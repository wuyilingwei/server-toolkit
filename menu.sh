#!/bin/bash
# Server Toolkit Interactive Menu
# This is the main interface that runs from /srv/server-toolkit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source config
source "$SCRIPT_DIR/config.sh"

# 检查更新
check_for_updates() {
    log_info "检查工具包更新..."
    
    if check_remote_update; then
        log_warning "发现新版本！使用菜单选项 3 进行更新"
        return 0
    else
        log_info "当前已是最新版本"
        return 1
    fi
}

# 执行自更新
do_self_update() {
    echo ""
    echo -e "${COLOR_CYAN}==================== 工具包自更新 ====================${COLOR_RESET}"
    
    local install_dir=$(get_install_dir)
    
    if [ ! -d "$install_dir/.git" ]; then
        log_error "未检测到 Git 仓库，无法自动更新"
        log_info "请重新运行 deploy.sh 进行全新安装"
        return 1
    fi
    
    cd "$install_dir" || return 1
    
    log_info "拉取最新代码..."
    if git pull origin main 2>/dev/null || git pull origin master 2>/dev/null; then
        log_success "更新成功！"
        log_info "重新加载配置..."
        source "$install_dir/config.sh"
        return 0
    else
        log_error "更新失败"
        return 1
    fi
}

# 配置 Vault URL
configure_vault_url() {
    echo ""
    echo -e "${COLOR_CYAN}==================== 配置 Vault URL ====================${COLOR_RESET}"
    echo ""
    echo "当前 Vault URL: $(get_vault_url)"
    echo ""
    echo -n "请输入新的 Vault URL: "
    read new_url
    
    if [ -n "$new_url" ]; then
        set_config_value "SYS_VAULT_URL" "$new_url"
        log_success "Vault URL 已更新"
    else
        log_warning "未输入新 URL，保持原设置"
    fi
}

# 配置设备 UUID
configure_device_uuid() {
    echo ""
    echo -e "${COLOR_CYAN}==================== 配置设备 UUID ====================${COLOR_RESET}"
    echo ""
    
    local current_uuid=$(get_device_uuid)
    if [ "$current_uuid" != "未配置" ]; then
        echo "当前设备 UUID: ${current_uuid:0:8}..."
        echo ""
    fi
    
    echo -n "请输入新的设备 UUID: "
    read -s new_uuid
    echo ""
    
    if [ -n "$new_uuid" ]; then
        set_config_value "SYS_DEVICE_UUID" "$new_uuid"
        log_success "设备 UUID 已更新"
    else
        log_warning "未输入新 UUID，保持原设置"
    fi
}

# 更新模块
update_modules() {
    echo ""
    echo -e "${COLOR_CYAN}==================== 更新模块 ====================${COLOR_RESET}"
    log_info "模块更新功能将在后续版本实现"
    echo ""
}

# 显示当前配置
show_current_config() {
    echo ""
    echo -e "${COLOR_CYAN}==================== 当前配置 ====================${COLOR_RESET}"
    echo ""
    echo -e "${COLOR_GREEN}系统变量:${COLOR_RESET}"
    echo "  SYS_DEVICE_UUID: $(get_device_uuid | sed 's/\(.\{8\}\).*/\1.../')"
    echo "  SYS_VAULT_URL: $(get_vault_url)"
    echo "  SYS_TOOLKIT_DIR: $(get_install_dir)"
    echo "  SYS_TOOLKIT_REPO: $(get_remote_repo)"
    echo ""
    
    echo -e "${COLOR_GREEN}已安装模块:${COLOR_RESET}"
    local config=$(read_local_config)
    local modules=$(echo "$config" | jq -r '.modules[]?.id // empty' 2>/dev/null)
    
    if [ -z "$modules" ]; then
        # 从仓库配置读取
        config=$(read_repo_config)
        modules=$(echo "$config" | jq -r '.modules[]?.id // empty' 2>/dev/null)
    fi
    
    if [ -n "$modules" ]; then
        echo "$modules" | while read module; do
            echo "  - $module"
        done
    else
        echo "  (无已安装模块)"
    fi
    echo ""
}

# 执行模块脚本
execute_module() {
    local script_path="$1"
    local full_path="$SCRIPT_DIR/$script_path"
    
    if [ ! -f "$full_path" ]; then
        log_error "脚本文件不存在: $full_path"
        return 1
    fi
    
    if [ ! -x "$full_path" ]; then
        chmod +x "$full_path"
    fi
    
    echo ""
    log_info "正在执行: $script_path"
    echo -e "${COLOR_CYAN}--------------------------------------------------${COLOR_RESET}"
    
    # 执行脚本
    bash "$full_path"
    local exit_code=$?
    
    echo -e "${COLOR_CYAN}--------------------------------------------------${COLOR_RESET}"
    
    if [ $exit_code -eq 0 ]; then
        log_success "脚本执行完成"
    else
        log_warning "脚本退出码: $exit_code"
    fi
    
    return $exit_code
}

# 显示菜单
show_menu() {
    local config="$1"
    
    echo -e "${COLOR_CYAN}==================== 操作菜单 ====================${COLOR_RESET}"
    
    # 保留操作 (1-9)
    echo -e "${COLOR_YELLOW}[1]${COLOR_RESET} 配置 Vault URL"
    echo -e "${COLOR_YELLOW}[2]${COLOR_RESET} 配置设备 UUID"
    echo -e "${COLOR_YELLOW}[3]${COLOR_RESET} 工具包自更新"
    echo -e "${COLOR_YELLOW}[4]${COLOR_RESET} 更新模块"
    echo -e "${COLOR_YELLOW}[5]${COLOR_RESET} 显示当前配置"
    
    echo ""
    
    # 模块操作 (10+)
    local modules=$(echo "$config" | jq -c '.modules[]?' 2>/dev/null)
    
    if [ -n "$modules" ]; then
        echo "$modules" | while IFS= read -r module; do
            local id=$(echo "$module" | jq -r '.menu_id')
            local name=$(echo "$module" | jq -r '.name')
            local enabled=$(echo "$module" | jq -r '.enabled')
            
            if [ "$enabled" = "true" ]; then
                echo -e "${COLOR_YELLOW}[$id]${COLOR_RESET} $name"
            fi
        done
    fi
    
    echo ""
    echo -e "${COLOR_YELLOW}[0]${COLOR_RESET} 退出"
    echo -e "${COLOR_CYAN}==================================================${COLOR_RESET}"
}

# 主循环
main_loop() {
    # 读取配置
    local config=$(read_repo_config)
    
    # 检查配置版本兼容性
    local toolkit_version=$(echo "$config" | jq -r '.version // "1.0.0"')
    local min_version=$(echo "$config" | jq -r '.min_config_version // "1.0.0"')
    
    if ! version_ge "$CONFIG_VERSION" "$min_version"; then
        log_error "配置版本 v$CONFIG_VERSION 低于要求的最低版本 v$min_version"
        log_info "请运行 deploy.sh 更新工具包"
        exit 1
    fi
    
    # 检查更新（静默）
    check_remote_update &>/dev/null && HAS_UPDATE=true || HAS_UPDATE=false
    
    while true; do
        echo ""
        
        if [ "$HAS_UPDATE" = "true" ]; then
            log_warning "发现新版本可用！请使用选项 [3] 进行更新"
        fi
        
        show_menu "$config"
        echo -n "请输入操作编号: "
        read choice
        
        # 处理退出
        if [ "$choice" = "0" ]; then
            echo ""
            log_success "感谢使用 Server Toolkit！"
            exit 0
        fi
        
        # 验证输入
        if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
            log_error "请输入有效的数字"
            continue
        fi
        
        # 处理保留操作 (1-9)
        case "$choice" in
            1)
                configure_vault_url
                ;;
            2)
                configure_device_uuid
                ;;
            3)
                do_self_update && HAS_UPDATE=false
                # 重新加载配置
                config=$(read_repo_config)
                ;;
            4)
                update_modules
                ;;
            5)
                show_current_config
                ;;
            6|7|8|9)
                log_warning "此功能保留待用"
                ;;
            *)
                # 处理模块操作 (10+)
                if [ "$choice" -ge 10 ]; then
                    local module=$(echo "$config" | jq -c ".modules[] | select(.menu_id == $choice)" 2>/dev/null)
                    
                    if [ -n "$module" ]; then
                        local script=$(echo "$module" | jq -r '.script')
                        local name=$(echo "$module" | jq -r '.name')
                        local min_config=$(echo "$module" | jq -r '.min_config_version // "1.0.0"')
                        
                        # 检查版本兼容性
                        if ! version_ge "$CONFIG_VERSION" "$min_config"; then
                            log_error "此模块需要配置版本 >= v$min_config"
                            log_info "当前版本: v$CONFIG_VERSION"
                            log_info "请先更新工具包"
                            continue
                        fi
                        
                        execute_module "$script"
                    else
                        log_error "无效的操作编号"
                    fi
                else
                    log_error "无效的操作编号"
                fi
                ;;
        esac
        
        # 询问是否继续
        echo ""
        echo -n "按 Enter 返回主菜单，或输入 'q' 退出: "
        read continue_choice
        
        if [ "$continue_choice" = "q" ] || [ "$continue_choice" = "Q" ]; then
            echo ""
            log_success "感谢使用 Server Toolkit！"
            exit 0
        fi
    done
}

# 主函数
main() {
    # 检查依赖
    if ! check_dependencies; then
        exit 1
    fi
    
    # 显示系统信息
    show_system_info
    
    # 进入主循环
    main_loop
}

# 运行主函数
main "$@"
