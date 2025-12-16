# GCloud 部署指南 - CLI Proxy API

## 目录

1. [前置条件](#前置条件)
2. [架构设计](#架构设计)
3. [配置管理方案](#配置管理方案)
4. [逐步部署流程](#逐步部署流程)
5. [验证和监控](#验证和监控)
6. [故障排查](#故障排查)
7. [更新和回滚](#更新和回滚)

---

## 前置条件

### 1. 安装必要工具

```powershell
# 安装 Google Cloud SDK
# https://cloud.google.com/sdk/docs/install

# 验证安装
gcloud version
kubectl version --client
docker version
```

### 2. GCP 项目设置

```powershell
# 创建新项目或使用现有项目
$PROJECT_ID = "your-project-id"
$REGION = "europe-west1"
$ZONE = "us-central1-a"

# 设置默认项目
gcloud config set project $PROJECT_ID

# 启用必要的 API
gcloud services enable compute.googleapis.com
gcloud services enable container.googleapis.com
gcloud services enable containerregistry.googleapis.com
gcloud services enable cloudbuild.googleapis.com
gcloud services enable artifactregistry.googleapis.com
gcloud services enable storage-component.googleapis.com
gcloud services enable secretmanager.googleapis.com
gcloud services enable cloudkms.googleapis.com
```

### 3. 认证设置

```powershell
# 使用服务账户进行认证
gcloud auth login

# 为 Docker 配置 GCR 认证
gcloud auth configure-docker gcr.io
```

---

## 架构设计

### 方案对比

| 方案 | 优点 | 缺点 | 适用场景 |
|------|------|------|---------|
| **Cloud Run** | 无服务器、自动扩展、成本低 | 冷启动延迟、受限环境 | 低延迟应用 |
| **GKE** | 完全控制、高性能、支持有状态应用 | 需要手动管理、成本较高 | 复杂、高性能应用 |
| **Compute Engine** | 最灵活、完全控制 | 需要手动配置、维护成本高 | 特定配置需求 |

### 推荐方案：GKE + Cloud Storage Bucket

- **计算层**：Google Kubernetes Engine (GKE)
- **配置管理**：Google Cloud Storage Bucket（用于 config.yaml）
- **密钥管理**：Google Secret Manager
- **日志**：Cloud Logging 和 Cloud Storage
- **监控**：Cloud Monitoring

---

## 配置管理方案

### 方案 1: Cloud Storage Bucket (推荐)

**优点**：
- 简单易用，一次性读入
- 支持版本控制
- 成本低
- 易于备份

**缺点**：
- 需要网络访问
- 缺少加密选项

### 方案 2: Google Secret Manager + ConfigMap

**优点**：
- 更安全
- 支持自动轮换
- 集中管理

**缺点**：
- 成本稍高
- 配置复杂

### 推荐：混合方案

- **config.yaml** → Cloud Storage Bucket（大型配置文件）
- **API Keys** → Google Secret Manager（敏感信息）

---

## 逐步部署流程

### Phase 1: 准备阶段

#### 1.1 创建 Cloud Storage Bucket

```powershell
$BUCKET_NAME = "${PROJECT_ID}-cli-proxy-config"

# 创建 bucket
gsutil mb gs://$BUCKET_NAME

# 配置版本控制
gsutil versioning set on gs://$BUCKET_NAME

# 配置访问权限（私有）
gsutil iam ch serviceAccount:cli-proxy-gke@${PROJECT_ID}.iam.gserviceaccount.com:objectAdmin gs://$BUCKET_NAME
```

#### 1.2 上传 config.yaml

```powershell
# 复制 config.example.yaml 为 config.yaml
Copy-Item config.example.yaml config.yaml

# 编辑 config.yaml 填入实际的 API keys 和配置
# 使用 VS Code 或其他编辑器打开 config.yaml
notepad config.yaml

# 上传到 bucket
gsutil cp config.yaml gs://$BUCKET_NAME/config.yaml

# 验证上传
gsutil ls -l gs://$BUCKET_NAME/config.yaml
```

#### 1.3 创建 Google Secret Manager 密钥

```powershell
# 创建管理员密钥 secret
$MANAGEMENT_KEY = "your-secure-management-key-here"

echo $MANAGEMENT_KEY | gcloud secrets create cli-proxy-management-key --data-file=-

# 授予 GKE 服务账户访问权限
gcloud secrets add-iam-policy-binding cli-proxy-management-key `
  --member=serviceAccount:cli-proxy-gke@${PROJECT_ID}.iam.gserviceaccount.com `
  --role=roles/secretmanager.secretAccessor
```

### Phase 2: 创建 GKE 集群

#### 2.1 创建 GKE 集群

```powershell
$CLUSTER_NAME = "cli-proxy-cluster"
$MACHINE_TYPE = "n2-standard-4"
$NUM_NODES = 3

gcloud container clusters create $CLUSTER_NAME `
  --zone $ZONE `
  --num-nodes $NUM_NODES `
  --machine-type $MACHINE_TYPE `
  --enable-autoscaling `
  --min-nodes 3 `
  --max-nodes 10 `
  --enable-autorepair `
  --enable-autoupgrade `
  --enable-ip-alias `
  --enable-cloud-logging `
  --enable-cloud-monitoring `
  --addons HorizontalPodAutoscaling,HttpLoadBalancing,GcePersistentDiskCsiDriver `
  --workload-pool=${PROJECT_ID}.svc.id.goog
```

#### 2.2 获取集群凭证

```powershell
gcloud container clusters get-credentials $CLUSTER_NAME --zone $ZONE

# 验证连接
kubectl cluster-info
kubectl get nodes
```

#### 2.3 创建 GKE 服务账户

```powershell
$K8S_SA = "cli-proxy-api"
$K8S_NAMESPACE = "cli-proxy-api"
$GCP_SA = "cli-proxy-gke"

# 创建 GCP 服务账户
gcloud iam service-accounts create $GCP_SA

# 授予必要的权限
gcloud projects add-iam-policy-binding $PROJECT_ID `
  --member=serviceAccount:${GCP_SA}@${PROJECT_ID}.iam.gserviceaccount.com `
  --role=roles/storage.objectViewer

gcloud projects add-iam-policy-binding $PROJECT_ID `
  --member=serviceAccount:${GCP_SA}@${PROJECT_ID}.iam.gserviceaccount.com `
  --role=roles/secretmanager.secretAccessor

# 设置 Workload Identity 绑定
kubectl create namespace $K8S_NAMESPACE

kubectl create serviceaccount $K8S_SA -n $K8S_NAMESPACE

gcloud iam service-accounts add-iam-policy-binding ${GCP_SA}@${PROJECT_ID}.iam.gserviceaccount.com `
  --role roles/iam.workloadIdentityUser `
  --member "serviceAccount:${PROJECT_ID}.svc.id.goog[${K8S_NAMESPACE}/${K8S_SA}]"

# 为 K8S SA 添加 GCP SA 的 Workload Identity 绑定
kubectl annotate serviceaccount $K8S_SA `
  -n $K8S_NAMESPACE `
  iam.gke.io/gcp-service-account=${GCP_SA}@${PROJECT_ID}.iam.gserviceaccount.com `
  --overwrite
```

### Phase 3: 准备 Kubernetes 资源

#### 3.1 创建 ConfigMap for GCP 配置

```powershell
# 创建命名空间（如果还未创建）
kubectl create namespace cli-proxy-api

# 创建 ConfigMap，用于 init container 下载配置
kubectl create configmap gcp-config `
  -n cli-proxy-api `
  --from-literal=bucket-name="${BUCKET_NAME}" `
  --from-literal=project-id="${PROJECT_ID}"

# 验证 ConfigMap
kubectl get configmap gcp-config -n cli-proxy-api
```

#### 3.2 创建 Secret for 敏感数据

```powershell
# 创建 Secret
kubectl create secret generic cli-proxy-secrets `
  -n cli-proxy-api `
  --from-literal=management-secret-key="your-secret-key-here"

# 验证 Secret
kubectl get secrets -n cli-proxy-api
```

### Phase 4: 构建和推送 Docker 镜像

#### 4.1 本地构建和测试（可选）

```powershell
# 设置 Docker 镜像标签
$IMAGE_TAG = "gcr.io/${PROJECT_ID}/cli-proxy-api:latest"

# 构建镜像
docker build -t $IMAGE_TAG `
  --build-arg VERSION="1.0.0" `
  --build-arg COMMIT="$(git rev-parse HEAD)" `
  --build-arg BUILD_DATE="$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')" `
  .

# 本地测试
docker run -it `
  -v "$(pwd)/config.yaml:/CLIProxyAPI/config.yaml" `
  -p 8317:8317 `
  $IMAGE_TAG
```

#### 4.2 推送到 GCR

```powershell
# 推送镜像
docker push $IMAGE_TAG

# 验证镜像
gcloud container images list --repository=gcr.io/${PROJECT_ID}
gcloud container images list-tags gcr.io/${PROJECT_ID}/cli-proxy-api
```

### Phase 3: 部署到 Cloud Run

#### 部署应用

```powershell
gcloud run deploy cli-proxy-api `
  --image gcr.io/${PROJECT_ID}/cli-proxy-api:latest `
  --region $REGION `
  --platform managed `
  --allow-unauthenticated `
  --set-env-vars=PROJECT_ID=${PROJECT_ID},BUCKET_NAME=${BUCKET_NAME}
```

> **说明**
> - `--allow-unauthenticated` 使服务公开访问（如需内部访问可去掉）。
> - 环境变量 `PROJECT_ID` 与 `BUCKET_NAME` 用于在容器启动时读取配置和密钥。

#### 验证部署

```powershell
# 部署完成后会输出类似的 URL
# https://cli-proxy-api-xxxxxx-uc.a.run.app
Invoke-WebRequest -Uri "https://cli-proxy-api-xxxxxx-uc.a.run.app/health"
```

#### 检查日志

```powershell
gcloud logging read "resource.type=cloud_run_revision AND resource.labels.service_name=cli-proxy-api" \
  --limit=50 --format="json"
```

#### 5.3 配置 Ingress 和 DNS

```powershell
# 如果使用 Ingress，保留外部 IP
$EXTERNAL_IP = kubectl get service cli-proxy-api -n cli-proxy-api -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

# 在 DNS 提供商中创建 A 记录，指向 $EXTERNAL_IP
# 例如：cli-proxy-api.example.com -> $EXTERNAL_IP

# 验证 DNS
nslookup cli-proxy-api.example.com

# 验证 HTTPS（ManagedCertificate）
# 等待 5-10 分钟让 Google 颁发证书
kubectl describe managedcertificate cli-proxy-api-cert -n cli-proxy-api
```

### Phase 6: 配置 Cloud Build 自动化部署（可选）

#### 6.1 连接 GitHub 仓库

```powershell
# 在 GCP Console 中：
# 1. 导航到 Cloud Build → 触发器
# 2. 连接新仓库
# 3. 选择 GitHub 并授权
# 4. 选择这个 CLIProxyAPI 仓库
```

#### 6.2 创建构建触发器

```powershell
# 使用 gcloud 命令
gcloud builds triggers create github `
  --repo-name=CLIProxyAPI `
  --repo-owner=xiyi-666 `
  --branch-pattern="^main$" `
  --build-config=cloudbuild.yaml `
  --name=cli-proxy-api-deploy
```

---

## 验证和监控

### 验证部署

```powershell
# 1. 检查 Pod 状态
kubectl get pods -n cli-proxy-api -o wide

# 2. 查看 Pod 日志
kubectl logs -n cli-proxy-api -l app=cli-proxy-api --tail=100 -f

# 3. 测试 API 端点
$EXTERNAL_IP = kubectl get service cli-proxy-api -n cli-proxy-api -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
Invoke-WebRequest -Uri "http://${EXTERNAL_IP}:8317/health"

# 4. 检查 config.yaml 是否正确加载
kubectl exec -it <pod-name> -n cli-proxy-api -- cat /CLIProxyAPI/config.yaml

# 5. 查看存储和卷
kubectl get pvc -n cli-proxy-api -o wide
kubectl get pv -o wide
```

### 监控应用

#### 设置 Cloud Logging

```powershell
# 查看 Cloud Logging
gcloud logging read "resource.type=k8s_container AND resource.labels.namespace_name=cli-proxy-api" `
  --limit=50 `
  --format=json
```

#### 设置 Cloud Monitoring

```powershell
# 创建告警策略
gcloud alpha monitoring policies create `
  --notification-channels=<CHANNEL_ID> `
  --display-name="CLI Proxy API High Error Rate" `
  --condition-name="ErrorRateHigh" `
  --condition-threshold-value=0.05 `
  --condition-threshold-duration=300s
```

---

## 故障排查

### 常见问题

#### 1. Pod 无法启动

```powershell
# 查看 Pod 事件
kubectl describe pod <pod-name> -n cli-proxy-api

# 查看详细日志
kubectl logs <pod-name> -n cli-proxy-api -p  # 前一个 Pod 日志
```

#### 2. config.yaml 未正确加载

```powershell
# 验证 init container
kubectl logs <pod-name> -n cli-proxy-api -c download-config

# 检查 Bucket 权限
gsutil iam get gs://$BUCKET_NAME

# 验证服务账户权限
gcloud projects get-iam-policy $PROJECT_ID \
  --flatten="bindings[].members" \
  --filter="bindings.members:serviceAccount:cli-proxy-gke@*"
```

#### 3. 网络连接问题

```powershell
# 检查 Service
kubectl get svc -n cli-proxy-api

# 端口转发测试
kubectl port-forward svc/cli-proxy-api 8317:8317 -n cli-proxy-api

# 从本地访问
Invoke-WebRequest -Uri "http://localhost:8317/health"
```

#### 4. 存储问题

```powershell
# 检查 PVC 状态
kubectl describe pvc -n cli-proxy-api

# 检查节点存储
kubectl top nodes
kubectl describe nodes
```

---

## 更新和回滚

### 更新应用

#### 方法 1: 使用 Cloud Build 自动部署

```powershell
# Push 到 main 分支会自动触发构建和部署
git push origin main
```

#### 方法 2: 手动更新镜像

```powershell
# 1. 构建新镜像
$NEW_VERSION = "1.1.0"
docker build -t gcr.io/${PROJECT_ID}/cli-proxy-api:${NEW_VERSION} .
docker push gcr.io/${PROJECT_ID}/cli-proxy-api:${NEW_VERSION}

# 2. 更新 Deployment
kubectl set image deployment/cli-proxy-api `
  -n cli-proxy-api `
  cli-proxy-api=gcr.io/${PROJECT_ID}/cli-proxy-api:${NEW_VERSION}

# 3. 验证更新
kubectl rollout status deployment/cli-proxy-api -n cli-proxy-api -w
```

### 回滚应用

```powershell
# 查看发布历史
kubectl rollout history deployment/cli-proxy-api -n cli-proxy-api

# 回滚到上一个版本
kubectl rollout undo deployment/cli-proxy-api -n cli-proxy-api

# 回滚到特定版本
kubectl rollout undo deployment/cli-proxy-api -n cli-proxy-api --to-revision=2

# 验证回滚
kubectl rollout status deployment/cli-proxy-api -n cli-proxy-api -w
```

### 更新 config.yaml

```powershell
# 1. 编辑本地 config.yaml
notepad config.yaml

# 2. 上传到 Bucket（创建新版本）
gsutil cp config.yaml gs://$BUCKET_NAME/config.yaml

# 3. 重启 Pod 以加载新配置
kubectl rollout restart deployment/cli-proxy-api -n cli-proxy-api

# 4. 验证
kubectl get pods -n cli-proxy-api -w
```

---

## 生产环境最佳实践

### 1. 安全性

```powershell
# 启用 Pod 安全策略
kubectl label namespace cli-proxy-api pod-security.kubernetes.io/enforce=restricted

# 使用 Workload Identity 而不是服务账户密钥
# （已在部署中配置）

# 定期审计日志
gcloud logging read "protoPayload.methodName:storage.*" --limit=10 --format=json

# 加密 Secret
kubectl create secret generic cli-proxy-secrets \
  --from-literal=key1=value1 \
  --dry-run=client \
  -o yaml | kubectl apply -f -
```

### 2. 成本优化

```powershell
# 使用抢占式节点降低成本
# 在 GKE 创建时添加：--preemptible

# 使用预留实例
gcloud compute reservations create cli-proxy-reservation \
  --zone=$ZONE \
  --vm-count=3 \
  --machine-type=$MACHINE_TYPE

# 启用集群自动缩放（已配置）
```

### 3. 备份和恢复

```powershell
# 备份 config.yaml（已使用 Bucket 版本控制）
gsutil versioning set on gs://$BUCKET_NAME

# 列出版本
gsutil ls -L gs://$BUCKET_NAME/config.yaml

# 恢复之前的版本
gsutil cp gs://$BUCKET_NAME/config.yaml#<GENERATION_NUMBER> config.yaml

# 备份 PVC
gcloud compute disks snapshot <PVC_DISK_NAME> \
  --snapshot-names=cli-proxy-backup-$(date +%Y%m%d)
```

### 4. 性能优化

```powershell
# 监控资源使用
kubectl top nodes
kubectl top pods -n cli-proxy-api

# 调整 HPA 参数（在 k8s-deployment.yaml 中）
# minReplicas: 3
# maxReplicas: 10
# CPU threshold: 70%
```

---

## 完整部署检查清单

- [ ] GCP 项目创建并启用必要 API
- [ ] Cloud Storage Bucket 创建和权限配置
- [ ] config.yaml 上传到 Bucket
- [ ] Google Secret Manager 密钥创建
- [ ] GKE 集群创建
- [ ] Workload Identity 配置
- [ ] Docker 镜像构建和推送
- [ ] Kubernetes 清单更新（项目 ID、Bucket 名等）
- [ ] 资源部署和验证
- [ ] DNS 配置（如使用 Ingress）
- [ ] 监控和日志配置
- [ ] 备份策略实施
- [ ] 文档更新

---

## 快速参考命令

```powershell
# 获取集群信息
kubectl cluster-info

# 获取所有资源
kubectl get all -n cli-proxy-api

# 查看详细信息
kubectl describe deployment cli-proxy-api -n cli-proxy-api

# 实时日志
kubectl logs -f -n cli-proxy-api -l app=cli-proxy-api

# 端口转发
kubectl port-forward svc/cli-proxy-api 8317:8317 -n cli-proxy-api

# 执行命令
kubectl exec -it <pod-name> -n cli-proxy-api -- /bin/sh

# 删除所有资源
kubectl delete namespace cli-proxy-api

# 获取集群状态
kubectl get nodes
kubectl describe nodes
```

---

## 支持和资源

- [Google Kubernetes Engine 文档](https://cloud.google.com/kubernetes-engine/docs)
- [Cloud Build 文档](https://cloud.google.com/build/docs)
- [Cloud Storage 文档](https://cloud.google.com/storage/docs)
- [Secret Manager 文档](https://cloud.google.com/secret-manager/docs)
- [Kubernetes 官方文档](https://kubernetes.io/docs/)
