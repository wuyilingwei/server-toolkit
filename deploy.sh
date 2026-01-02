#!/bin/bash
# Server Toolkit Deployment Script
# This script should be run directly from remote URL
# Usage: curl -sSL https://raw.githubusercontent.com/wuyilingwei/server-toolkit/main/deploy.sh | sudo bash

set -e

# Configuration
INSTALL_DIR="/srv/server-toolkit"
SCRIPTS_DIR="$INSTALL_DIR/scripts"
STORAGE_DIR="$INSTALL_DIR/storage"
BIN_LINK="/usr/local/bin/server-toolkit"
REPO_URL="https://github.com/wuyilingwei/server-toolkit"
RAW_REPO_URL="https://raw.githubusercontent.com/wuyilingwei/server-toolkit/main"

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
    
    # 导出到当前环境 (safely quoted)
    export "${key}=${value}"
}

get_device_uuid() {
    get_config_value "SYS_DEVICE_UUID" "未配置"
}

get_vault_url() {
    get_config_value "SYS_VAULT_URL" "未配置"
}

main() {
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
    
    # Whitelist of allowed packages
    local allowed_packages="curl jq procps git"
    local missing_pkgs=()
    
    # Check curl
    if ! command -v curl &> /dev/null; then
        missing_pkgs+=(curl)
    fi
    
    # Check jq
    if ! command -v jq &> /dev/null; then
        missing_pkgs+=(jq)
    fi
    
    # Check free (part of procps package)
    if ! command -v free &> /dev/null; then
        missing_pkgs+=(procps)
    fi
    
    # Check git
    if ! command -v git &> /dev/null; then
        missing_pkgs+=(git)
    fi
    
    # Note: df is part of coreutils which is essential and should already be installed
    # Note: free is part of procps package
    
    if [ ${#missing_pkgs[@]} -ne 0 ]; then
        # Validate all packages are in whitelist
        for pkg in "${missing_pkgs[@]}"; do
            if [[ ! " $allowed_packages " =~ " $pkg " ]]; then
                log_error "不允许安装的软件包: $pkg"
                return 1
            fi
        done
        
        log_warning "缺少以下软件包: ${missing_pkgs[*]}"
        log_info "正在自动安装依赖..."
        
        # Update package list
        apt-get update -qq || {
            log_error "无法更新软件包列表"
            return 1
        }
        
        # Install missing packages (validated against whitelist)
        apt-get install -y -qq "${missing_pkgs[@]}" || {
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

# 创建主目录
log_info "创建主目录: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

# 克隆或更新仓库到 scripts 目录
log_info "克隆仓库到 $SCRIPTS_DIR"

# 如果 scripts 目录已存在，强制删除并重新克隆
if [ -d "$SCRIPTS_DIR" ]; then
    log_warning "检测到已存在的 scripts 目录，将强制重新克隆"
    rm -rf "$SCRIPTS_DIR"
fi

# 克隆仓库
if git clone "$REPO_URL" "$SCRIPTS_DIR"; then
    log_success "仓库克隆成功"
else
    log_error "仓库克隆失败"
    exit 1
fi

# 复制核心文件到主目录
log_info "复制核心文件到主目录..."
cp "$SCRIPTS_DIR/menu.sh" "$INSTALL_DIR/"
cp "$SCRIPTS_DIR/config.json" "$INSTALL_DIR/"
cp "$SCRIPTS_DIR/helper.sh" "$INSTALL_DIR/"

chmod +x "$INSTALL_DIR/menu.sh"
chmod +x "$INSTALL_DIR/helper.sh"

# 创建 storage 目录
log_info "创建持久化数据目录: $STORAGE_DIR"
mkdir -p "$STORAGE_DIR"

# 创建 server-toolkit 命令
log_info "创建系统命令: server-toolkit"
cat > "$BIN_LINK" << EOF
#!/bin/bash
bash "$INSTALL_DIR/menu.sh" "\$@"
EOF
chmod +x "$BIN_LINK"

# 配置环境变量
log_info "配置环境变量..."

# 安装目录
set_config_value "SYS_TOOLKIT_DIR" "$INSTALL_DIR"

# 远程仓库
set_config_value "SYS_TOOLKIT_REPO" "https://github.com/wuyilingwei/server-toolkit"

# Vault URL
log_info "配置 Vault URL"
current_vault_url=$(get_vault_url)
log_info "当前 Vault URL: $current_vault_url"

if [ "$current_vault_url" != "未配置" ]; then
    log_success "Vault URL 已配置为: $current_vault_url，跳过配置"
else
    echo -n "请输入 Vault URL: "
    read custom_url

    if [ -n "$custom_url" ]; then
        set_config_value "SYS_VAULT_URL" "$custom_url"
    else
        log_error "未输入 Vault URL，部署中止"
        exit 1
    fi
    log_success "Vault URL 已设置: $(get_vault_url)"
fi

# 设备 UUID（如果未设置）
if [ "$(get_device_uuid)" = "未配置" ]; then
    echo ""
    log_info "配置设备 UUID"
    echo -n "请输入设备 UUID (用于 Vault 认证): "
    read device_uuid
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
echo "安装目录: $INSTALL_DIR"
echo "  ├── menu.sh         (主菜单程序)"
echo "  ├── config.json     (配置文件)"
echo "  ├── helper.sh       (辅助函数)"
echo "  ├── scripts/        (Git 仓库目录)"
echo "  └── storage/        (持久化数据目录)"
echo ""
echo "使用以下命令启动工具包菜单："
echo -e "  ${COLOR_CYAN}server-toolkit${COLOR_RESET}"
    echo ""
}

main "$@"
