# PowerShell GCloud 部署助手脚本
# 用于简化 CLI Proxy API 的部署过程

param(
    [Parameter(Position = 0)]
    [string]$Command = "",
    
    [Parameter(Position = 1)]
    [string]$Version = "1.0.0"
)

# 配置变量
$PROJECT_ID = $env:GCP_PROJECT_ID
$REGION = $env:GCP_REGION -or "us-central1"
$ZONE = $env:GCP_ZONE -or "us-central1-a"
$CLUSTER_NAME = $env:GKE_CLUSTER_NAME -or "cli-proxy-cluster"
$BUCKET_NAME = $env:GCP_BUCKET_NAME -or "$PROJECT_ID-cli-proxy-config"
$NAMESPACE = "cli-proxy-api"
$GCP_SA = "cli-proxy-gke"

# 颜色输出
function Write-Info {
    Write-Host "[INFO] $args" -ForegroundColor Blue
}

function Write-Success {
    Write-Host "[SUCCESS] $args" -ForegroundColor Green
}

function Write-Warning {
    Write-Host "[WARNING] $args" -ForegroundColor Yellow
}

function Write-Error {
    Write-Host "[ERROR] $args" -ForegroundColor Red
}

# 检查前置条件
function Test-Prerequisites {
    Write-Info "检查必要工具..."
    
    $tools = @("gcloud", "kubectl", "docker", "git")
    foreach ($tool in $tools) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            Write-Error "$tool 未安装"
            return $false
        }
    }
    
    Write-Success "所有必要工具已安装"
    return $true
}

# 检查 GCP 项目 ID
function Test-ProjectID {
    if ([string]::IsNullOrEmpty($PROJECT_ID)) {
        Write-Error "请设置 GCP_PROJECT_ID 环境变量"
        Write-Host "示例: `$env:GCP_PROJECT_ID = 'my-project'"
        return $false
    }
    return $true
}

# 初始化 GCP 项目
function Initialize-GCPProject {
    Write-Info "初始化 GCP 项目..."
    
    if (-not (Test-ProjectID)) { return $false }
    
    gcloud config set project $PROJECT_ID
    
    Write-Info "启用必要的 API..."
    $apis = @(
        "compute.googleapis.com",
        "container.googleapis.com",
        "containerregistry.googleapis.com",
        "cloudbuild.googleapis.com",
        "storage-component.googleapis.com",
        "secretmanager.googleapis.com"
    )
    
    foreach ($api in $apis) {
        gcloud services enable $api
    }
    
    Write-Success "GCP 项目初始化完成"
    return $true
}

# 创建 Cloud Storage Bucket
function New-StorageBucket {
    Write-Info "创建 Cloud Storage Bucket..."
    
    $bucketExists = gcloud storage buckets describe gs://$BUCKET_NAME 2>$null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Warning "Bucket 已存在: gs://$BUCKET_NAME"
    }
    else {
        gcloud storage buckets create gs://$BUCKET_NAME --location=$REGION
        Write-Success "Bucket 已创建: gs://$BUCKET_NAME"
    }
    
    # 启用版本控制
    gcloud storage buckets update gs://$BUCKET_NAME --versioning
    
    return $true
}

# 上传 config.yaml
function Upload-Config {
    Write-Info "上传 config.yaml..."
    
    if (-not (Test-Path "config.yaml")) {
        Write-Error "config.yaml 不存在，请先复制 config.example.yaml"
        return $false
    }
    
    gcloud storage cp config.yaml gs://$BUCKET_NAME/config.yaml
    Write-Success "config.yaml 已上传"
    
    return $true
}

# 创建 GKE 集群
function New-GKECluster {
    Write-Info "创建 GKE 集群..."
    
    $clusterExists = gcloud container clusters describe $CLUSTER_NAME --zone $ZONE 2>$null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Warning "集群已存在: $CLUSTER_NAME"
    }
    else {
        gcloud container clusters create $CLUSTER_NAME `
            --zone $ZONE `
            --num-nodes 3 `
            --machine-type n2-standard-4 `
            --enable-autoscaling `
            --min-nodes 3 `
            --max-nodes 10 `
            --enable-autorepair `
            --enable-autoupgrade `
            --enable-ip-alias `
            --enable-cloud-logging `
            --enable-cloud-monitoring `
            --addons HorizontalPodAutoscaling,HttpLoadBalancing,GcePersistentDiskCsiDriver `
            --workload-pool=$PROJECT_ID.svc.id.goog
        
        Write-Success "GKE 集群已创建"
    }
    
    # 获取集群凭证
    gcloud container clusters get-credentials $CLUSTER_NAME --zone $ZONE
    
    return $true
}

# 设置 Workload Identity
function Set-WorkloadIdentity {
    Write-Info "设置 Workload Identity..."
    
    # 创建服务账户
    $saExists = gcloud iam service-accounts describe $GCP_SA@$PROJECT_ID.iam.gserviceaccount.com 2>$null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Warning "服务账户已存在: $GCP_SA"
    }
    else {
        gcloud iam service-accounts create $GCP_SA
        Write-Success "服务账户已创建: $GCP_SA"
    }
    
    # 授予权限
    gcloud projects add-iam-policy-binding $PROJECT_ID `
        --member=serviceAccount:$GCP_SA@$PROJECT_ID.iam.gserviceaccount.com `
        --role=roles/storage.objectViewer
    
    gcloud projects add-iam-policy-binding $PROJECT_ID `
        --member=serviceAccount:$GCP_SA@$PROJECT_ID.iam.gserviceaccount.com `
        --role=roles/secretmanager.secretAccessor
    
    # 创建命名空间
    kubectl create namespace $NAMESPACE 2>$null
    
    # 创建 K8S 服务账户
    kubectl create serviceaccount cli-proxy-api -n $NAMESPACE 2>$null
    
    # 设置 Workload Identity 绑定
    gcloud iam service-accounts add-iam-policy-binding `
        $GCP_SA@$PROJECT_ID.iam.gserviceaccount.com `
        --role roles/iam.workloadIdentityUser `
        --member "serviceAccount:$PROJECT_ID.svc.id.goog[$NAMESPACE/cli-proxy-api]"
    
    kubectl annotate serviceaccount cli-proxy-api `
        -n $NAMESPACE `
        iam.gke.io/gcp-service-account=$GCP_SA@$PROJECT_ID.iam.gserviceaccount.com `
        --overwrite
    
    Write-Success "Workload Identity 已配置"
    return $true
}

# 创建 ConfigMap
function New-ConfigMap {
    Write-Info "创建 ConfigMap..."
    
    kubectl create configmap gcp-config `
        -n $NAMESPACE `
        --from-literal=bucket-name=$BUCKET_NAME `
        --from-literal=project-id=$PROJECT_ID `
        --dry-run=client -o yaml | kubectl apply -f -
    
    Write-Success "ConfigMap 已创建"
    return $true
}

# 创建 Secret
function New-Secret {
    Write-Info "创建 Secret..."
    
    $secretKey = Read-Host "输入管理员密钥" -AsSecureString
    $secretKeyPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToCoTaskMemUnicode($secretKey))
    
    kubectl create secret generic cli-proxy-secrets `
        -n $NAMESPACE `
        --from-literal=management-secret-key=$secretKeyPlain `
        --dry-run=client -o yaml | kubectl apply -f -
    
    Write-Success "Secret 已创建"
    return $true
}

# 构建和推送 Docker 镜像
function Build-AndPushImage {
    param([string]$Version = "1.0.0")
    
    Write-Info "构建 Docker 镜像..."
    
    $IMAGE_TAG = "gcr.io/$PROJECT_ID/cli-proxy-api:latest"
    $COMMIT = git rev-parse HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { $COMMIT = "none" }
    $BUILD_DATE = Get-Date -Format "o"
    
    docker build -t $IMAGE_TAG `
        --build-arg VERSION=$Version `
        --build-arg COMMIT=$COMMIT `
        --build-arg BUILD_DATE=$BUILD_DATE `
        .
    
    Write-Success "镜像构建完成"
    
    Write-Info "推送镜像到 GCR..."
    docker push $IMAGE_TAG
    
    Write-Success "镜像已推送: $IMAGE_TAG"
    return $true
}

# 部署到 GKE
function Deploy-ToGKE {
    Write-Info "部署到 GKE..."
    
    # 替换 Kubernetes 清单中的变量
    $content = Get-Content k8s-deployment.yaml
    $content = $content -replace "PROJECT_ID", $PROJECT_ID
    $content = $content -replace "BUCKET_NAME", $BUCKET_NAME
    
    $content | kubectl apply -f -
    
    Write-Success "已部署到 GKE"
    
    Write-Info "等待 Pod 启动..."
    kubectl rollout status deployment/cli-proxy-api -n $NAMESPACE
    
    Write-Success "部署完成！"
    return $true
}

# 显示部署信息
function Show-DeploymentInfo {
    Write-Info "部署信息:"
    Write-Host ""
    
    kubectl get service cli-proxy-api -n $NAMESPACE
    
    Write-Host ""
    $EXTERNAL_IP = kubectl get service cli-proxy-api -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
    
    if ($EXTERNAL_IP) {
        Write-Success "外部 IP: $EXTERNAL_IP"
        Write-Info "API 端点: http://$EXTERNAL_IP:8317"
    }
    else {
        Write-Warning "外部 IP 还未分配，请稍候..."
    }
    
    return $true
}

# 显示使用帮助
function Show-Usage {
    Write-Host @"
用法: .\deploy.ps1 [命令] [版本]

命令:
  init          - 初始化 GCP 项目
  bucket        - 创建 Cloud Storage Bucket
  upload        - 上传 config.yaml
  cluster       - 创建 GKE 集群
  workload      - 设置 Workload Identity
  configmap     - 创建 ConfigMap
  secret        - 创建 Secret
  build         - 构建和推送 Docker 镜像
  deploy        - 部署到 GKE
  full          - 完整部署（从头到尾）
  info          - 显示部署信息

环境变量:
  GCP_PROJECT_ID    - GCP 项目 ID（必需）
  GCP_REGION        - GCP 地区（默认: us-central1）
  GCP_ZONE          - GCP 可用区（默认: us-central1-a）
  GKE_CLUSTER_NAME  - GKE 集群名称（默认: cli-proxy-cluster）
  GCP_BUCKET_NAME   - GCS Bucket 名称（默认: {PROJECT_ID}-cli-proxy-config）

示例:
  `$env:GCP_PROJECT_ID = 'my-project'
  .\deploy.ps1 init
  .\deploy.ps1 bucket
  .\deploy.ps1 upload
  .\deploy.ps1 full
"@
}

# 完整部署
function Invoke-FullDeploy {
    Write-Info "开始完整部署流程..."
    
    if (-not (Test-Prerequisites)) { return $false }
    if (-not (Initialize-GCPProject)) { return $false }
    if (-not (New-StorageBucket)) { return $false }
    if (-not (Upload-Config)) { return $false }
    if (-not (New-GKECluster)) { return $false }
    if (-not (Set-WorkloadIdentity)) { return $false }
    if (-not (New-ConfigMap)) { return $false }
    if (-not (New-Secret)) { return $false }
    if (-not (Build-AndPushImage -Version $Version)) { return $false }
    if (-not (Deploy-ToGKE)) { return $false }
    
    Show-DeploymentInfo
    
    Write-Success "完整部署已完成！"
    return $true
}

# 主逻辑
switch ($Command.ToLower()) {
    "init" {
        Test-Prerequisites
        Initialize-GCPProject
    }
    "bucket" {
        New-StorageBucket
    }
    "upload" {
        Upload-Config
    }
    "cluster" {
        New-GKECluster
    }
    "workload" {
        Set-WorkloadIdentity
    }
    "configmap" {
        New-ConfigMap
    }
    "secret" {
        New-Secret
    }
    "build" {
        Build-AndPushImage -Version $Version
    }
    "deploy" {
        Deploy-ToGKE
    }
    "full" {
        Invoke-FullDeploy
    }
    "info" {
        Show-DeploymentInfo
    }
    default {
        Show-Usage
    }
}
