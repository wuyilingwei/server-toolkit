#!/bin/bash
# Server Toolkit - Certificate Sync Worker
# This script is the template for the worker that will be deployed

source /etc/environment
VAULT_URL="${SYS_VAULT_URL}"
TOKEN="${SYS_DEVICE_UUID}"
LOG_FILE="/srv/server-toolkit/cert/sync.log"
CONFIG_FILE="/srv/server-toolkit/cert/sync-config.json"
CERT_DIR="/srv/server-toolkit/cert/local"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Ensure cert directory exists with correct permissions
# Note: 700 permissions are required for security (owner read/write/execute only)
mkdir -p "$CERT_DIR"
chmod 700 "$CERT_DIR"

# Read configuration
if [ ! -f "$CONFIG_FILE" ]; then
    log "错误: 配置文件不存在: $CONFIG_FILE"
    exit 1
fi

CONFIG=$(cat "$CONFIG_FILE")
PROD_DOMAINS=$(echo "$CONFIG" | jq -r '.production[]' 2>/dev/null)
CF_DOMAINS=$(echo "$CONFIG" | jq -r '.cf_origin[]' 2>/dev/null)

# Function to fix JSON newlines and get value
get_cert_value() {
    local response="$1"
    local key="$2"
    
    # Clean response by converting literal \n to actual newlines for proper JSON parsing
    local clean_resp=$(echo "$response" | sed 's/\\n/\n/g' | jq -c '.')
    
    # Extract value and restore literal \n in certificate content
    echo "$clean_resp" | jq -r --arg k "$key" \
        '.[0].data[] | select(.key == $k) | .value // empty'
}

# Sync production certificates
if [ -n "$PROD_DOMAINS" ]; then
    log "开始同步生产证书..."
    for domain in $PROD_DOMAINS; do
        log "同步域名: $domain (生产证书)"
        
        # Build request for all three keys
        PAYLOAD=$(jq -n \
            --arg d "$domain" \
            '{ops: [
                {id: "cert", type: "read", module: "certs", key: ($d + "-cert")},
                {id: "fullchain", type: "read", module: "certs", key: ($d + "-fullchain")},
                {id: "privkey", type: "read", module: "certs", key: ($d + "-privkey")}
            ]}')
        
        RESPONSE=$(curl -s -m 30 -X POST "$VAULT_URL" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $TOKEN" \
            -d "$PAYLOAD")
        
        if [ -z "$RESPONSE" ]; then
            log "错误: 空响应 - $domain"
            continue
        fi
        
        # Extract and save certificates with original naming
        CERT=$(get_cert_value "$RESPONSE" "${domain}-cert")
        FULLCHAIN=$(get_cert_value "$RESPONSE" "${domain}-fullchain")
        PRIVKEY=$(get_cert_value "$RESPONSE" "${domain}-privkey")
        
        if [ -n "$CERT" ]; then
            echo "$CERT" > "$CERT_DIR/${domain}-cert"
            chmod 600 "$CERT_DIR/${domain}-cert"
        fi
        
        if [ -n "$FULLCHAIN" ]; then
            echo "$FULLCHAIN" > "$CERT_DIR/${domain}-fullchain"
            chmod 600 "$CERT_DIR/${domain}-fullchain"
        fi
        
        if [ -n "$PRIVKEY" ]; then
            echo "$PRIVKEY" > "$CERT_DIR/${domain}-privkey"
            chmod 600 "$CERT_DIR/${domain}-privkey"
        fi
        
        log "完成: $domain (生产证书)"
    done
fi

# Sync CF origin certificates
if [ -n "$CF_DOMAINS" ]; then
    log "开始同步源站证书..."
    for domain in $CF_DOMAINS; do
        log "同步域名: $domain (源站证书)"
        
        # Build request for CF certs
        PAYLOAD=$(jq -n \
            --arg d "$domain" \
            '{ops: [
                {id: "cf-cert", type: "read", module: "certs", key: ($d + "-cf-cert")},
                {id: "cf-privkey", type: "read", module: "certs", key: ($d + "-cf-privkey")}
            ]}')
        
        RESPONSE=$(curl -s -m 30 -X POST "$VAULT_URL" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $TOKEN" \
            -d "$PAYLOAD")
        
        if [ -z "$RESPONSE" ]; then
            log "错误: 空响应 - $domain"
            continue
        fi
        
        # Extract and save CF certificates with original naming
        CF_CERT=$(get_cert_value "$RESPONSE" "${domain}-cf-cert")
        CF_PRIVKEY=$(get_cert_value "$RESPONSE" "${domain}-cf-privkey")
        
        if [ -n "$CF_CERT" ]; then
            echo "$CF_CERT" > "$CERT_DIR/${domain}-cf-cert"
            chmod 600 "$CERT_DIR/${domain}-cf-cert"
        fi
        
        if [ -n "$CF_PRIVKEY" ]; then
            echo "$CF_PRIVKEY" > "$CERT_DIR/${domain}-cf-privkey"
            chmod 600 "$CERT_DIR/${domain}-cf-privkey"
        fi
        
        log "完成: $domain (源站证书)"
    done
fi

log "证书同步完成"
