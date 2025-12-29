#!/bin/bash
# Server Toolkit Helper Functions
# Version: 1.1.0

# ===== 工作目录保护（强制要求） =====
WORKDIR="/srv/server-toolkit"
# 确保工作目录存在
mkdir -p "$WORKDIR" 2>/dev/null || true
# 强制设置工作目录，如果失败则修改权限（非致命错误）
if ! cd "$WORKDIR" 2>/dev/null; then
    # 如果无法进入，尝试修复权限
    chmod 755 "$WORKDIR" 2>/dev/null || true
    mkdir -p "$WORKDIR" 2>/dev/null || true
    cd "$WORKDIR" 2>/dev/null || true
fi
# ====================================

CONFIG_VERSION="1.1.0"
TOOLKIT_REPO="https://github.com/wuyilingwei/server-toolkit"
RAW_REPO_URL="https://raw.githubusercontent.com/wuyilingwei/server-toolkit/main"
DEFAULT_INSTALL_DIR="/srv/server-toolkit"
DEFAULT_VAULT_URL="https://vault.wuyilingwei.com/api/data"

# ANSI Color Codes
COLOR_RESET="\033[0m"
COLOR_BLUE="\033[1;34m"
COLOR_GREEN="\033[1;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_RED="\033[1;31m"
COLOR_CYAN="\033[1;36m"

# 检查依赖
check_dependencies() {
    local missing_deps=()
    
    for cmd in curl jq free df; do
        if ! command -v $cmd &> /dev/null; then
            missing_deps+=($cmd)
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo -e "${COLOR_RED}错误: 缺少必要的依赖工具: ${missing_deps[*]}${COLOR_RESET}"
        echo "请使用以下命令安装: sudo apt install ${missing_deps[*]}"
        return 1
    fi
    return 0
}

# 从 /etc/environment 读取配置
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

# 设置配置到 /etc/environment
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

# 获取设备 UUID
get_device_uuid() {
    get_config_value "SYS_DEVICE_UUID" "未配置"
}

# 获取 Vault URL
get_vault_url() {
    get_config_value "SYS_VAULT_URL" "$DEFAULT_VAULT_URL"
}

# 获取安装目录
get_install_dir() {
    get_config_value "SYS_TOOLKIT_DIR" "$DEFAULT_INSTALL_DIR"
}

# 获取远程仓库 URL
get_remote_repo() {
    get_config_value "SYS_TOOLKIT_REPO" "$TOOLKIT_REPO"
}

# 获取公网 IPv4
get_public_ipv4() {
    local ipv4=$(curl -4 -s -m 5 https://api.ipify.org 2>/dev/null)
    if [ -z "$ipv4" ]; then
        ipv4=$(curl -4 -s -m 5 https://ifconfig.me 2>/dev/null)
    fi
    echo "${ipv4:-N/A}"
}

# 获取公网 IPv6
get_public_ipv6() {
    local ipv6=$(curl -6 -s -m 5 https://api64.ipify.org 2>/dev/null)
    if [ -z "$ipv6" ]; then
        ipv6=$(curl -6 -s -m 5 https://ifconfig.me 2>/dev/null)
    fi
    echo "${ipv6:-N/A}"
}

# 获取内存使用情况
get_memory_info() {
    local mem_info=$(free -h | grep Mem:)
    local mem_total=$(echo $mem_info | awk '{print $2}')
    local mem_used=$(echo $mem_info | awk '{print $3}')
    local mem_percent=$(free | grep Mem: | awk '{printf("%.0f", $3/$2 * 100)}')
    echo "$mem_used / $mem_total (${mem_percent}%)"
}

# 获取存储使用情况
get_storage_info() {
    local disk_info=$(df -h / | tail -1)
    local disk_total=$(echo $disk_info | awk '{print $2}')
    local disk_used=$(echo $disk_info | awk '{print $3}')
    local disk_percent=$(echo $disk_info | awk '{print $5}')
    echo "$disk_used / $disk_total ($disk_percent)"
}

# 版本比较 (返回 0 表示 v1 >= v2)
version_ge() {
    local v1="$1"
    local v2="$2"
    
    # 移除 'v' 前缀
    v1="${v1#v}"
    v2="${v2#v}"
    
    printf '%s\n%s\n' "$v2" "$v1" | sort -V -C
    return $?
}

# 检查远程是否有更新
check_remote_update() {
    local install_dir=$(get_install_dir)
    
    # 获取本地版本
    local local_config=$(read_repo_config)
    local local_version=$(echo "$local_config" | jq -r '.version // "0.0.0"')
    
    # 获取远程版本
    local remote_config=$(curl -s -m 5 "$RAW_REPO_URL/config.json")
    if [ -z "$remote_config" ] || ! echo "$remote_config" | jq -e . >/dev/null 2>&1; then
        return 1 # 无法获取远程配置
    fi
    
    local remote_version=$(echo "$remote_config" | jq -r '.version // "0.0.0"')
    
    # 比较版本 (如果 remote > local，返回 0)
    if version_ge "$remote_version" "$local_version" && [ "$remote_version" != "$local_version" ]; then
        return 0
    else
        return 1
    fi
}

# 从 Vault API 获取数据
vault_api_call() {
    local ops="$1"
    local vault_url=$(get_vault_url)
    local device_uuid=$(get_device_uuid)
    
    if [ "$device_uuid" = "未配置" ]; then
        return 1
    fi
    
    local response=$(curl -s -m 10 -X POST "$vault_url" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $device_uuid" \
        -d "$ops" 2>/dev/null)
    
    if [ $? -eq 0 ] && [ -n "$response" ]; then
        echo "$response"
        return 0
    fi
    
    return 1
}

# 读取本地 config.json
read_local_config() {
    local install_dir=$(get_install_dir)
    local config_file="$install_dir/config.json"
    
    if [ -f "$config_file" ]; then
        cat "$config_file"
    else
        echo "{}"
    fi
}

# 读取仓库 config.json
read_repo_config() {
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local config_file="$script_dir/config.json"
    
    if [ -f "$config_file" ]; then
        cat "$config_file"
    else
        echo "{}"
    fi
}

# 从远程仓库下载文件
download_from_repo() {
    local remote_path="$1"
    local local_path="$2"
    local url="$RAW_REPO_URL/$remote_path"
    
    # 创建父目录
    mkdir -p "$(dirname "$local_path")"
    
    if curl -s -L -o "$local_path" "$url"; then
        return 0
    else
        return 1
    fi
}

# 显示系统信息
show_system_info() {
    echo ""
    echo -e "${COLOR_CYAN}==================================================${COLOR_RESET}"
    echo -e "${COLOR_BLUE}           Server Toolkit v${CONFIG_VERSION}${COLOR_RESET}"
    echo -e "${COLOR_CYAN}==================================================${COLOR_RESET}"
    
    echo -e "${COLOR_GREEN}[网络信息]${COLOR_RESET}"
    echo -e "  公网 IPv4: $(get_public_ipv4)"
    echo -e "  公网 IPv6: $(get_public_ipv6)"
    echo ""
    
    echo -e "${COLOR_GREEN}[系统资源]${COLOR_RESET}"
    echo -e "  内存使用: $(get_memory_info)"
    echo -e "  存储使用: $(get_storage_info)"
    echo ""
    
    echo -e "${COLOR_GREEN}[配置信息]${COLOR_RESET}"
    echo -e "  设备 UUID: $(get_device_uuid)"
    echo -e "  Vault URL: $(get_vault_url)"
    echo -e "  安装目录: $(get_install_dir)"
    echo -e "  配置版本: v${CONFIG_VERSION}"
    echo ""
}

# 读取已安装模块配置
read_installed_config() {
    local install_dir=$(get_install_dir)
    local installed_file="$install_dir/installed.json"
    
    if [ -f "$installed_file" ]; then
        cat "$installed_file"
    else
        echo '{"modules":[]}'
    fi
}

# 保存已安装模块配置
write_installed_config() {
    local content="$1"
    local install_dir=$(get_install_dir)
    local installed_file="$install_dir/installed.json"
    
    # 确保目录存在
    mkdir -p "$install_dir"
    
    echo "$content" > "$installed_file"
}

# 获取已安装模块的版本
get_installed_version() {
    local module_id="$1"
    local installed=$(read_installed_config)
    
    local version=$(echo "$installed" | jq -r --arg id "$module_id" '.modules[] | select(.id == $id) | .version')
    
    # 如果版本为空或null，返回"未安装"
    if [ -z "$version" ] || [ "$version" = "null" ]; then
        echo "未安装"
    else
        echo "$version"
    fi
}

# 记录模块安装
register_module_install() {
    local module_id="$1"
    local version="$2"
    local timestamp="$(date -Iseconds)"
    local installed=$(read_installed_config)
    
    # 移除旧记录
    installed=$(echo "$installed" | jq --arg id "$module_id" 'del(.modules[] | select(.id == $id))')
    
    # 添加新记录 - 使用 jq 参数避免 JSON 注入
    installed=$(echo "$installed" | jq --arg id "$module_id" --arg ver "$version" --arg ts "$timestamp" \
        '.modules += [{"id": $id, "version": $ver, "installed_at": $ts}]')
    
    write_installed_config "$installed"
}

# 检查模块是否已安装
is_module_installed() {
    local module_id="$1"
    local version=$(get_installed_version "$module_id")
    
    if [ "$version" != "未安装" ]; then
        return 0
    else
        return 1
    fi
}

# 日志函数
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
