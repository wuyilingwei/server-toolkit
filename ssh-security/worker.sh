#!/bin/bash
# SSH Security Worker Script - Persistent Security Synchronization
# This script handles ongoing IP whitelist synchronization

source /etc/environment

# Check configuration
if [ -z "$SYS_VAULT_URL" ]; then
    echo "[$(date)] 错误: SYS_VAULT_URL 未配置。请运行 deploy.sh 进行初始化配置。"
    exit 1
fi

if [ -z "$SYS_DEVICE_UUID" ]; then
    echo "[$(date)] 错误: SYS_DEVICE_UUID 未配置。请运行 deploy.sh 进行初始化配置。"
    exit 1
fi

VAULT_URL="${SYS_VAULT_URL}"
TOKEN="${SYS_DEVICE_UUID}"
IPSET_NAME="vault_global_whitelist"

# [Security Mechanism] Pre-cleanup any lingering DROP rules to ensure sync period doesn't lock us out
cleanup_drop() {
    iptables -S INPUT | grep "dport 22" | grep "DROP" | grep "#ssh-security" | sed "s/-A/iptables -D/" | bash 2>/dev/null
}

# 1. Get response
RESPONSE=$(curl -s -m 10 -X POST "$VAULT_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d "{\"ops\": [{\"id\": \"get_wl\", \"type\": \"read\", \"module\": \"ip\", \"key\": \"whitelist\"}]}")

# 2. Parse IP list (compatible with spaces and commas)
IPS=$(echo "$RESPONSE" | jq -r ".[0].data.content" 2>/dev/null | tr " ," "\n" | tr -d "\r\"" | grep -E "^[0-9./]+")

# 3. [Circuit Breaker Logic] If IPS length is 0 or parsing failed
if [ -z "$IPS" ]; then
    echo "[$(date)] 警告: 同步失败或白名单为空。为防止锁死，已撤回 DROP 拦截。"
    cleanup_drop
    exit 1
fi

# 4. Update IPSET (force ensure type is hash:net)
EXISTING_TYPE=$(ipset list "$IPSET_NAME" -terse 2>/dev/null | grep Type | cut -d: -f2 | tr -d " ")
if [ -n "$EXISTING_TYPE" ] && [ "$EXISTING_TYPE" != "hash:net" ]; then
    # If type doesn't match, first delete iptables rules referencing it before destroying
    iptables -D INPUT -m set --match-set "$IPSET_NAME" src -j ACCEPT -m comment --comment "#ssh-security" 2>/dev/null
    ipset destroy "$IPSET_NAME" 2>/dev/null
fi

ipset create "$IPSET_NAME" hash:net -exist
ipset create "${IPSET_NAME}_tmp" hash:net -exist
ipset flush "${IPSET_NAME}_tmp"
for ip in $IPS; do
    ipset add "${IPSET_NAME}_tmp" "$ip" -exist
done
ipset swap "${IPSET_NAME}_tmp" "$IPSET_NAME"
ipset destroy "${IPSET_NAME}_tmp"

# 5. Rebuild Iptables chain
# Clean old rules
iptables -S INPUT | grep "#ssh-security" | sed "s/-A/iptables -D/" | bash 2>/dev/null

# Level 1: Top priority whitelist ACCEPT
iptables -I INPUT 1 -m set --match-set "$IPSET_NAME" src -j ACCEPT -m comment --comment "#ssh-security"

# Level 2: Only enable DROP when we have confirmed whitelist IPs
iptables -I INPUT 2 -p tcp --dport 22 -j DROP -m comment --comment "#ssh-security"

echo "[$(date)] 同步成功。有效 IP 数量: $(echo "$IPS" | wc -l)"