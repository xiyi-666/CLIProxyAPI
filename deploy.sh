#!/bin/bash
# GCloud 部署助手脚本
# 用于简化 CLI Proxy API 的部署过程

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 配置变量
PROJECT_ID="${GCP_PROJECT_ID:-}"
REGION="${GCP_REGION:-us-central1}"
ZONE="${GCP_ZONE:-us-central1-a}"
CLUSTER_NAME="${GKE_CLUSTER_NAME:-cli-proxy-cluster}"
BUCKET_NAME="${GCP_BUCKET_NAME:-}"
NAMESPACE="cli-proxy-api"

# 检查必要工具
check_prerequisites() {
    log_info "检查必要工具..."
    
    local tools=("gcloud" "kubectl" "docker" "git")
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            log_error "$tool 未安装"
            return 1
        fi
    done
    
    log_success "所有必要工具已安装"
}

# 初始化 GCP 项目
init_gcp_project() {
    log_info "初始化 GCP 项目..."
    
    if [ -z "$PROJECT_ID" ]; then
        log_error "请设置 GCP_PROJECT_ID 环境变量"
        return 1
    fi
    
    gcloud config set project $PROJECT_ID
    
    log_info "启用必要的 API..."
    local apis=(
        "compute.googleapis.com"
        "container.googleapis.com"
        "containerregistry.googleapis.com"
        "cloudbuild.googleapis.com"
        "storage-component.googleapis.com"
        "secretmanager.googleapis.com"
    )
    
    for api in "${apis[@]}"; do
        gcloud services enable "$api"
    done
    
    log_success "GCP 项目初始化完成"
}

# 创建 Cloud Storage Bucket
create_bucket() {
    log_info "创建 Cloud Storage Bucket..."
    
    if [ -z "$BUCKET_NAME" ]; then
        BUCKET_NAME="${PROJECT_ID}-cli-proxy-config"
    fi
    
    if gsutil ls -b gs://$BUCKET_NAME > /dev/null 2>&1; then
        log_warning "Bucket 已存在: gs://$BUCKET_NAME"
    else
        gsutil mb -p $PROJECT_ID -l $REGION gs://$BUCKET_NAME
        log_success "Bucket 已创建: gs://$BUCKET_NAME"
    fi
    
    # 启用版本控制
    gsutil versioning set on gs://$BUCKET_NAME
}

# 上传 config.yaml
upload_config() {
    log_info "上传 config.yaml..."
    
    if [ ! -f "config.yaml" ]; then
        log_error "config.yaml 不存在，请先复制 config.example.yaml"
        return 1
    fi
    
    gsutil cp config.yaml gs://$BUCKET_NAME/config.yaml
    log_success "config.yaml 已上传"
}

# 创建 GKE 集群
create_gke_cluster() {
    log_info "创建 GKE 集群..."
    
    if gcloud container clusters describe $CLUSTER_NAME --zone $ZONE > /dev/null 2>&1; then
        log_warning "集群已存在: $CLUSTER_NAME"
    else
        gcloud container clusters create $CLUSTER_NAME \
            --zone $ZONE \
            --num-nodes 3 \
            --machine-type n2-standard-4 \
            --enable-autoscaling \
            --min-nodes 3 \
            --max-nodes 10 \
            --enable-autorepair \
            --enable-autoupgrade \
            --enable-ip-alias \
            --enable-cloud-logging \
            --enable-cloud-monitoring \
            --addons HorizontalPodAutoscaling,HttpLoadBalancing,GcePersistentDiskCsiDriver \
            --workload-pool=${PROJECT_ID}.svc.id.goog
        
        log_success "GKE 集群已创建"
    fi
    
    # 获取集群凭证
    gcloud container clusters get-credentials $CLUSTER_NAME --zone $ZONE
}

# 设置 Workload Identity
setup_workload_identity() {
    log_info "设置 Workload Identity..."
    
    local GCP_SA="cli-proxy-gke"
    
    # 创建 GCP 服务账户
    if gcloud iam service-accounts describe ${GCP_SA}@${PROJECT_ID}.iam.gserviceaccount.com > /dev/null 2>&1; then
        log_warning "服务账户已存在: $GCP_SA"
    else
        gcloud iam service-accounts create $GCP_SA
        log_success "服务账户已创建: $GCP_SA"
    fi
    
    # 授予权限
    gcloud projects add-iam-policy-binding $PROJECT_ID \
        --member=serviceAccount:${GCP_SA}@${PROJECT_ID}.iam.gserviceaccount.com \
        --role=roles/storage.objectViewer
    
    gcloud projects add-iam-policy-binding $PROJECT_ID \
        --member=serviceAccount:${GCP_SA}@${PROJECT_ID}.iam.gserviceaccount.com \
        --role=roles/secretmanager.secretAccessor
    
    # 创建命名空间
    kubectl create namespace $NAMESPACE || true
    
    # 创建 K8S 服务账户
    kubectl create serviceaccount cli-proxy-api -n $NAMESPACE || true
    
    # 设置 Workload Identity 绑定
    gcloud iam service-accounts add-iam-policy-binding \
        ${GCP_SA}@${PROJECT_ID}.iam.gserviceaccount.com \
        --role roles/iam.workloadIdentityUser \
        --member "serviceAccount:${PROJECT_ID}.svc.id.goog[${NAMESPACE}/cli-proxy-api]"
    
    kubectl annotate serviceaccount cli-proxy-api \
        -n $NAMESPACE \
        iam.gke.io/gcp-service-account=${GCP_SA}@${PROJECT_ID}.iam.gserviceaccount.com \
        --overwrite
    
    log_success "Workload Identity 已配置"
}

# 创建 ConfigMap
create_configmap() {
    log_info "创建 ConfigMap..."
    
    kubectl create configmap gcp-config \
        -n $NAMESPACE \
        --from-literal=bucket-name="$BUCKET_NAME" \
        --from-literal=project-id="$PROJECT_ID" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    log_success "ConfigMap 已创建"
}

# 创建 Secret
create_secret() {
    log_info "创建 Secret..."
    
    read -sp "输入管理员密钥: " MANAGEMENT_KEY
    echo
    
    kubectl create secret generic cli-proxy-secrets \
        -n $NAMESPACE \
        --from-literal=management-secret-key="$MANAGEMENT_KEY" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    log_success "Secret 已创建"
}

# 构建和推送 Docker 镜像
build_and_push_image() {
    log_info "构建 Docker 镜像..."
    
    local IMAGE_TAG="gcr.io/${PROJECT_ID}/cli-proxy-api:latest"
    local VERSION="${1:-1.0.0}"
    local COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "none")
    local BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    docker build -t $IMAGE_TAG \
        --build-arg VERSION="$VERSION" \
        --build-arg COMMIT="$COMMIT" \
        --build-arg BUILD_DATE="$BUILD_DATE" \
        .
    
    log_success "镜像构建完成"
    
    log_info "推送镜像到 GCR..."
    docker push $IMAGE_TAG
    
    log_success "镜像已推送: $IMAGE_TAG"
}

# 部署到 GKE
deploy_to_gke() {
    log_info "部署到 GKE..."
    
    # 替换 Kubernetes 清单中的变量
    sed "s/PROJECT_ID/$PROJECT_ID/g" k8s-deployment.yaml | \
    sed "s/BUCKET_NAME/$BUCKET_NAME/g" | \
    sed "s/cli-proxy-api.example.com/cli-proxy-api.example.com/g" | \
    kubectl apply -f -
    
    log_success "已部署到 GKE"
    
    log_info "等待 Pod 启动..."
    kubectl rollout status deployment/cli-proxy-api -n $NAMESPACE
    
    log_success "部署完成！"
}

# 显示部署信息
show_deployment_info() {
    log_info "部署信息:"
    
    echo ""
    kubectl get service cli-proxy-api -n $NAMESPACE
    echo ""
    
    local EXTERNAL_IP=$(kubectl get service cli-proxy-api -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    if [ -n "$EXTERNAL_IP" ]; then
        log_success "外部 IP: $EXTERNAL_IP"
        log_info "API 端点: http://$EXTERNAL_IP:8317"
    else
        log_warning "外部 IP 还未分配，请稍候..."
    fi
}

# 显示使用帮助
show_usage() {
    cat << EOF
用法: ./deploy.sh [命令]

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
  clean         - 清理所有资源

环境变量:
  GCP_PROJECT_ID    - GCP 项目 ID（必需）
  GCP_REGION        - GCP 地区（默认: us-central1）
  GCP_ZONE          - GCP 可用区（默认: us-central1-a）
  GKE_CLUSTER_NAME  - GKE 集群名称（默认: cli-proxy-cluster）
  GCP_BUCKET_NAME   - GCS Bucket 名称（默认: {PROJECT_ID}-cli-proxy-config）

示例:
  export GCP_PROJECT_ID=my-project
  export GCP_REGION=us-central1
  ./deploy.sh init
  ./deploy.sh bucket
  ./deploy.sh upload
  ./deploy.sh full
EOF
}

# 完整部署流程
full_deploy() {
    log_info "开始完整部署流程..."
    
    check_prerequisites || return 1
    init_gcp_project || return 1
    create_bucket || return 1
    upload_config || return 1
    create_gke_cluster || return 1
    setup_workload_identity || return 1
    create_configmap || return 1
    create_secret || return 1
    build_and_push_image || return 1
    deploy_to_gke || return 1
    show_deployment_info
    
    log_success "完整部署已完成！"
}

# 清理资源
cleanup_resources() {
    log_warning "警告：将删除所有资源"
    read -p "确定要继续吗？(yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        log_info "已取消"
        return
    fi
    
    log_info "删除 GKE 集群..."
    gcloud container clusters delete $CLUSTER_NAME --zone $ZONE --quiet
    
    log_info "删除 Cloud Storage Bucket..."
    gsutil -m rm -r gs://$BUCKET_NAME
    
    log_info "删除服务账户..."
    gcloud iam service-accounts delete cli-proxy-gke@${PROJECT_ID}.iam.gserviceaccount.com --quiet
    
    log_success "资源已清理"
}

# 主入口
main() {
    if [ $# -eq 0 ]; then
        show_usage
        return 1
    fi
    
    case "$1" in
        init)
            check_prerequisites && init_gcp_project
            ;;
        bucket)
            create_bucket
            ;;
        upload)
            upload_config
            ;;
        cluster)
            create_gke_cluster
            ;;
        workload)
            setup_workload_identity
            ;;
        configmap)
            create_configmap
            ;;
        secret)
            create_secret
            ;;
        build)
            build_and_push_image "$2"
            ;;
        deploy)
            deploy_to_gke
            ;;
        full)
            full_deploy
            ;;
        info)
            show_deployment_info
            ;;
        clean)
            cleanup_resources
            ;;
        *)
            log_error "未知命令: $1"
            show_usage
            return 1
            ;;
    esac
}

# 运行主函数
main "$@"
