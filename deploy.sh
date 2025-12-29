#!/bin/bash
# Server Toolkit Deployment Script
# This script installs the toolkit to /srv/server-toolkit

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/srv/server-toolkit"
BIN_LINK="/usr/local/bin/server-toolkit"

# Source config
source "$SCRIPT_DIR/config.sh"

echo -e "${COLOR_CYAN}==================================================${COLOR_RESET}"
echo -e "${COLOR_BLUE}    Server Toolkit 部署脚本 v${CONFIG_VERSION}${COLOR_RESET}"
echo -e "${COLOR_CYAN}==================================================${COLOR_RESET}"
echo ""

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then 
    log_error "此脚本需要 root 权限运行"
    echo "请使用: sudo bash deploy.sh"
    exit 1
fi

# 检查依赖
log_info "检查系统依赖..."
if ! check_dependencies; then
    exit 1
fi
log_success "依赖检查通过"

# 创建安装目录
log_info "创建安装目录: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

# 复制文件
log_info "复制工具包文件..."
cp -r "$SCRIPT_DIR"/* "$INSTALL_DIR/" 2>/dev/null || true
chmod +x "$INSTALL_DIR"/*.sh 2>/dev/null || true
chmod +x "$INSTALL_DIR"/*/*.sh 2>/dev/null || true

# 初始化 git 仓库（如果不存在）
if [ ! -d "$INSTALL_DIR/.git" ]; then
    log_info "初始化 Git 仓库..."
    cd "$INSTALL_DIR"
    git init
    git remote add origin "https://github.com/wuyilingwei/server-toolkit.git" 2>/dev/null || true
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
echo "使用以下命令启动工具包菜单："
echo -e "  ${COLOR_CYAN}server-toolkit${COLOR_RESET}"
echo ""
echo "或直接运行："
echo -e "  ${COLOR_CYAN}bash $INSTALL_DIR/menu.sh${COLOR_RESET}"
echo ""
