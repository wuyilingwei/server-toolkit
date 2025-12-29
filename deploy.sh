#!/bin/bash
# Server Toolkit Deployment Script
# This script should be run directly from remote URL
# Usage: curl -sSL https://raw.githubusercontent.com/wuyilingwei/server-toolkit/main/deploy.sh | sudo bash

set -e

# Configuration
INSTALL_DIR="/srv/server-toolkit"
BIN_LINK="/usr/local/bin/server-toolkit"
REPO_URL="https://github.com/wuyilingwei/server-toolkit"
TEMP_DIR="/tmp/server-toolkit-$$"
DEFAULT_VAULT_URL="https://vault.wuyilingwei.com/api/data"

# Color codes
COLOR_RESET="\033[0m"
COLOR_BLUE="\033[1;34m"
COLOR_GREEN="\033[1;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_RED="\033[1;31m"
COLOR_CYAN="\033[1;36m"

# Logging functions
log_info() {
    echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $1"
}

log_success() {
    echo -e "${COLOR_GREEN}[成功]${COLOR_RESET} $1"
}

log_warning() {
    echo -e "${COLOR_YELLOW}[警告]${COLOR_RESET} $1"
}

log_error() {
    echo -e "${COLOR_RED}[错误]${COLOR_RESET} $1"
}

# Configuration helper functions (inline for standalone operation)
get_config_value() {
    local key="$1"
    local default="$2"
    
    if [ -f /etc/environment ]; then
        local value=$(grep "^${key}=" /etc/environment | cut -d'=' -f2- | tr -d '"' | tr -d "'")
        echo "${value:-$default}"
    else
        echo "$default"
    fi
}

set_config_value() {
    local key="$1"
    local value="$2"
    
    if [ ! -f /etc/environment ]; then
        touch /etc/environment
    fi
    
    # 删除旧值
    sed -i "/^${key}=/d" /etc/environment 2>/dev/null
    
    # 添加新值
    echo "${key}=\"${value}\"" >> /etc/environment
    
    # 导出到当前环境
    export ${key}="${value}"
}

get_device_uuid() {
    get_config_value "SYS_DEVICE_UUID" "未配置"
}

get_vault_url() {
    get_config_value "SYS_VAULT_URL" "$DEFAULT_VAULT_URL"
}

echo ""
echo -e "${COLOR_CYAN}==================================================${COLOR_RESET}"
echo -e "${COLOR_BLUE}    Server Toolkit 远程部署脚本${COLOR_RESET}"
echo -e "${COLOR_CYAN}==================================================${COLOR_RESET}"
echo ""

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then 
    log_error "此脚本需要 root 权限运行"
    echo "请使用: curl -sSL https://raw.githubusercontent.com/wuyilingwei/server-toolkit/main/deploy.sh | sudo bash"
    exit 1
fi

# Install dependencies automatically
install_dependencies() {
    log_info "检查并安装系统依赖..."
    
    # Check if apt-get is available (Debian/Ubuntu-based systems)
    if ! command -v apt-get &> /dev/null; then
        log_error "此脚本目前仅支持基于 Debian/Ubuntu 的系统"
        return 1
    fi
    
    local missing_pkgs=()
    
    # Check curl
    if ! command -v curl &> /dev/null; then
        missing_pkgs+=(curl)
    fi
    
    # Check jq
    if ! command -v jq &> /dev/null; then
        missing_pkgs+=(jq)
    fi
    
    # Check git
    if ! command -v git &> /dev/null; then
        missing_pkgs+=(git)
    fi
    
    # Check free (part of procps package)
    if ! command -v free &> /dev/null; then
        missing_pkgs+=(procps)
    fi
    
    # Note: df is part of coreutils which is essential and should already be installed
    
    if [ ${#missing_pkgs[@]} -ne 0 ]; then
        log_warning "缺少以下软件包: ${missing_pkgs[*]}"
        log_info "正在自动安装依赖..."
        
        # Update package list
        apt-get update -qq || {
            log_error "无法更新软件包列表"
            return 1
        }
        
        # Install missing packages
        apt-get install -y -qq ${missing_pkgs[*]} || {
            log_error "依赖安装失败"
            return 1
        }
        
        log_success "依赖安装完成"
    else
        log_success "所有依赖已满足"
    fi
    
    return 0
}

# Install dependencies
if ! install_dependencies; then
    log_error "依赖安装失败，无法继续"
    exit 1
fi

# Clone main module from remote repository
log_info "从远程仓库拉取主模块..."

# Clean up temp directory if exists
rm -rf "$TEMP_DIR" 2>/dev/null || true

# Clone repository
if git clone --quiet --depth 1 "$REPO_URL" "$TEMP_DIR"; then
    log_success "主模块拉取完成"
else
    log_error "主模块拉取失败"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# 部署主模块到 /srv
log_info "部署主模块到 $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

# 复制主模块文件
log_info "复制主模块文件..."
cp -r "$TEMP_DIR"/* "$INSTALL_DIR/" 2>/dev/null || true
chmod +x "$INSTALL_DIR"/*.sh 2>/dev/null || true
chmod +x "$INSTALL_DIR"/*/*.sh 2>/dev/null || true

# 初始化 git 仓库（如果不存在）
if [ ! -d "$INSTALL_DIR/.git" ]; then
    log_info "初始化 Git 仓库..."
    cd "$INSTALL_DIR"
    git init
    git remote add origin "$REPO_URL" 2>/dev/null || true
fi

# 创建本地 config.json（如果不存在）
if [ ! -f "$INSTALL_DIR/config.json" ]; then
    log_info "创建本地配置文件..."
    cat > "$INSTALL_DIR/config.json" << 'EOF'
{
  "installed_modules": [],
  "last_update": "",
  "local_version": "1.0.0"
}
EOF
fi

# 创建 server-toolkit 命令
log_info "创建系统命令: server-toolkit"
cat > "$BIN_LINK" << EOF
#!/bin/bash
cd "$INSTALL_DIR"
bash "$INSTALL_DIR/menu.sh" "\$@"
EOF
chmod +x "$BIN_LINK"

# 配置环境变量
log_info "配置环境变量..."

# 安装目录
set_config_value "SYS_TOOLKIT_DIR" "$INSTALL_DIR"

# 远程仓库
set_config_value "SYS_TOOLKIT_REPO" "https://github.com/wuyilingwei/server-toolkit"

# Vault URL（如果未设置）
if [ "$(get_vault_url)" = "$DEFAULT_VAULT_URL" ]; then
    echo ""
    log_info "配置 Vault URL"
    read -p "使用默认 Vault URL ($DEFAULT_VAULT_URL)? (y/n): " use_default
    
    if [ "$use_default" = "n" ] || [ "$use_default" = "N" ]; then
        echo -n "请输入 Vault URL: "
        read custom_url
        if [ -n "$custom_url" ]; then
            set_config_value "SYS_VAULT_URL" "$custom_url"
            log_success "Vault URL 已设置"
        else
            set_config_value "SYS_VAULT_URL" "$DEFAULT_VAULT_URL"
            log_info "使用默认 Vault URL"
        fi
    else
        set_config_value "SYS_VAULT_URL" "$DEFAULT_VAULT_URL"
        log_success "使用默认 Vault URL"
    fi
fi

# 设备 UUID（如果未设置）
if [ "$(get_device_uuid)" = "未配置" ]; then
    echo ""
    log_info "配置设备 UUID"
    echo -n "请输入设备 UUID (用于 Vault 认证): "
    read -s device_uuid
    echo ""
    
    if [ -n "$device_uuid" ]; then
        set_config_value "SYS_DEVICE_UUID" "$device_uuid"
        log_success "设备 UUID 已设置"
    else
        log_warning "未设置设备 UUID，部分功能可能无法使用"
    fi
fi

echo ""
echo -e "${COLOR_GREEN}==================================================${COLOR_RESET}"
echo -e "${COLOR_GREEN}              部署完成！${COLOR_RESET}"
echo -e "${COLOR_GREEN}==================================================${COLOR_RESET}"
echo ""
echo "主模块已部署到: $INSTALL_DIR"
echo "子模块由主模块统一管理"
echo ""
echo "使用以下命令启动工具包菜单："
echo -e "  ${COLOR_CYAN}server-toolkit${COLOR_RESET}"
echo ""

# Clean up temp directory
log_info "清理临时文件..."
rm -rf "$TEMP_DIR" 2>/dev/null || true
log_success "临时文件已清理"
