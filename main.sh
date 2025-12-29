#!/bin/bash
# Server Toolkit Main Entry Script
# Version: 1.0.0

VERSION="v1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_API_URL="https://vault.wuyilingwei.com/api/data"

# ANSI Color Codes
COLOR_RESET="\033[0m"
COLOR_BLUE="\033[1;34m"
COLOR_GREEN="\033[1;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_RED="\033[1;31m"
COLOR_CYAN="\033[1;36m"

# 依赖检查
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
        exit 1
    fi
}

# 获取公网 IPv4 地址
get_public_ipv4() {
    local ipv4=$(curl -4 -s -m 5 https://api.ipify.org 2>/dev/null)
    if [ -z "$ipv4" ]; then
        ipv4=$(curl -4 -s -m 5 https://ifconfig.me 2>/dev/null)
    fi
    echo "${ipv4:-N/A}"
}

# 获取公网 IPv6 地址
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

# 获取设备 UUID
get_device_uuid() {
    if [ -f /etc/environment ]; then
        local uuid=$(grep "SYS_DEVICE_UUID" /etc/environment | cut -d'=' -f2 | tr -d '"' | tr -d "'")
        echo "${uuid:-未配置}"
    else
        echo "未配置"
    fi
}

# 获取 Vault URL
get_vault_url() {
    if [ -f /etc/environment ]; then
        local vault_url=$(grep "SYS_VAULT_URL" /etc/environment | cut -d'=' -f2 | tr -d '"' | tr -d "'")
        echo "${vault_url:-$DEFAULT_API_URL}"
    else
        echo "$DEFAULT_API_URL"
    fi
}

# 从云端 API 获取操作列表
fetch_operations_from_cloud() {
    local device_uuid=$(get_device_uuid)
    local vault_url=$(get_vault_url)
    
    if [ "$device_uuid" = "未配置" ]; then
        return 1
    fi
    
    local response=$(curl -s -m 10 -X POST "$vault_url" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $device_uuid" \
        -d '{"ops": [{"id": "get_operations", "type": "read", "module": "toolkit", "key": "operations"}]}' 2>/dev/null)
    
    if [ $? -eq 0 ] && [ -n "$response" ]; then
        echo "$response" | jq -r '.[0].data.content' 2>/dev/null
        return $?
    fi
    
    return 1
}

# 获取本地备用操作列表
get_local_operations() {
    cat << 'EOF'
[
  {"id": 1, "name": "SSH 安全防护部署", "script": "ssh-security/deploy.sh"},
  {"id": 2, "name": "系统更新", "script": "system/update.sh"}
]
EOF
}

# 显示系统信息
show_system_info() {
    echo ""
    echo -e "${COLOR_CYAN}==================================================${COLOR_RESET}"
    echo -e "${COLOR_BLUE}           Server Toolkit ${VERSION}${COLOR_RESET}"
    echo -e "${COLOR_CYAN}==================================================${COLOR_RESET}"
    
    echo -e "${COLOR_GREEN}[网络信息]${COLOR_RESET}"
    echo -e "  公网 IPv4: $(get_public_ipv4)"
    echo -e "  公网 IPv6: $(get_public_ipv6)"
    echo ""
    
    echo -e "${COLOR_GREEN}[系统资源]${COLOR_RESET}"
    echo -e "  内存使用: $(get_memory_info)"
    echo -e "  存储使用: $(get_storage_info)"
    echo ""
    
    echo -e "${COLOR_GREEN}[设备信息]${COLOR_RESET}"
    echo -e "  设备 UUID: $(get_device_uuid)"
    echo -e "  脚本版本: ${VERSION}"
    echo ""
    
    echo -e "${COLOR_GREEN}[Vault 配置]${COLOR_RESET}"
    echo -e "  Vault URL: $(get_vault_url)"
    echo ""
}

# 显示操作菜单
show_menu() {
    local operations="$1"
    
    echo -e "${COLOR_CYAN}==================== 操作菜单 ====================${COLOR_RESET}"
    
    # 解析并显示操作列表
    local count=$(echo "$operations" | jq '. | length' 2>/dev/null)
    if [ $? -eq 0 ] && [ "$count" -gt 0 ]; then
        for i in $(seq 0 $((count - 1))); do
            local id=$(echo "$operations" | jq -r ".[$i].id" 2>/dev/null)
            local name=$(echo "$operations" | jq -r ".[$i].name" 2>/dev/null)
            echo -e "${COLOR_YELLOW}[$id]${COLOR_RESET} $name"
        done
    else
        echo -e "${COLOR_RED}错误: 无法解析操作列表${COLOR_RESET}"
    fi
    
    echo -e "${COLOR_YELLOW}[0]${COLOR_RESET} 退出"
    echo -e "${COLOR_CYAN}==================================================${COLOR_RESET}"
}

# 执行脚本
execute_script() {
    local script_path="$1"
    local full_path="$SCRIPT_DIR/$script_path"
    
    if [ ! -f "$full_path" ]; then
        echo -e "${COLOR_RED}错误: 脚本文件不存在: $full_path${COLOR_RESET}"
        return 1
    fi
    
    if [ ! -x "$full_path" ]; then
        chmod +x "$full_path"
    fi
    
    echo ""
    echo -e "${COLOR_GREEN}正在执行: $script_path${COLOR_RESET}"
    echo -e "${COLOR_CYAN}--------------------------------------------------${COLOR_RESET}"
    
    # 执行脚本
    bash "$full_path"
    local exit_code=$?
    
    echo -e "${COLOR_CYAN}--------------------------------------------------${COLOR_RESET}"
    
    if [ $exit_code -eq 0 ]; then
        echo -e "${COLOR_GREEN}脚本执行完成${COLOR_RESET}"
    else
        echo -e "${COLOR_YELLOW}脚本退出码: $exit_code${COLOR_RESET}"
    fi
    
    return $exit_code
}

# 主交互循环
main_loop() {
    local operations
    
    # 尝试从云端获取操作列表
    echo -e "${COLOR_BLUE}正在从云端获取操作列表...${COLOR_RESET}"
    operations=$(fetch_operations_from_cloud)
    
    if [ $? -ne 0 ] || [ -z "$operations" ]; then
        echo -e "${COLOR_YELLOW}警告: 无法从云端获取操作列表，使用本地配置${COLOR_RESET}"
        operations=$(get_local_operations)
    else
        echo -e "${COLOR_GREEN}成功从云端获取操作列表${COLOR_RESET}"
    fi
    
    while true; do
        echo ""
        show_menu "$operations"
        echo -n "请输入操作编号: "
        read choice
        
        # 处理退出
        if [ "$choice" = "0" ]; then
            echo -e "${COLOR_GREEN}感谢使用 Server Toolkit！${COLOR_RESET}"
            exit 0
        fi
        
        # 验证输入是否为数字
        if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
            echo -e "${COLOR_RED}错误: 请输入有效的数字${COLOR_RESET}"
            continue
        fi
        
        # 查找对应的操作
        local script=$(echo "$operations" | jq -r ".[] | select(.id == $choice) | .script" 2>/dev/null)
        
        if [ -z "$script" ] || [ "$script" = "null" ]; then
            echo -e "${COLOR_RED}错误: 无效的操作编号${COLOR_RESET}"
            continue
        fi
        
        # 执行脚本
        execute_script "$script"
        
        # 询问是否继续
        echo ""
        echo -n "按 Enter 返回主菜单，或输入 'q' 退出: "
        read continue_choice
        
        if [ "$continue_choice" = "q" ] || [ "$continue_choice" = "Q" ]; then
            echo -e "${COLOR_GREEN}感谢使用 Server Toolkit！${COLOR_RESET}"
            exit 0
        fi
    done
}

# 主函数
main() {
    # 检查依赖
    check_dependencies
    
    # 显示系统信息
    show_system_info
    
    # 进入主循环
    main_loop
}

# 运行主函数
main
