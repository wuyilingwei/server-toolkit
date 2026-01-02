#!/bin/bash
# Server Toolkit Interactive Menu
# This is the main interface that runs from /srv/server-toolkit

# ===== 工作目录保护（强制要求） =====
WORKDIR="/srv/server-toolkit"
# 确保工作目录存在
mkdir -p "$WORKDIR"
# 强制设置工作目录，如果失败则修改权限
if ! cd "$WORKDIR" 2>/dev/null; then
    # 如果无法进入，尝试修复权限
    chmod 755 "$WORKDIR" 2>/dev/null || mkdir -p "$WORKDIR"
    cd "$WORKDIR" || { echo "错误: 无法访问工作目录 $WORKDIR"; exit 1; }
fi
# ====================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source helper
if [ ! -f "$SCRIPT_DIR/helper.sh" ]; then
    echo "错误: 找不到 helper.sh"
    echo "请重新运行部署脚本"
    exit 1
fi

if ! source "$SCRIPT_DIR/helper.sh"; then
    echo "错误: 加载 helper.sh 失败"
    exit 1
fi

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

# 执行自更新 (更新 scripts 仓库和核心文件)
do_self_update() {
    echo ""
    echo -e "${COLOR_CYAN}==================== 工具包自更新 ====================${COLOR_RESET}"
    
    local install_dir=$(get_install_dir)
    local scripts_dir="$install_dir/scripts"
    
    # 检查 scripts 目录是否存在
    if [ ! -d "$scripts_dir/.git" ]; then
        log_error "未找到 Git 仓库目录: $scripts_dir"
        log_info "请重新运行部署脚本："
        log_info "  curl -sSL https://raw.githubusercontent.com/wuyilingwei/server-toolkit/main/deploy.sh | sudo bash"
        return 1
    fi
    
    log_info "正在检查更新..."
    
    # 进入 scripts 目录
    cd "$scripts_dir" || {
        log_error "无法进入 scripts 目录"
        return 1
    }
    
    # 获取当前版本
    local local_version=$(cat "$install_dir/config.json" | jq -r '.version // "0.0.0"')
    
    # 使用强制同步方式拉取最新代码
    log_info "执行强制 Git 同步..."
    
    # 获取远程更新
    if ! git fetch origin main; then
        log_error "Git fetch 失败"
        cd "$install_dir"
        return 1
    fi
    
    # 强制重置到远程分支（丢弃本地修改）
    log_info "重置到远程最新版本..."
    if ! git reset --hard origin/main; then
        log_error "Git reset 失败"
        cd "$install_dir"
        return 1
    fi
    
    # 获取新版本
    local remote_version=$(cat "$scripts_dir/config.json" | jq -r '.version // "0.0.0"')
    
    log_info "当前版本: v$local_version"
    log_info "最新版本: v$remote_version"
    
    # 始终复制核心文件（即使版本号相同，文件内容可能已更新）
    log_info "提取核心文件..."
    cp "$scripts_dir/menu.sh" "$install_dir/"
    cp "$scripts_dir/config.json" "$install_dir/"
    cp "$scripts_dir/helper.sh" "$install_dir/"
    
    chmod +x "$install_dir/menu.sh"
    chmod +x "$install_dir/helper.sh"
    
    cd "$install_dir"
    
    # 重新加载 helper 以使用最新函数定义
    log_info "重新加载配置..."
    source "$install_dir/helper.sh"
    
    # 重新读取更新后的配置
    local updated_config=$(read_repo_config)
    local updated_version=$(echo "$updated_config" | jq -r '.version // "0.0.0"')
    
    # 检查版本是否有变化
    if version_ge "$local_version" "$updated_version" && [ "$local_version" = "$updated_version" ]; then
        log_success "已是最新版本"
    else
        log_success "更新完成！新版本: v$updated_version"
    fi
    
    return 0
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
        # 重新加载环境变量
        . /etc/environment 2>/dev/null || true
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
    read new_uuid
    echo ""
    
    if [ -n "$new_uuid" ]; then
        set_config_value "SYS_DEVICE_UUID" "$new_uuid"
        # 重新加载环境变量
        . /etc/environment 2>/dev/null || true
        log_success "设备 UUID 已更新"
    else
        log_warning "未输入新 UUID，保持原设置"
    fi
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
    
    # 验证JSON格式
    if ! echo "$installed" | jq empty 2>/dev/null; then
        echo "  (配置文件损坏，已重置)"
        echo ""
        return
    fi
    
    # 直接使用jq来格式化输出，避免复杂的while循环
    local module_count=$(echo "$installed" | jq -r '.modules | length' 2>/dev/null)
    
    if [ "$module_count" -gt 0 ] 2>/dev/null; then
        echo "$installed" | jq -r '.modules[] | "  - " + .id + " (v" + .version + ") - 安装于 " + (.installed_at // "未知时间")' 2>/dev/null || {
            echo "  (模块信息解析失败)"
        }
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
    local scripts_dir="$install_dir/scripts"
    
    # 构建本地脚本路径
    local local_script="$scripts_dir/$script_path"
    
    # 检查脚本是否存在
    if [ ! -f "$local_script" ]; then
        log_error "模块脚本不存在: $local_script"
        log_info "请尝试更新工具包（菜单选项 3）"
        return 1
    fi
    
    echo ""
    log_info "正在执行模块: $script_path"
    echo -e "${COLOR_CYAN}--------------------------------------------------${COLOR_RESET}"
    
    # 执行本地脚本
    if bash "$local_script"; then
        local exit_code=0
    else
        local exit_code=$?
    fi
    
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
    local current_version=$(echo "$config" | jq -r '.version // "1.0.0"')
    local current_hash=$(get_current_hash)
    
    echo -e "${COLOR_CYAN}==================== 操作菜单 ====================${COLOR_RESET}"
    echo -e "${COLOR_BLUE}当前版本: v$current_version ($current_hash)${COLOR_RESET}"
    echo ""
    
    # 保留操作 (1-9)
    echo -e "${COLOR_YELLOW}[1]${COLOR_RESET} 配置 Vault URL"
    echo -e "${COLOR_YELLOW}[2]${COLOR_RESET} 配置设备 UUID"
    echo -e "${COLOR_YELLOW}[3]${COLOR_RESET} 工具包自更新"
    echo -e "${COLOR_YELLOW}[4]${COLOR_RESET} 显示当前配置"
    
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
    local AUTO_UPDATE_DONE=false
    
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
    
    # 自动检查更新（首次启动时）
    if [ "$AUTO_UPDATE_DONE" = "false" ]; then
        log_info "检查工具包更新..."
        if check_remote_update; then
            log_info "发现新版本！正在自动更新..."
            if do_self_update; then
                log_success "更新完成，正在重启菜单..."
                exec "$0" "$@"  # 重新执行脚本
            else
                log_error "自动更新失败，将继续使用当前版本"
                HAS_UPDATE=true
            fi
        else
            log_info "当前已是最新版本"
        fi
        AUTO_UPDATE_DONE=true
    fi
    
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
                if do_self_update; then
                    log_success "更新完成，正在重启菜单..."
                    exec "$0" "$@"  # 重新执行脚本以载入新配置
                else
                    log_error "更新失败"
                fi
                ;;
            4)
                show_current_config
                ;;
            5|6|7|8|9)
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
