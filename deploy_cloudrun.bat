@echo off
setlocal EnableDelayedExpansion

REM 设置代码页为 UTF-8 以支持中文输出
chcp 65001 >nul

REM Cloud Run 部署助手脚本 (Windows Batch 版)
REM 自动化设置 Artifact Registry 并提交 Cloud Build 构建

echo [INFO] 开始部署流程...

REM 1. 检查必要工具
where gcloud >nul 2>nul
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] gcloud 未安装，请先安装 Google Cloud SDK
    exit /b 1
)
echo [SUCCESS] 所有必要工具已安装

REM 2. 初始化配置
for /f "tokens=*" %%i in ('gcloud config get-value project 2^>nul') do set PROJECT_ID=%%i
if "%PROJECT_ID%"=="" (
    echo [ERROR] 未设置默认 GCP 项目，请运行 'gcloud config set project YOUR_PROJECT_ID'
    exit /b 1
)

set REGION=europe-west1
set REPO_NAME=cli-proxy-repo
set SERVICE_NAME=cli-proxy-api

echo [INFO] 当前配置:
echo   Project ID: !PROJECT_ID!
echo   Region:     !REGION!
echo   Repository: !REPO_NAME!
echo   Service:    !SERVICE_NAME!

echo.
set /p CONFIRM="确认部署到上述项目和区域？(y/n): "
if /i "%CONFIRM%" neq "y" (
    echo [INFO] 已取消
    exit /b 0
)

REM 3. 启用必要的 API
echo [INFO] 启用必要的 Google Cloud API...
call gcloud services enable artifactregistry.googleapis.com cloudbuild.googleapis.com run.googleapis.com --project "!PROJECT_ID!"
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] 启用 API 失败
    exit /b 1
)
echo [SUCCESS] API 已启用

REM 4. 创建 Artifact Registry 仓库
echo [INFO] 检查 Artifact Registry 仓库...
call gcloud artifacts repositories describe "!REPO_NAME!" --project="!PROJECT_ID!" --location="!REGION!" >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    echo [SUCCESS] 仓库 !REPO_NAME! 已存在
) else (
    echo [INFO] 创建仓库 !REPO_NAME! ...
    call gcloud artifacts repositories create "!REPO_NAME!" --project="!PROJECT_ID!" --repository-format=docker --location="!REGION!" --description="Docker repository for CLI Proxy API"
    if %ERRORLEVEL% NEQ 0 (
        echo [ERROR] 创建仓库失败
        exit /b 1
    )
    echo [SUCCESS] 仓库 !REPO_NAME! 已创建
)

REM 5. 准备 substitutions 变量
set SUBSTITUTIONS=
if exist .env (
    echo [INFO] 从 .env 文件读取环境变量...
    for /f "usebackq tokens=1* delims==" %%A in (".env") do (
        set "KEY=%%A"
        set "VALUE=%%B"
        
        REM 去除可能的引号
        set "VALUE=!VALUE:"=!"
        set "VALUE=!VALUE:'=!"

        REM 忽略注释行
        echo !KEY! | findstr /r "^#" >nul
        if errorlevel 1 (
             REM 匹配需要传递的变量
            if "!KEY!"=="MANAGEMENT_PASSWORD" set "MATCH=1"
            if "!KEY!"=="PGSTORE_DSN" set "MATCH=1"
            if "!KEY!"=="PGSTORE_SCHEMA" set "MATCH=1"
            if "!KEY!"=="GITSTORE_GIT_URL" set "MATCH=1"
            if "!KEY!"=="GITSTORE_GIT_USERNAME" set "MATCH=1"
            if "!KEY!"=="GITSTORE_GIT_TOKEN" set "MATCH=1"
            if "!KEY!"=="OBJECTSTORE_ENDPOINT" set "MATCH=1"
            if "!KEY!"=="OBJECTSTORE_BUCKET" set "MATCH=1"
            if "!KEY!"=="OBJECTSTORE_ACCESS_KEY" set "MATCH=1"
            if "!KEY!"=="OBJECTSTORE_SECRET_KEY" set "MATCH=1"
            
            if defined MATCH (
                if defined SUBSTITUTIONS (
                    set "SUBSTITUTIONS=!SUBSTITUTIONS!,_!KEY!=!VALUE!"
                ) else (
                    set "SUBSTITUTIONS=_!KEY!=!VALUE!"
                )
                set "MATCH="
            )
        )
    )
) else (
    echo [WARNING] .env 文件不存在，将使用默认空值进行构建
)

REM 获取当前日期用于构建参数
for /f %%i in ('powershell -command "Get-Date -Format 'yyyy-MM-dd'"') do set CURRENT_DATE=%%i

REM 获取 git commit hash
for /f %%i in ('git rev-parse --short HEAD 2^>nul') do set SHORT_SHA=%%i
if "%SHORT_SHA%"=="" set SHORT_SHA=unknown

REM 添加 _DATE 和 _SHORT_SHA 到 substitutions
if defined SUBSTITUTIONS (
    set "SUBSTITUTIONS=!SUBSTITUTIONS!,_DATE=!CURRENT_DATE!,_SHORT_SHA=!SHORT_SHA!"
) else (
    set "SUBSTITUTIONS=_DATE=!CURRENT_DATE!,_SHORT_SHA=!SHORT_SHA!"
)

REM 6. 提交构建
echo [INFO] 提交构建到 Cloud Build...
set CMD=gcloud builds submit --config cloudbuild.yaml --project !PROJECT_ID! --region !REGION!
if defined SUBSTITUTIONS (
    set CMD=!CMD! --substitutions !SUBSTITUTIONS!
)

echo 执行命令: !CMD!
call !CMD!

if %ERRORLEVEL% EQU 0 (
    echo [SUCCESS] 构建和部署成功！
    
    REM 获取 Cloud Run 服务 URL
    for /f "tokens=*" %%i in ('gcloud run services describe !SERVICE_NAME! --platform managed --region !REGION! --format "value(status.url)"') do set SERVICE_URL=%%i
    echo [INFO] 服务 URL: !SERVICE_URL!
) else (
    echo [ERROR] 构建失败
    exit /b 1
)

endlocal