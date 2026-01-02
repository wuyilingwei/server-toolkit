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

# Read symlink configuration
CREATE_ETC_SSL=$(echo "$CONFIG" | jq -r '.symlinks.etc_ssl // false' 2>/dev/null)
CREATE_NGINX_SSL=$(echo "$CONFIG" | jq -r '.symlinks.nginx_ssl // false' 2>/dev/null)

# Function to extract certificate value from JSON response
get_cert_value() {
    local response="$1"
    local key="$2"
    
    # Extract value directly - jq -r automatically handles \n escape sequences
    echo "$response" | jq -r --arg k "$key" \
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

# Create/maintain symbolic links
if [ "$CREATE_ETC_SSL" = "true" ]; then
    log "维护 /etc/ssl 符号链接..."
    # Remove old symlink if it exists
    if [ -L /etc/ssl ]; then
        rm -f /etc/ssl
    elif [ -e /etc/ssl ]; then
        log "警告: /etc/ssl 已存在且不是符号链接，跳过创建"
    fi
    
    # Create new symlink if it doesn't exist or was just removed
    if [ ! -e /etc/ssl ]; then
        ln -sf "$CERT_DIR" /etc/ssl
        log "已创建 /etc/ssl -> $CERT_DIR"
    fi
fi

if [ "$CREATE_NGINX_SSL" = "true" ]; then
    log "维护 /etc/nginx/ssl 符号链接..."
    # Ensure /etc/nginx directory exists
    if [ ! -d /etc/nginx ]; then
        log "警告: /etc/nginx 目录不存在，跳过创建符号链接"
    else
        # Remove old symlink if it exists
        if [ -L /etc/nginx/ssl ]; then
            rm -f /etc/nginx/ssl
        elif [ -e /etc/nginx/ssl ]; then
            log "警告: /etc/nginx/ssl 已存在且不是符号链接，跳过创建"
        fi
        
        # Create new symlink if it doesn't exist or was just removed
        if [ ! -e /etc/nginx/ssl ]; then
            ln -sf "$CERT_DIR" /etc/nginx/ssl
            log "已创建 /etc/nginx/ssl -> $CERT_DIR"
        fi
    fi
fi

log "同步任务完成"
