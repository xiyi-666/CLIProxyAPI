#!/usr/bin/env python3
"""
GCloud 部署前检查脚本
用于验证所有必要的工具和配置是否正确
"""

import subprocess
import sys
import os
from pathlib import Path

class Colors:
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    RED = '\033[91m'
    BLUE = '\033[94m'
    END = '\033[0m'

def print_header(text):
    print(f"\n{Colors.BLUE}{'='*60}")
    print(f"{text:^60}")
    print(f"{'='*60}{Colors.END}\n")

def print_success(text):
    print(f"{Colors.GREEN}✓ {text}{Colors.END}")

def print_error(text):
    print(f"{Colors.RED}✗ {text}{Colors.END}")

def print_warning(text):
    print(f"{Colors.YELLOW}⚠ {text}{Colors.END}")

def check_command(cmd, description):
    """检查命令是否存在"""
    try:
        result = subprocess.run(
            [cmd, '--version'] if cmd != 'gcloud' else [cmd, 'version'],
            capture_output=True,
            timeout=5
        )
        if result.returncode == 0:
            print_success(f"{description} 已安装")
            return True
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    
    print_error(f"{description} 未安装或无法访问")
    return False

def check_gcp_auth():
    """检查 GCP 认证"""
    try:
        result = subprocess.run(
            ['gcloud', 'auth', 'list'],
            capture_output=True,
            timeout=5
        )
        if result.returncode == 0 and b'ACTIVE' in result.stdout:
            print_success("GCP 认证已配置")
            return True
    except:
        pass
    
    print_error("GCP 认证未配置，请运行: gcloud auth login")
    return False

def check_gcp_project():
    """检查 GCP 项目"""
    project_id = os.environ.get('GCP_PROJECT_ID')
    
    if not project_id:
        print_warning("GCP_PROJECT_ID 环境变量未设置")
        return False
    
    try:
        result = subprocess.run(
            ['gcloud', 'config', 'get-value', 'project'],
            capture_output=True,
            timeout=5
        )
        if result.returncode == 0:
            current_project = result.stdout.decode().strip()
            if current_project == project_id:
                print_success(f"GCP 项目已设置: {project_id}")
                return True
            else:
                print_warning(f"当前项目: {current_project}, 目标项目: {project_id}")
                return True
    except:
        pass
    
    print_error(f"无法检查 GCP 项目: {project_id}")
    return False

def check_kubectl_connection():
    """检查 kubectl 连接"""
    try:
        result = subprocess.run(
            ['kubectl', 'cluster-info'],
            capture_output=True,
            timeout=5
        )
        if result.returncode == 0:
            print_success("kubectl 已连接到集群")
            return True
    except:
        pass
    
    print_warning("kubectl 未连接到集群（可能需要创建）")
    return False

def check_docker_connection():
    """检查 Docker 连接"""
    try:
        result = subprocess.run(
            ['docker', 'ps'],
            capture_output=True,
            timeout=5
        )
        if result.returncode == 0:
            print_success("Docker 守护进程运行中")
            return True
    except:
        pass
    
    print_error("Docker 守护进程未运行或无权限")
    return False

def check_config_file():
    """检查配置文件"""
    if Path('config.yaml').exists():
        print_success("config.yaml 存在")
        return True
    
    if Path('config.example.yaml').exists():
        print_warning("config.example.yaml 存在，但 config.yaml 缺失")
        print("  请运行: cp config.example.yaml config.yaml")
        return False
    
    print_error("config.yaml 和 config.example.yaml 都不存在")
    return False

def check_kubernetes_files():
    """检查 Kubernetes 配置文件"""
    files = ['k8s-deployment.yaml', 'cloudbuild.yaml']
    all_exist = True
    
    for file in files:
        if Path(file).exists():
            print_success(f"{file} 存在")
        else:
            print_error(f"{file} 不存在")
            all_exist = False
    
    return all_exist

def check_deploy_scripts():
    """检查部署脚本"""
    scripts = {
        'deploy.ps1': 'PowerShell 脚本',
        'deploy.sh': 'Bash 脚本'
    }
    
    for script, desc in scripts.items():
        if Path(script).exists():
            print_success(f"{desc} ({script}) 存在")
        else:
            print_warning(f"{desc} ({script}) 不存在")
    
    return True

def check_environment_variables():
    """检查必要的环境变量"""
    required_vars = {
        'GCP_PROJECT_ID': 'GCP 项目 ID',
    }
    
    optional_vars = {
        'GCP_REGION': 'GCP 地区 (默认: us-central1)',
        'GCP_ZONE': 'GCP 可用区 (默认: us-central1-a)',
        'GKE_CLUSTER_NAME': 'GKE 集群名称 (默认: cli-proxy-cluster)',
    }
    
    print("\n必要的环境变量:")
    all_set = True
    for var, desc in required_vars.items():
        if os.environ.get(var):
            print_success(f"{var}: {os.environ[var]}")
        else:
            print_error(f"{var} 未设置")
            all_set = False
    
    print("\n可选的环境变量:")
    for var, desc in optional_vars.items():
        if os.environ.get(var):
            print_success(f"{var}: {os.environ[var]}")
        else:
            print_warning(f"{var} 未设置 ({desc})")
    
    return all_set

def main():
    print_header("GCloud 部署前检查清单")
    
    checks = [
        ("必要工具检查", [
            ("gcloud", "Google Cloud SDK"),
            ("kubectl", "Kubernetes CLI"),
            ("docker", "Docker"),
            ("git", "Git"),
        ]),
        ("GCP 认证和项目", [
            ("gcp_auth", "GCP 认证"),
            ("gcp_project", "GCP 项目设置"),
        ]),
        ("本地连接", [
            ("docker", "Docker 连接"),
            ("kubectl", "kubectl 连接（可选）"),
        ]),
        ("项目文件", [
            ("config", "配置文件"),
            ("kubernetes", "Kubernetes 文件"),
            ("scripts", "部署脚本"),
        ]),
        ("环境变量", [
            ("env_vars", "环境变量"),
        ]),
    ]
    
    results = {}
    
    # 检查必要工具
    print_header("1️⃣  必要工具检查")
    for cmd, desc in checks[0][1]:
        results[cmd] = check_command(cmd, desc)
    
    # 检查 GCP 认证
    print_header("2️⃣  GCP 认证和项目")
    results['gcp_auth'] = check_gcp_auth()
    results['gcp_project'] = check_gcp_project()
    
    # 检查本地连接
    print_header("3️⃣  本地连接")
    results['docker_conn'] = check_docker_connection()
    results['kubectl_conn'] = check_kubectl_connection()
    
    # 检查文件
    print_header("4️⃣  项目文件")
    results['config'] = check_config_file()
    results['kubernetes'] = check_kubernetes_files()
    results['scripts'] = check_deploy_scripts()
    
    # 检查环境变量
    print_header("5️⃣  环境变量")
    results['env_vars'] = check_environment_variables()
    
    # 总结
    print_header("检查总结")
    
    critical_checks = [
        ('gcloud', "Google Cloud SDK"),
        ('kubectl', "Kubernetes CLI"),
        ('docker', "Docker"),
        ('git', "Git"),
        ('gcp_auth', "GCP 认证"),
        ('gcp_project', "GCP 项目"),
        ('config', "配置文件"),
        ('kubernetes', "Kubernetes 文件"),
        ('env_vars', "环境变量"),
    ]
    
    passed = sum(1 for check, _ in critical_checks if results.get(check, False))
    total = len(critical_checks)
    
    print(f"关键检查: {passed}/{total} 通过\n")
    
    for check, desc in critical_checks:
        status = "✓" if results.get(check, False) else "✗"
        color = Colors.GREEN if results.get(check, False) else Colors.RED
        print(f"{color}{status}{Colors.END} {desc}")
    
    print("\n" + "="*60)
    
    if passed == total:
        print_success("所有检查通过！可以开始部署了")
        print("\n建议的后续步骤:")
        print("1. 编辑 config.yaml，填入 API keys")
        print("2. 运行部署脚本:")
        
        system = sys.platform
        if system == "win32":
            print("   PowerShell: .\\deploy.ps1 full")
        else:
            print("   Bash: ./deploy.sh full")
        
        return 0
    else:
        print_error(f"检查失败！请修复上述问题后重试 ({total-passed} 项失败)")
        print("\n需要帮助？查看以下文档:")
        print("  • gcloud-setup.md - 详细部署指南")
        print("  • DEPLOYMENT_SUMMARY.md - 架构总结")
        print("  • QUICK_REFERENCE.txt - 快速参考")
        return 1

if __name__ == "__main__":
    sys.exit(main())
