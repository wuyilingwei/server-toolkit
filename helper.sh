#!/bin/bash
# Server Toolkit Helper Functions
# Version: 1.1.0

CONFIG_VERSION="1.1.0"
TOOLKIT_REPO="https://github.com/wuyilingwei/server-toolkit"
RAW_REPO_URL="https://raw.githubusercontent.com/wuyilingwei/server-toolkit/main"
DEFAULT_INSTALL_DIR="/srv/server-toolkit"

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
    get_config_value "SYS_VAULT_URL" "未配置"
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

# 获取 Swap 使用情况
get_swap_info() {
    # 一次性获取 swap 信息（包括数字和人类可读格式）
    local swap_line_numeric=$(free | grep Swap: 2>/dev/null)
    if [ -z "$swap_line_numeric" ]; then
        echo "N/A"
        return
    fi
    
    local swap_line_human=$(free -h | grep Swap: 2>/dev/null)
    local swap_total=$(echo "$swap_line_human" | awk '{print $2}')
    local swap_used=$(echo "$swap_line_human" | awk '{print $3}')
    
    # 检查是否有 Swap
    if [ "$swap_total" = "0B" ] || [ "$swap_total" = "0" ]; then
        echo "未配置"
        return
    fi
    
    # 从数字格式计算使用百分比（避免再次调用 free）
    local swap_percent=$(echo "$swap_line_numeric" | awk '{if($2>0) printf("%.0f", $3/$2 * 100); else print "0"}')
    echo "$swap_used / $swap_total (${swap_percent}%)"
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

# 获取当前代码版本Hash
get_current_hash() {
    local install_dir=$(get_install_dir)
    local scripts_dir="$install_dir/scripts"
    
    if [ -d "$scripts_dir/.git" ]; then
        cd "$scripts_dir" && git rev-parse --short HEAD 2>/dev/null || echo "unknown"
    else
        echo "no-git"
    fi
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
    echo -e "  Swap 使用: $(get_swap_info)"
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
        # 验证JSON格式
        if jq empty "$installed_file" 2>/dev/null; then
            cat "$installed_file"
        else
            # JSON损坏，重置为空配置并备份损坏的文件
            log_warning "检测到损坏的 installed.json，正在重置..."
            [ -f "$installed_file" ] && mv "$installed_file" "${installed_file}.backup.$(date +%s)"
            echo '{"modules":[]}'
        fi
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
    
    # 验证JSON格式后再写入
    if echo "$content" | jq empty 2>/dev/null; then
        echo "$content" > "$installed_file"
    else
        log_error "尝试写入无效的JSON内容，操作被拒绝"
        return 1
    fi
}

# 获取已安装模块的版本
get_installed_version() {
    local module_id="$1"
    local installed=$(read_installed_config)
    
    # 验证JSON格式
    if ! echo "$installed" | jq empty 2>/dev/null; then
        echo "未安装"
        return
    fi
    
    local version=$(echo "$installed" | jq -r --arg id "$module_id" '.modules[] | select(.id == $id) | .version' 2>/dev/null)
    
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
    
    # 验证输入的JSON
    if ! echo "$installed" | jq empty 2>/dev/null; then
        log_warning "installed.json 格式错误，重新初始化"
        installed='{"modules":[]}'
    fi
    
    # 移除旧记录
    installed=$(echo "$installed" | jq --arg id "$module_id" 'del(.modules[] | select(.id == $id))' 2>/dev/null) || {
        log_error "JSON处理失败，重新初始化配置"
        installed='{"modules":[]}'
    }
    
    # 添加新记录 - 使用 jq 参数避免 JSON 注入
    installed=$(echo "$installed" | jq --arg id "$module_id" --arg ver "$version" --arg ts "$timestamp" \
        '.modules += [{"id": $id, "version": $ver, "installed_at": $ts}]' 2>/dev/null) || {
        log_error "无法更新模块安装记录"
        return 1
    }
    
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

# ============================================================================
# 输入函数 (Input Functions)
# ============================================================================

# 输入函数 - 需要按 Enter 确认
# 用法: result=$(input_with_enter "提示信息" "默认值" "上次设置值(可选)")
# 返回: 用户输入值，或默认值/上次设置值
input_with_enter() {
    local prompt="$1"
    local default_value="$2"
    local previous_value="${3:-}"
    local user_input=""
    
    # 构建完整提示信息
    local full_prompt="$prompt"
    if [ -n "$previous_value" ]; then
        full_prompt="${full_prompt} (当前: $previous_value, 默认: $default_value): "
    else
        full_prompt="${full_prompt} (默认: $default_value): "
    fi
    
    # 读取用户输入
    read -r -p "$full_prompt" user_input
    
    # 处理输入优先级: 用户输入 > 上次设置 > 默认值
    if [ -n "$user_input" ]; then
        echo "$user_input"
    elif [ -n "$previous_value" ]; then
        echo "$previous_value"
    else
        echo "$default_value"
    fi
}

# 单字符输入函数 - 不需要按 Enter (y/n 等)
# 用法: result=$(input_single_char "提示信息" "默认值" "上次设置值(可选)")
# 返回: 单字符输入，或默认值/上次设置值
input_single_char() {
    local prompt="$1"
    local default_value="$2"
    local previous_value="${3:-}"
    local user_input=""
    
    # 构建完整提示信息
    local full_prompt="$prompt"
    if [ -n "$previous_value" ]; then
        full_prompt="${full_prompt} (当前: $previous_value, 默认: $default_value): "
    else
        full_prompt="${full_prompt} (默认: $default_value): "
    fi
    
    # 读取单字符输入 (如果支持 -n 选项)
    # 注意: 某些 shell 不支持 read -n，所以提供回退方案
    if read -n 1 -r -p "$full_prompt" user_input 2>/dev/null; then
        echo "" # 换行
        if [ -n "$user_input" ]; then
            echo "$user_input"
        elif [ -n "$previous_value" ]; then
            echo "$previous_value"
        else
            echo "$default_value"
        fi
    else
        # 回退到普通 read (兼容性)
        read -r -p "$full_prompt" user_input
        if [ -n "$user_input" ]; then
            # 只取第一个字符
            echo "${user_input:0:1}"
        elif [ -n "$previous_value" ]; then
            echo "$previous_value"
        else
            echo "$default_value"
        fi
    fi
}

# ============================================================================
# 定时任务函数 (Cron Functions)
# ============================================================================

# 添加定时任务
# 用法: cron_add "identifier" "time_expression" "command"
# 例如: cron_add "cert-sync" "0 * * * *" "/path/to/script.sh"
# 注意: 
#   - identifier 不需要带 #，函数会自动添加
#   - 命令会自动添加环境变量加载 (. /etc/environment;)
cron_add() {
    local identifier="$1"
    local time_expr="$2"
    local command="$3"
    
    if [ -z "$identifier" ] || [ -z "$time_expr" ] || [ -z "$command" ]; then
        log_error "cron_add: 缺少必要参数 (identifier, time_expression, command)"
        return 1
    fi
    
    # 构建标识符标签
    local tag="#server-toolkit-${identifier}"
    
    # 构建完整的 cron 命令 (自动添加环境变量加载)
    local full_cmd="${time_expr} . /etc/environment; ${command} ${tag}"
    
    # 移除旧的任务
    cron_remove "$identifier"
    
    # 添加新任务
    local temp_cron="/tmp/cron_add_$$"
    (crontab -l 2>/dev/null || true) > "$temp_cron"
    echo "$full_cmd" >> "$temp_cron"
    
    if crontab "$temp_cron" 2>/dev/null; then
        rm -f "$temp_cron"
        log_success "定时任务已添加: $identifier"
        return 0
    else
        rm -f "$temp_cron"
        log_error "定时任务添加失败: $identifier"
        return 1
    fi
}

# 移除定时任务
# 用法: cron_remove "identifier"
# 例如: cron_remove "cert-sync"
# 注意: identifier 不需要带 #，函数会自动添加
cron_remove() {
    local identifier="$1"
    
    if [ -z "$identifier" ]; then
        log_error "cron_remove: 缺少 identifier 参数"
        return 1
    fi
    
    # 构建标识符标签
    local tag="#server-toolkit-${identifier}"
    
    # 移除所有带此标识符的行
    local temp_cron="/tmp/cron_remove_$$"
    if crontab -l 2>/dev/null | grep -v "$tag" > "$temp_cron"; then
        crontab "$temp_cron" 2>/dev/null || true
        rm -f "$temp_cron"
        return 0
    else
        # 如果 crontab 为空或 grep 失败，创建空 crontab
        rm -f "$temp_cron"
        return 0
    fi
}
