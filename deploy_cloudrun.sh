#!/bin/bash
# Cloud Run 部署助手脚本 (Artifact Registry + Cloud Build)
# 自动化设置 Artifact Registry 并提交 Cloud Build 构建

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

# 检查必要工具
check_prerequisites() {
    log_info "检查必要工具..."
    local tools=("gcloud")
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            log_error "$tool 未安装，请先安装 Google Cloud SDK"
            return 1
        fi
    done
    log_success "所有必要工具已安装"
}

# 初始化配置
init_config() {
    # 获取当前项目 ID
    PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
    if [ -z "$PROJECT_ID" ]; then
        log_error "未设置默认 GCP 项目，请运行 'gcloud config set project YOUR_PROJECT_ID'"
        return 1
    fi
    
    REGION="europe-west1"
    REPO_NAME="cli-proxy-repo"
    SERVICE_NAME="cli-proxy-api"
    
    log_info "当前配置:"
    echo "  Project ID: $PROJECT_ID"
    echo "  Region:     $REGION"
    echo "  Repository: $REPO_NAME"
    echo "  Service:    $SERVICE_NAME"
}

# 启用必要的 API
enable_apis() {
    log_info "启用必要的 Google Cloud API..."
    gcloud services enable \
        artifactregistry.googleapis.com \
        cloudbuild.googleapis.com \
        run.googleapis.com \
        --project "$PROJECT_ID"
    log_success "API 已启用"
}

# 创建 Artifact Registry 仓库
create_repo() {
    log_info "检查 Artifact Registry 仓库..."
    
    if gcloud artifacts repositories describe "$REPO_NAME" \
        --project="$PROJECT_ID" \
        --location="$REGION" &>/dev/null; then
        log_success "仓库 $REPO_NAME 已存在"
    else
        log_info "创建仓库 $REPO_NAME ..."
        gcloud artifacts repositories create "$REPO_NAME" \
            --project="$PROJECT_ID" \
            --repository-format=docker \
            --location="$REGION" \
            --description="Docker repository for CLI Proxy API"
        log_success "仓库 $REPO_NAME 已创建"
    fi
}

# 提交 Cloud Build 构建
submit_build() {
    log_info "准备提交 Cloud Build 构建..."
    
    # 读取 .env 文件中的变量作为 substitutions
    local substitutions=""
    
    if [ -f ".env" ]; then
        log_info "从 .env 文件读取环境变量..."
        # 简单的 .env 解析器，忽略注释和空行
        while IFS='=' read -r key value; do
            # 跳过注释和空行
            [[ "$key" =~ ^#.*$ ]] && continue
            [[ -z "$key" ]] && continue
            
            # 去除可能的引号
            value=$(echo "$value" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
            
            # 检查是否是 cloudbuild.yaml 中定义的变量
            case "$key" in
                MANAGEMENT_PASSWORD|PGSTORE_DSN|PGSTORE_SCHEMA|GITSTORE_GIT_URL|GITSTORE_GIT_USERNAME|GITSTORE_GIT_TOKEN|OBJECTSTORE_ENDPOINT|OBJECTSTORE_BUCKET|OBJECTSTORE_ACCESS_KEY|OBJECTSTORE_SECRET_KEY)
                    if [ -n "$substitutions" ]; then
                        substitutions="${substitutions},_${key}=${value}"
                    else
                        substitutions="_${key}=${value}"
                    fi
                    ;;
            esac
        done < ".env"
    else
        log_warning ".env 文件不存在，将使用默认空值进行构建"
    fi
    
    log_info "提交构建到 Cloud Build..."
    
    local cmd="gcloud builds submit --config cloudbuild.yaml --project $PROJECT_ID --region $REGION"
    
    if [ -n "$substitutions" ]; then
        cmd="$cmd --substitutions $substitutions"
    fi
    
    echo "执行命令: $cmd"
    eval "$cmd"
    
    if [ $? -eq 0 ]; then
        log_success "构建和部署成功！"
        
        # 获取 Cloud Run 服务 URL
        local service_url=$(gcloud run services describe $SERVICE_NAME --platform managed --region $REGION --format 'value(status.url)')
        log_info "服务 URL: $service_url"
    else
        log_error "构建失败"
        return 1
    fi
}

# 主函数
main() {
    check_prerequisites || return 1
    init_config || return 1
    
    echo ""
    read -p "确认部署到上述项目和区域？(y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "已取消"
        return 0
    fi
    
    enable_apis
    create_repo
    submit_build
}

main "$@"