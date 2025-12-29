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

# 执行自更新 (仅更新核心文件)
do_self_update() {
    echo ""
    echo -e "${COLOR_CYAN}==================== 工具包自更新 ====================${COLOR_RESET}"
    
    local install_dir=$(get_install_dir)
    
    log_info "正在检查核心组件更新..."
    
    # 获取远程配置
    local remote_config=$(curl -s -m 10 "$RAW_REPO_URL/config.json")
    if [ -z "$remote_config" ]; then
        log_error "无法获取远程配置"
        return 1
    fi
    
    local remote_version=$(echo "$remote_config" | jq -r '.version // "0.0.0"')
    local local_config=$(read_repo_config)
    local local_version=$(echo "$local_config" | jq -r '.version // "0.0.0"')
    
    log_info "当前版本: v$local_version"
    log_info "最新版本: v$remote_version"
    
    # 检查是否需要更新
    if version_ge "$local_version" "$remote_version"; then
        log_success "核心组件已是最新版本"
        return 0
    fi
    
    echo -n "发现新版本 v$remote_version，是否更新核心组件? (y/n): "
    read confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        log_info "已取消更新"
        return 0
    fi
    
    log_info "正在更新核心文件..."
    local update_failed=false
    
    # 更新核心文件列表
    for file in "config.json" "config.sh" "menu.sh"; do
        log_info "下载 $file..."
        if ! download_from_repo "$file" "$install_dir/$file"; then
            log_error "下载 $file 失败"
            update_failed=true
        fi
    done
    
    if [ "$update_failed" = "true" ]; then
        log_error "部分文件更新失败"
        return 1
    else
        chmod +x "$install_dir/menu.sh"
        log_success "核心组件更新成功！"
        log_info "重新加载配置..."
        source "$install_dir/config.sh"
        return 0
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
    
    log_info "模块现在通过远程执行，无需手动更新"
    log_info "已安装的持久化模块会在重新执行时自动更新"
    
    # 显示已安装的持久化模块
    local installed=$(read_installed_config)
    local installed_modules=$(echo "$installed" | jq -r '.modules[]? | "\(.id | @sh) v\(.version | @sh)"' 2>/dev/null)
    
    if [ -n "$installed_modules" ]; then
        echo ""
        echo -e "${COLOR_GREEN}已安装的持久化模块:${COLOR_RESET}"
        while IFS= read -r line; do
            echo "  - $line"
        done <<< "$installed_modules"
        echo ""
        log_info "重新执行对应菜单选项即可更新这些模块"
    else
        echo ""
        log_info "当前没有已安装的持久化模块"
    fi
    
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
    
    echo -e "${COLOR_GREEN}已安装的持久化模块:${COLOR_RESET}"
    local installed=$(read_installed_config)
    local installed_modules=$(echo "$installed" | jq -r '.modules[]?' 2>/dev/null)
    
    if [ -n "$installed_modules" ]; then
        echo "$installed_modules" | while IFS= read -r module; do
            local id=$(echo "$module" | jq -r '.id')
            local version=$(echo "$module" | jq -r '.version')
            local installed_at=$(echo "$module" | jq -r '.installed_at // "未知时间"')
            echo "  - $id (v$version) - 安装于 $installed_at"
        done
    else
        echo "  (无已安装的持久化模块)"
    fi
    echo ""
}

# 执行模块脚本
execute_module() {
    local script_path="$1"
    local module_id="$2"
    local module_version="$3"
    local needs_persistence="$4"
    local install_dir=$(get_install_dir)
    
    # 构建远程 URL
    local script_url="$RAW_REPO_URL/$script_path"
    
    echo ""
    log_info "正在从远程执行: $script_path"
    echo -e "${COLOR_CYAN}--------------------------------------------------${COLOR_RESET}"
    
    # 直接从远程执行脚本，添加超时保护
    curl -s -L -m 300 "$script_url" | bash
    local exit_code=$?
    
    echo -e "${COLOR_CYAN}--------------------------------------------------${COLOR_RESET}"
    
    if [ $exit_code -eq 0 ]; then
        log_success "脚本执行完成"
        
        # 如果模块需要持久化，记录安装
        if [ "$needs_persistence" = "true" ]; then
            register_module_install "$module_id" "$module_version"
            log_success "模块已记录为已安装: $module_id v$module_version"
        fi
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
            local module_id=$(echo "$module" | jq -r '.id')
            local module_version=$(echo "$module" | jq -r '.version // "1.0.0"')
            local needs_persistence=$(echo "$module" | jq -r '.needs_persistence // false')
            
            if [ "$enabled" = "true" ]; then
                local status_text=""
                
                # 检查是否需要持久化
                if [ "$needs_persistence" = "true" ]; then
                    local installed_version=$(get_installed_version "$module_id")
                    
                    if [ "$installed_version" != "未安装" ]; then
                        status_text=" ${COLOR_GREEN}[已安装 v$installed_version]${COLOR_RESET}"
                        
                        # 检查是否有更新
                        if [ "$installed_version" != "$module_version" ]; then
                            status_text="$status_text ${COLOR_YELLOW}[可更新到 v$module_version]${COLOR_RESET}"
                        fi
                    else
                        status_text=" ${COLOR_YELLOW}[未安装]${COLOR_RESET}"
                    fi
                fi
                
                echo -e "${COLOR_YELLOW}[$id]${COLOR_RESET} $name$status_text"
            fi
        done
    fi
    
    echo ""
    echo -e "${COLOR_YELLOW}[0]${COLOR_RESET} 退出"
    echo -e "${COLOR_CYAN}==================================================${COLOR_RESET}"
}

# 主循环
main_loop() {
    local HAS_UPDATE=false
    
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
                        local module_id=$(echo "$module" | jq -r '.id')
                        local module_version=$(echo "$module" | jq -r '.version // "1.0.0"')
                        local needs_persistence=$(echo "$module" | jq -r '.needs_persistence // false')
                        
                        # 检查版本兼容性
                        if ! version_ge "$CONFIG_VERSION" "$min_config"; then
                            log_error "此模块需要配置版本 >= v$min_config"
                            log_info "当前版本: v$CONFIG_VERSION"
                            log_info "请先更新工具包"
                            continue
                        fi
                        
                        execute_module "$script" "$module_id" "$module_version" "$needs_persistence"
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
