# GCloud 部署方案总结

## 📌 项目概览

这是 **CLI Proxy API** 在 Google Cloud Platform 上的完整部署解决方案。

## 📁 新增文件清单

### 1. **cloudbuild.yaml** - CI/CD 自动化
- **用途**: 定义 Google Cloud Build 流程
- **功能**:
  - 自动构建 Docker 镜像
  - 推送到 Google Container Registry (GCR)
  - 部署到 GKE 或 Cloud Run
  - 支持 Git 触发自动部署

### 2. **k8s-deployment.yaml** - Kubernetes 完整配置
- **用途**: Kubernetes 清单文件
- **包含**:
  - Namespace 和 ServiceAccount
  - Deployment（3-10 副本）
  - Service（LoadBalancer）
  - PersistentVolumeClaim（存储）
  - ConfigMap 和 Secret
  - HorizontalPodAutoscaler（自动扩展）
  - Ingress（HTTPS）
  - RBAC 权限配置

**核心特性**:
```yaml
init-container:
  下载 config.yaml 从 Cloud Storage Bucket
  
main-container:
  运行 CLI Proxy API
  挂载配置、认证目录、日志目录
  
高可用:
  - 最少 3 个副本
  - Pod 反亲和性分散部署
  - 自动扩展（3-10 pods）
  - 健康检查和自动重启

安全:
  - Workload Identity（Pod 访问 GCP）
  - 非 root 运行
  - 只读根文件系统
  - 资源限制和请求
```

### 3. **gcloud-setup.md** - 详细部署指南（180+ 行）
- **内容覆盖**:
  - 前置条件检查
  - GCP 项目初始化
  - Cloud Storage Bucket 创建和配置
  - config.yaml 管理方案
  - GKE 集群创建
  - Workload Identity 配置
  - Docker 镜像构建和推送
  - Kubernetes 资源部署
  - 验证和监控
  - 故障排查指南
  - 更新和回滚流程
  - 生产环境最佳实践

### 4. **deploy.ps1** - PowerShell 自动化脚本
- **功能**:
  - 一键部署（`.\deploy.ps1 full`）
  - 分步部署（`init` → `bucket` → `cluster` → 等）
  - 自动化 GCP 和 Kubernetes 操作
  - Windows PowerShell 5.1 兼容

**支持的命令**:
```powershell
.\deploy.ps1 init          # 初始化 GCP
.\deploy.ps1 bucket        # 创建 Bucket
.\deploy.ps1 upload        # 上传配置
.\deploy.ps1 cluster       # 创建 GKE 集群
.\deploy.ps1 workload      # 配置 Workload Identity
.\deploy.ps1 configmap     # 创建 ConfigMap
.\deploy.ps1 secret        # 创建 Secret
.\deploy.ps1 build [version]  # 构建镜像
.\deploy.ps1 deploy        # 部署到 GKE
.\deploy.ps1 full          # 完整部署
.\deploy.ps1 info          # 显示部署信息
```

### 5. **deploy.sh** - Shell 自动化脚本
- **功能**: Linux/Mac 版本的自动化部署脚本
- **与 deploy.ps1 功能相同**

### 6. **DEPLOYMENT_SUMMARY.md** - 架构总结文档
- **内容**:
  - 系统架构图（ASCII）
  - 部署组件清单
  - 快速开始指南
  - 配置管理方案对比
  - 资源规划和成本估算
  - 安全特性说明
  - 常见操作指南

### 7. **QUICK_REFERENCE.txt** - 快速参考卡片
- **内容**: 常用命令速查表
- **覆盖**: 环境变量、kubectl 命令、gcloud 命令等

---

## 🚀 快速开始（3 种方式）

### 方式 1: 完全自动化（推荐）

```powershell
# Windows PowerShell
$env:GCP_PROJECT_ID = "my-project"
cp config.example.yaml config.yaml
# 编辑 config.yaml，填入 API keys
notepad config.yaml
.\deploy.ps1 full
```

### 方式 2: 分步部署

```powershell
.\deploy.ps1 init
.\deploy.ps1 bucket
.\deploy.ps1 upload
.\deploy.ps1 cluster
.\deploy.ps1 workload
.\deploy.ps1 build
.\deploy.ps1 deploy
.\deploy.ps1 info
```

### 方式 3: Cloud Build 自动部署

```bash
# 推送到 GitHub main 分支
git push origin main
# 自动触发 Cloud Build → 构建 → 部署
```

---

## 🏗️ 架构设计

```
外网用户
    ↓
Google Cloud Load Balancer
    ↓
GKE Service (LoadBalancer)
    ↓
Pod (3-10 个副本)
    ├── init-container: 下载 config.yaml
    └── main-container: CLI Proxy API
        ├── 读取 /CLIProxyAPI/config.yaml （来自 Cloud Storage）
        ├── 使用 /root/.cli-proxy-api （来自 PVC）
        └── 写入 /CLIProxyAPI/logs （来自 PVC）
```

---

## 💾 配置管理方案

### 推荐：混合方案

**config.yaml → Cloud Storage Bucket**
- 优点: 简单、版本控制、成本低
- 流程: init-container 启动时一次性下载
- 更新: 上传新文件 + 重启 Pod

**API Keys → Google Secret Manager**
- 优点: 更安全、加密、审计日志
- 流程: Workload Identity 访问
- 更新: 创建新版本即可

**小型配置 → ConfigMap**
- 优点: K8s 原生
- 用途: 应用设置、环境变量

---

## 🔐 安全特性

✅ **网络安全**
- VPC 隔离
- 防火墙规则
- TLS/HTTPS (ManagedCertificate)

✅ **身份认证**
- Workload Identity（Pod ← 服务账户）
- RBAC（角色访问控制）
- 最小权限原则

✅ **数据保护**
- Secret Manager 加密
- Cloud Storage 加密
- 卷级加密
- 只读根文件系统

✅ **运行时安全**
- 非 root 用户
- 无特权容器
- 资源限制

---

## 📊 资源规划

### 初始配置
```
GKE 集群:
  - 节点: 3x n2-standard-4 (4 vCPU, 16GB RAM)
  - 自动扩展: 3-10 个节点
  
Pod 配置:
  - 初始副本: 3
  - 最大副本: 10
  - CPU 请求: 250m, 限制: 500m
  - 内存请求: 512Mi, 限制: 1Gi

存储:
  - auth 目录: 10Gi PVC
  - logs 目录: 20Gi PVC
```

### 成本估算（月度）
```
低配 (3 nodes):   ~$350
中配 (5 nodes):   ~$550
高配 (10 nodes):  ~$800

优化选项:
- 抢占式节点: -70% 成本
- 预留实例: -25-30% 成本
```

---

## 📝 关键操作

### 更新应用

```bash
# 方法 1: Git 推送（自动）
git push origin main

# 方法 2: 手动部署
docker build -t gcr.io/$PROJECT_ID/cli-proxy-api:1.1.0 .
docker push gcr.io/$PROJECT_ID/cli-proxy-api:1.1.0
kubectl set image deployment/cli-proxy-api \
  cli-proxy-api=gcr.io/$PROJECT_ID/cli-proxy-api:1.1.0 \
  -n cli-proxy-api
```

### 更新配置

```bash
# 编辑
vim config.yaml

# 上传
gsutil cp config.yaml gs://$BUCKET_NAME/

# 重启 Pod（自动下载新配置）
kubectl rollout restart deployment/cli-proxy-api -n cli-proxy-api
```

### 回滚

```bash
# 查看历史
kubectl rollout history deployment/cli-proxy-api -n cli-proxy-api

# 回滚
kubectl rollout undo deployment/cli-proxy-api -n cli-proxy-api

# 回滚到特定版本
kubectl rollout undo deployment/cli-proxy-api -n cli-proxy-api --to-revision=3
```

---

## ✅ 部署清单

- [ ] GCP 项目创建
- [ ] API 启用
- [ ] 服务账户创建
- [ ] Cloud Storage Bucket
- [ ] config.yaml 准备
- [ ] GKE 集群创建
- [ ] Workload Identity
- [ ] Docker 镜像构建
- [ ] 镜像推送 GCR
- [ ] 资源部署
- [ ] DNS 配置
- [ ] HTTPS 证书
- [ ] 日志配置
- [ ] 备份策略
- [ ] 文档完成

---

## 📚 文档导航

| 文档 | 用途 | 详度 |
|------|------|------|
| **gcloud-setup.md** | 完整部署指南 | ⭐⭐⭐⭐⭐ |
| **DEPLOYMENT_SUMMARY.md** | 架构总结 | ⭐⭐⭐⭐ |
| **QUICK_REFERENCE.txt** | 命令速查 | ⭐⭐⭐ |
| **deploy.ps1** / **deploy.sh** | 自动化脚本 | ⭐⭐⭐⭐⭐ |
| **k8s-deployment.yaml** | K8s 配置 | ⭐⭐⭐ |
| **cloudbuild.yaml** | CI/CD 配置 | ⭐⭐ |

---

## 🆘 常见问题

**Q: 如何更新 config.yaml？**
A: 上传新文件到 Bucket，然后 `kubectl rollout restart` 重启 Pod

**Q: 如何回滚应用？**
A: `kubectl rollout undo deployment/cli-proxy-api -n cli-proxy-api`

**Q: 如何查看日志？**
A: `kubectl logs -f -l app=cli-proxy-api -n cli-proxy-api`

**Q: 如何访问 API？**
A: 获取 LoadBalancer IP: `kubectl get svc -n cli-proxy-api`

**Q: 成本太高怎么办？**
A: 使用抢占式节点或预留实例，可节省 25-70% 成本

---

## 📞 支持资源

- [GKE 官方文档](https://cloud.google.com/kubernetes-engine/docs)
- [Cloud Build 文档](https://cloud.google.com/build/docs)
- [Kubernetes 文档](https://kubernetes.io/docs/)
- [CLIProxyAPI 项目](https://github.com/xiyi-666/CLIProxyAPI)

---

## 🎯 下一步

1. **阅读**: `gcloud-setup.md` 了解详细步骤
2. **准备**: 编辑 `config.yaml` 填入 API keys
3. **部署**: 运行 `deploy.ps1 full` 或 `deploy.sh full`
4. **验证**: 检查 Pod 运行状态和日志
5. **监控**: 配置 Cloud Logging 和 Monitoring
6. **优化**: 根据实际使用调整资源

---

**创建时间**: 2024-12-15  
**版本**: 1.0.0  
**维护者**: CLI Proxy API Team  
**语言**: Go 1.24  
**容器**: Docker / Kubernetes
