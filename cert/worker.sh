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
    local id="$2"
    
    # Extract value directly - jq -r automatically handles \n escape sequences
    echo "$response" | jq -r --arg id "$id" \
        '.[] | select(.id == $id) | .data.content // empty'
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
        CERT=$(get_cert_value "$RESPONSE" "cert")
        FULLCHAIN=$(get_cert_value "$RESPONSE" "fullchain")
        PRIVKEY=$(get_cert_value "$RESPONSE" "privkey")
        
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
        CF_CERT=$(get_cert_value "$RESPONSE" "cf-cert")
        CF_PRIVKEY=$(get_cert_value "$RESPONSE" "cf-privkey")
        
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

# Create/maintain symbolic links for files
create_symlink() {
    local target_file="$1"
    local link_path="$2"

    # Ensure the parent directory of the link exists
    local link_dir
    link_dir=$(dirname "$link_path")
    mkdir -p "$link_dir"

    # Check if the target file exists
    if [ ! -e "$target_file" ]; then
        log "错误: 目标文件不存在: $target_file"
        return
    fi

    # Handle existing link or file at the link path
    if [ -L "$link_path" ]; then
        rm -f "$link_path"
    elif [ -e "$link_path" ]; then
        log "警告: $link_path 已存在且不是符号链接，跳过创建"
        return
    fi

    # Create the symbolic link
    ln -sf "$target_file" "$link_path"
    log "已创建符号链接: $link_path -> $target_file"
}

# Example usage of create_symlink
if [ "$CREATE_ETC_SSL" = "true" ]; then
    log "维护 /etc/ssl 符号链接..."
    create_symlink "$CERT_DIR/cert.pem" "/etc/ssl/cert.pem"
fi

if [ "$CREATE_NGINX_SSL" = "true" ]; then
    log "维护 /etc/nginx/ssl 符号链接..."
    create_symlink "$CERT_DIR/nginx-cert.pem" "/etc/nginx/ssl/nginx-cert.pem"
fi

# Custom command after updates (configurable)
CUSTOM_COMMAND=""

custom_command() {
    if [ -n "$CUSTOM_COMMAND" ]; then
        log "执行自定义命令: $CUSTOM_COMMAND"
        eval "$CUSTOM_COMMAND"
    else
        log "未配置自定义命令，跳过执行"
    fi
}

# Example: Uncomment and set CUSTOM_COMMAND to reload nginx after updates
# CUSTOM_COMMAND="systemctl reload nginx"

# Call custom_command at the end of the script
custom_command

log "同步任务完成"
