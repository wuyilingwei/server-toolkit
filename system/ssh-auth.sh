#!/bin/bash
set -e

# 检查root权限
if [ "$EUID" -ne 0 ]; then
    echo "错误: 需要root权限执行此脚本"
    echo "请使用: sudo bash $0"
    exit 1
fi

USER_NAME=$(whoami)
if [ "$USER_NAME" = "root" ]; then
    echo "警告: 正在为root用户配置SSH密钥"
    read -rp "是否继续? (y/n, 默认n): " continue_root
    continue_root="${continue_root:-n}"
    if [ "$continue_root" != "y" ] && [ "$continue_root" != "Y" ]; then
        echo "操作已取消"
        exit 0
    fi
    KEY_DIR="/root/.ssh"
else
    # 如果是root执行但要为其他用户配置，询问用户
    echo "当前以root身份运行，请选择要配置SSH密钥的用户:"
    echo "1) root用户"
    echo "2) 其他用户"
    read -rp "请选择 (1-2, 默认1): " user_choice
    user_choice="${user_choice:-1}"
    
    if [ "$user_choice" = "2" ]; then
        read -rp "请输入用户名: " target_user
        if ! id "$target_user" &>/dev/null; then
            echo "错误: 用户 $target_user 不存在"
            exit 1
        fi
        USER_NAME="$target_user"
        KEY_DIR="/home/$target_user/.ssh"
    else
        KEY_DIR="/root/.ssh"
    fi
fi

KEY_FILE="$KEY_DIR/id_ed25519"

echo ""
echo "=========================================="
echo "SSH 密钥管理工具"
echo "=========================================="
echo "目标用户: $USER_NAME"
echo "密钥目录: $KEY_DIR"
echo ""

# 检查现有密钥
check_existing_keys() {
    local has_ed25519=false
    local has_rsa=false
    local has_other=false
    
    if [ -f "$KEY_DIR/id_ed25519" ]; then
        has_ed25519=true
    fi
    if [ -f "$KEY_DIR/id_rsa" ]; then
        has_rsa=true
    fi
    if [ -f "$KEY_DIR/id_ecdsa" ] || [ -f "$KEY_DIR/id_dsa" ]; then
        has_other=true
    fi
    
    if [ "$has_ed25519" = true ] || [ "$has_rsa" = true ] || [ "$has_other" = true ]; then
        echo "发现现有SSH密钥:"
        echo ""
        
        if [ "$has_ed25519" = true ]; then
            echo "🔑 ED25519 密钥:"
            echo "   私钥: $KEY_DIR/id_ed25519"
            echo "   公钥: $KEY_DIR/id_ed25519.pub"
            if [ -f "$KEY_DIR/id_ed25519.pub" ]; then
                echo "   内容: $(cat "$KEY_DIR/id_ed25519.pub" 2>/dev/null || echo '读取失败')"
            fi
            echo ""
        fi
        
        if [ "$has_rsa" = true ]; then
            echo "🔑 RSA 密钥:"
            echo "   私钥: $KEY_DIR/id_rsa"
            echo "   公钥: $KEY_DIR/id_rsa.pub"
            if [ -f "$KEY_DIR/id_rsa.pub" ]; then
                echo "   内容: $(cat "$KEY_DIR/id_rsa.pub" 2>/dev/null || echo '读取失败')"
            fi
            echo ""
        fi
        
        if [ "$has_other" = true ]; then
            echo "🔑 其他类型密钥: "
            ls -la "$KEY_DIR"/id_* 2>/dev/null | grep -v ".pub$" || echo "   无"
            echo ""
        fi
        
        return 0  # 存在密钥
    else
        echo "未发现现有SSH密钥"
        echo ""
        return 1  # 不存在密钥
    fi
}

# 显示菜单
show_menu() {
    echo "请选择操作:"
    echo "1) 一步配置 (ED25519密钥 + SSH服务 + 显示密钥) [推荐]"
    echo "2) 生成新的ED25519密钥对"
    echo "3) 生成新的RSA密钥对"
    echo "4) 仅配置SSH服务 (禁用密码登录)"
    echo "0) 退出"
    echo ""
}

# 一步操作（生成ED25519密钥 + 配置SSH服务 + 显示密钥）
quick_setup() {
    echo ""
    echo "🚀 开始一步配置 SSH 安全认证..."
    echo ""
    
    # 检查是否已存在ED25519密钥
    if [ -f "$KEY_FILE" ]; then
        echo "⚠️  警告: ED25519密钥已存在，将会覆盖现有密钥"
        echo "当前密钥: $KEY_FILE"
        if [ -f "$KEY_FILE.pub" ]; then
            echo "公钥内容: $(cat "$KEY_FILE.pub" 2>/dev/null || echo '读取失败')"
        fi
        echo ""
        read -rp "是否继续覆盖? (y/n, 默认n): " confirm
        confirm="${confirm:-n}"
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            echo "操作已取消"
            return 1
        fi
    fi
    
    echo "1/3 🔐 生成ED25519密钥对..."
    if ! generate_keypair "ed25519"; then
        echo "❗ 密钥生成失败"
        return 1
    fi
    
    echo "2/3 🔧 配置SSH服务..."
    if ! configure_ssh_service; then
        echo "❗ SSH服务配置失败"
        return 1
    fi
    
    echo "3/3 📝 显示密钥信息..."
    echo ""
    echo "✅ 一步配置完成！"
    echo "──────────────────────────────────────────────────"
    echo "🔐 密码登录已禁用，仅允许密钥登录"
    echo "⚠️  请务必妖善保管私钥，否则将无法再登录此主机！"
    echo "🔄 复制私钥后，执行 'sudo systemctl restart sshd' 启用更改"
    echo "──────────────────────────────────────────────────"
    
    return 0
}

# 配置SSH服务
configure_ssh_service() {
    echo "🔧 配置SSH服务设置..."
    
    # 备份原配置
    if [ ! -f /etc/ssh/sshd_config.bak ]; then
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
        echo "✅ 已备份原SSH配置到 /etc/ssh/sshd_config.bak"
    fi
    
    # 修改SSH配置
    sed -i 's/^#\?\s*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
    sed -i 's/^#\?\s*AuthorizedKeysFile.*/AuthorizedKeysFile .ssh\/authorized_keys .ssh\/authorized_keys2/' /etc/ssh/sshd_config
    sed -i 's/^#\?\s*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#\?\s*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
    
    echo "✅ SSH配置已更新"
}

# 生成密钥对
generate_keypair() {
    local key_type="$1"
    local key_file=""
    
    # 确保.ssh目录存在
    if [ "$USER_NAME" = "root" ]; then
        mkdir -p "$KEY_DIR"
        chmod 700 "$KEY_DIR"
    else
        sudo -u "$USER_NAME" mkdir -p "$KEY_DIR"
        sudo -u "$USER_NAME" chmod 700 "$KEY_DIR"
    fi
    
    case "$key_type" in
        "ed25519")
            key_file="$KEY_DIR/id_ed25519"
            echo "🔐 生成ED25519密钥对..."
            if [ "$USER_NAME" = "root" ]; then
                ssh-keygen -t ed25519 -f "$key_file" -N "" -C "$USER_NAME@$(hostname)"
            else
                sudo -u "$USER_NAME" ssh-keygen -t ed25519 -f "$key_file" -N "" -C "$USER_NAME@$(hostname)"
            fi
            ;;
        "rsa")
            key_file="$KEY_DIR/id_rsa"
            echo "🔐 生成RSA密钥对..."
            if [ "$USER_NAME" = "root" ]; then
                ssh-keygen -t rsa -b 4096 -f "$key_file" -N "" -C "$USER_NAME@$(hostname)"
            else
                sudo -u "$USER_NAME" ssh-keygen -t rsa -b 4096 -f "$key_file" -N "" -C "$USER_NAME@$(hostname)"
            fi
            ;;
        *)
            echo "错误: 不支持的密钥类型"
            return 1
            ;;
    esac
    
    # 添加公钥到authorized_keys
    if [ -f "$key_file.pub" ]; then
        if [ "$USER_NAME" = "root" ]; then
            cat "$key_file.pub" >> "$KEY_DIR/authorized_keys"
            chmod 600 "$KEY_DIR/authorized_keys"
        else
            sudo -u "$USER_NAME" bash -c "cat '$key_file.pub' >> '$KEY_DIR/authorized_keys'"
            sudo -u "$USER_NAME" chmod 600 "$KEY_DIR/authorized_keys"
        fi
        echo "✅ 公钥已添加到 authorized_keys"
    fi
    
    return 0
}

# 显示密钥
show_keys() {
    local key_file="$1"
    local show_private="${2:-true}"  # 默认显示私钥
    
    if [ -n "$key_file" ] && [ -f "$key_file.pub" ]; then
        echo ""
        echo "✅ SSH公钥:"
        echo "──────────────────── BEGIN PUBLIC KEY ─────────────────────"
        cat "$key_file.pub"
        echo "───────────────────── END PUBLIC KEY ──────────────────────"
        echo ""
        
        if [ "$show_private" = "true" ] && [ -f "$key_file" ]; then
            echo "⚠️  SSH私钥 (请妖善保管):"
            echo "─────────────────── BEGIN PRIVATE KEY ─────────────────────"
            cat "$key_file"
            echo "──────────────────── END PRIVATE KEY ──────────────────────"
            echo ""
        fi
    elif [ -z "$key_file" ] || [ "$show_private" = "false" ]; then
        # 显示所有公钥
        echo ""
        echo "显示所有现有公钥:"
        if [ -d "$KEY_DIR" ]; then
            for pub_key in "$KEY_DIR"/*.pub; do
                if [ -f "$pub_key" ]; then
                    echo ""
                    echo "🔑 $(basename "$pub_key"):"
                    cat "$pub_key"
                fi
            done
            echo ""
        else
            echo "未找到密钥目录"
        fi
    else
        echo "未找到指定的密钥文件"
    fi
}

# 主逻辑
main() {
    # 检查现有密钥
    if check_existing_keys; then
        echo "发现现有密钥，建议谨慎操作。"
        echo ""
    fi
    
    while true; do
        show_menu
        read -rp "请选择操作 (0-4): " choice
        
        case "$choice" in
            1)
                if quick_setup; then
                    show_keys "$KEY_FILE" "true"
                    break
                fi
                ;;
            2)
                if [ -f "$KEY_FILE" ]; then
                    echo "警告: ED25519密钥已存在，将会覆盖现有密钥"
                    read -rp "是否继续? (y/n): " confirm
                    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
                        continue
                    fi
                fi
                generate_keypair "ed25519"
                show_keys "$KEY_FILE" "true"
                read -rp "按回车继续..." dummy
                ;;
            3)
                if [ -f "$KEY_DIR/id_rsa" ]; then
                    echo "警告: RSA密钥已存在，将会覆盖现有密钥"
                    read -rp "是否继续? (y/n): " confirm
                    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
                        continue
                    fi
                fi
                generate_keypair "rsa"
                show_keys "$KEY_DIR/id_rsa" "true"
                read -rp "按回车继续..." dummy
                ;;
            4)
                configure_ssh_service
                echo ""
                echo "✅ SSH服务配置完成"
                echo "🔄 执行 'sudo systemctl restart sshd' 启用更改"
                read -rp "按回车继续..." dummy
                ;;
            0)
                echo "退出SSH密钥管理工具"
                exit 0
                ;;
            *)
                echo "无效选择，请输入0-4之间的数字"
                ;;
        esac
    done
}

# 运行主函数
main "$@"