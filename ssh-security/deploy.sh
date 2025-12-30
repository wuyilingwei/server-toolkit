#!/bin/bash
# SSH Security Deployment Script

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

# Storage directory for persistent data
STORAGE_DIR="$WORKDIR/storage/ssh-security"
mkdir -p "$STORAGE_DIR"

# 默认 Vault URL
DEFAULT_VAULT_URL="https://vault.wuyilingwei.com/api/data"

# 1. 交互式检查环境变量
if ! grep -q "SYS_DEVICE_UUID" /etc/environment; then
    echo "未发现 SYS_DEVICE_UUID，请输入您的 Vault Token (UUID):"
    read -s user_token
    echo ""
    if [ -n "$user_token" ]; then
        echo "SYS_DEVICE_UUID=\"$user_token\"" >> /etc/environment
        export SYS_DEVICE_UUID="$user_token"
        echo "Token 已写入 /etc/environment"
    else
        echo "错误: 未输入 Token，部署终止。"
        exit 1
    fi
fi

# 检查 Vault URL 配置
if ! grep -q "SYS_VAULT_URL" /etc/environment; then
    echo ""
    echo "未发现 SYS_VAULT_URL 配置"
    echo "默认使用: $DEFAULT_VAULT_URL"
    read -p "是否使用默认 Vault URL? (y/n): " use_default
    
    if [ "$use_default" = "n" ] || [ "$use_default" = "N" ]; then
        echo "请输入自定义 Vault URL:"
        read custom_vault_url
        if [ -n "$custom_vault_url" ]; then
            echo "SYS_VAULT_URL=\"$custom_vault_url\"" >> /etc/environment
            export SYS_VAULT_URL="$custom_vault_url"
            echo "Vault URL 已写入 /etc/environment"
        else
            echo "使用默认 Vault URL: $DEFAULT_VAULT_URL"
            echo "SYS_VAULT_URL=\"$DEFAULT_VAULT_URL\"" >> /etc/environment
            export SYS_VAULT_URL="$DEFAULT_VAULT_URL"
        fi
    else
        echo "SYS_VAULT_URL=\"$DEFAULT_VAULT_URL\"" >> /etc/environment
        export SYS_VAULT_URL="$DEFAULT_VAULT_URL"
        echo "已使用默认 Vault URL"
    fi
fi

# 2. 安装依赖
if ! apt update; then
    echo "错误: 软件包列表更新失败"
    exit 1
fi
apt install -y jq curl ipset iptables

# 3. 创建同步脚本到 storage 目录
SYNC_SCRIPT="$STORAGE_DIR/sync.sh"
LOG_FILE="$STORAGE_DIR/sync.log"

cat << "EOF" > "$SYNC_SCRIPT"
#!/bin/sh
#ssh-security: 带熔断保护的同步脚本

. /etc/environment
DEFAULT_VAULT_URL="https://vault.wuyilingwei.com/api/data"
VAULT_URL="${SYS_VAULT_URL:-$DEFAULT_VAULT_URL}"
TOKEN=${SYS_DEVICE_UUID}
IPSET_NAME="vault_global_whitelist"

# [安全机制] 预先清理可能残留的 DROP 规则，确保同步期间不会锁死
cleanup_drop() {
    iptables -S INPUT | grep "dport 22" | grep "DROP" | grep "#ssh-security" | sed "s/-A/iptables -D/" | bash 2>/dev/null
}

# 1. 获取响应
RESPONSE=\$(curl -s -m 10 -X POST "\$VAULT_URL" \\
    -H "Content-Type: application/json" \\
    -H "Authorization: Bearer \$TOKEN" \\
    -d "{\"ops\": [{\"id\": \"get_wl\", \"type\": \"read\", \"module\": \"ip\", \"key\": \"whitelist\"}]}")

# 2. 解析 IP 列表 (兼容空格与逗号)
IPS=\$(echo "\$RESPONSE" | jq -r ".[0].data.content" 2>/dev/null | tr " ," "\\n" | tr -d "\\r\\"" | grep -E "^[0-9./]+")

# 3. [熔断逻辑] 如果 IPS 长度为 0 或解析失败
if [ -z "\$IPS" ]; then
    echo "[$(date)] 警告: 同步失败或白名单为空。为防止锁死，已撤回 DROP 拦截。"
    cleanup_drop
    exit 1
fi

# 4. 更新 IPSET (强制确保类型为 hash:net)
EXISTING_TYPE=\$(ipset list "\$IPSET_NAME" -terse 2>/dev/null | grep Type | cut -d: -f2 | tr -d " ")
if [ -n "\$EXISTING_TYPE" ] && [ "\$EXISTING_TYPE" != "hash:net" ]; then
    # 若类型不匹配，先删除引用它的 iptables 规则才能销毁
    iptables -D INPUT -m set --match-set "\$IPSET_NAME" src -j ACCEPT -m comment --comment "#ssh-security" 2>/dev/null
    ipset destroy "\$IPSET_NAME" 2>/dev/null
fi

ipset create "\$IPSET_NAME" hash:net -exist
ipset create "\${IPSET_NAME}_tmp" hash:net -exist
ipset flush "\${IPSET_NAME}_tmp"
for ip in \$IPS; do
    ipset add "\${IPSET_NAME}_tmp" "\$ip" -exist
done
ipset swap "\${IPSET_NAME}_tmp" "\$IPSET_NAME"
ipset destroy "\${IPSET_NAME}_tmp"

# 5. 重构 Iptables 链
# 清理旧规则
iptables -S INPUT | grep "#ssh-security" | sed "s/-A/iptables -D/" | bash 2>/dev/null

# Level 1: 置顶白名单 ACCEPT
iptables -I INPUT 1 -m set --match-set "\$IPSET_NAME" src -j ACCEPT -m comment --comment "#ssh-security"

# Level 2: 只有在确定有白名单 IP 的情况下才开启 DROP
iptables -I INPUT 2 -p tcp --dport 22 -j DROP -m comment --comment "#ssh-security"

echo "[$(date)] 同步成功。有效 IP 数量: \$(echo "\$IPS" | wc -l)"
EOF

chmod +x "$SYNC_SCRIPT"

# 4. 管理 Crontab
crontab -l 2>/dev/null | grep -v "#rsync-fail2ban" | grep -v "#ssh-security" > /tmp/cron_tmp
echo "*/10 * * * * . /etc/environment; /bin/sh $SYNC_SCRIPT >> $LOG_FILE 2>&1 #ssh-security" >> /tmp/cron_tmp
crontab /tmp/cron_tmp
rm /tmp/cron_tmp

# 5. 立即执行首次同步
/bin/sh "$SYNC_SCRIPT"

echo "----------------------------------------------------------"
echo "部署完成！层级防护已就绪。"
echo "层级1：白名单 IP 放行 (IPSET: vault_global_whitelist)"
echo "层级2：非白名单 SSH 丢弃 (DROP)"
echo "熔断：若 API 异常，层级2 自动失效，确保管理入口可用。"
echo "同步脚本: $SYNC_SCRIPT"
echo "日志文件: $LOG_FILE"
echo "----------------------------------------------------------"

# 6. 交互式卸载 Fail2ban
read -p "是否需要直接卸载 Fail2ban 以清理旧策略? (y/n): " confirm
if [ "$confirm" = "y" ]; then
    apt purge fail2ban -y && apt autoremove -y
    echo "Fail2ban 已卸载。"
else
    echo "已跳过卸载。"
fi
