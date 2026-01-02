#!/bin/bash
# Certificate Sync Module - Completely Rewritten
# Syncs certificates from Vault to local /srv/server-toolkit/cert/local directory

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

# Default Configuration
DEFAULT_VAULT_URL="https://vault.wuyilingwei.com/api/data"
# Storage directory for persistent data
STORAGE_DIR="$WORKDIR/cert"
CERT_LOCAL_DIR="$STORAGE_DIR/local"
CONFIG_FILE="$STORAGE_DIR/sync-config.json"
mkdir -p "$STORAGE_DIR"
mkdir -p "$CERT_LOCAL_DIR"

SYNC_SCRIPT_PATH="$STORAGE_DIR/worker.sh"
LOG_FILE="$STORAGE_DIR/sync.log"

# Color codes
COLOR_RESET="\033[0m"
COLOR_GREEN="\033[1;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_RED="\033[1;31m"
COLOR_CYAN="\033[1;36m"
COLOR_BLUE="\033[1;34m"

log_info() { echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET} $1"; }
log_success() { echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $1"; }
log_error() { echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $1"; }
log_warning() { echo -e "${COLOR_YELLOW}[WARNING]${COLOR_RESET} $1"; }

# 1. Environment & UUID Check
# Load environment variables
if [ -f /etc/environment ]; then
    source /etc/environment
fi

# Check/Prompt for UUID
if [ -z "$SYS_DEVICE_UUID" ]; then
    echo ""
    echo -e "${COLOR_YELLOW}未检测到设备 UUID (SYS_DEVICE_UUID)${COLOR_RESET}"
    echo -n "请输入您的 Vault Token (UUID): "
    read -s user_token
    echo ""
    
    if [ -n "$user_token" ]; then
        # Persist to /etc/environment
        if ! grep -q "SYS_DEVICE_UUID" /etc/environment; then
            echo "SYS_DEVICE_UUID=\"$user_token\"" >> /etc/environment
        else
            sed -i "s/^SYS_DEVICE_UUID=.*/SYS_DEVICE_UUID=\"$user_token\"/" /etc/environment
        fi
        export SYS_DEVICE_UUID="$user_token"
        log_success "UUID 已保存"
    else
        log_error "未输入 Token，无法继续"
        exit 1
    fi
fi

# Check/Prompt for Vault URL
if [ -z "$SYS_VAULT_URL" ]; then
    SYS_VAULT_URL="$DEFAULT_VAULT_URL"
    if ! grep -q "SYS_VAULT_URL" /etc/environment; then
        echo "SYS_VAULT_URL=\"$SYS_VAULT_URL\"" >> /etc/environment
    fi
    export SYS_VAULT_URL
fi

# Ask about cert/local directory permissions
echo ""
echo -e "${COLOR_CYAN}=== 证书目录权限设置 ===${COLOR_RESET}"
echo "证书将存储在: $CERT_LOCAL_DIR"
echo -e "${COLOR_YELLOW}建议设置目录权限为 600 (仅所有者可读写) 以保护证书安全${COLOR_RESET}"
echo -n "是否设置 cert/local 目录权限为 600? (y/n，默认: y): "
read set_perm

if [ -z "$set_perm" ] || [ "$set_perm" = "y" ] || [ "$set_perm" = "Y" ]; then
    chmod 600 "$CERT_LOCAL_DIR"
    log_success "已设置 cert/local 目录权限为 600"
else
    log_warning "跳过权限设置，当前权限: $(stat -c '%a' "$CERT_LOCAL_DIR")"
fi

# 2. List Available Certificate Keys
log_info "正在获取可用的证书密钥列表..."

RESPONSE=$(curl -s -m 10 -X POST "$SYS_VAULT_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $SYS_DEVICE_UUID" \
    -d '{"ops": [{"id": "list_certs", "type": "list", "module": "certs"}]}')

# Check for errors safely - handle potential \n in response
if [ -z "$RESPONSE" ]; then
    log_error "获取列表失败: 空响应"
    exit 1
fi

# Fix JSON by replacing literal \n sequences with actual newlines, then minify for parsing
CLEAN_RESPONSE=$(echo "$RESPONSE" | sed 's/\\n/\n/g' | jq -c '.')

if ! echo "$CLEAN_RESPONSE" | jq -e '.[0].status == 200' >/dev/null 2>&1; then
    ERR_MSG=$(echo "$CLEAN_RESPONSE" | jq -r 'if type=="array" then .[0].error // .[0].message else .error // .message end // "Unknown error"' 2>/dev/null)
    log_error "获取列表失败: ${ERR_MSG:-Response format error}"
    exit 1
fi

# Parse keys from list response
ALL_KEYS=$(echo "$CLEAN_RESPONSE" | jq -r '.[0].data[] | .key' 2>/dev/null)

if [ -z "$ALL_KEYS" ]; then
    log_error "未找到任何证书密钥"
    exit 1
fi

echo ""
echo -e "${COLOR_CYAN}=== 可用证书密钥列表 ===${COLOR_RESET}"
echo "$ALL_KEYS"
echo ""

# Extract unique domain names from keys
# Keys format: domain-cert, domain-fullchain, domain-privkey, domain-cf-cert, domain-cf-privkey
DOMAINS=$(echo "$ALL_KEYS" | sed -E 's/-(cert|fullchain|privkey|cf-cert|cf-privkey)$//' | sort -u)

if [ -z "$DOMAINS" ]; then
    log_error "无法解析域名"
    exit 1
fi

echo -e "${COLOR_BLUE}=== 检测到的域名 ===${COLOR_RESET}"
i=1
declare -A domain_map
while IFS= read -r domain; do
    echo "[$i] $domain"
    domain_map[$i]="$domain"
    ((i++))
done <<< "$DOMAINS"
echo ""

# 3. Select Domains for Production Certificates
echo -e "${COLOR_GREEN}=== 选择要同步的生产证书 ===${COLOR_RESET}"
echo "生产证书包含: domain-cert, domain-fullchain, domain-privkey"
echo -n "请输入要同步的域名编号 (逗号分隔，例如 1,3 或输入 'all' 同步所有，留空跳过): "
read prod_selection

PROD_DOMAINS=""
if [ "$prod_selection" = "all" ]; then
    PROD_DOMAINS="$DOMAINS"
elif [ -n "$prod_selection" ]; then
    IFS=',' read -ra ADDR <<< "$prod_selection"
    for id in "${ADDR[@]}"; do
        id=$(echo "$id" | xargs)  # trim whitespace
        if [ -n "${domain_map[$id]}" ]; then
            PROD_DOMAINS="$PROD_DOMAINS
${domain_map[$id]}"
        fi
    done
fi

# 4. Select Domains for CF Origin Certificates
echo ""
echo -e "${COLOR_GREEN}=== 选择要同步的源站证书 (Cloudflare Origin) ===${COLOR_RESET}"
echo "源站证书包含: domain-cf-cert, domain-cf-privkey"
echo -n "请输入要同步的域名编号 (逗号分隔，例如 1,3 或输入 'all' 同步所有，留空跳过): "
read cf_selection

CF_DOMAINS=""
if [ "$cf_selection" = "all" ]; then
    CF_DOMAINS="$DOMAINS"
elif [ -n "$cf_selection" ]; then
    IFS=',' read -ra ADDR <<< "$cf_selection"
    for id in "${ADDR[@]}"; do
        id=$(echo "$id" | xargs)  # trim whitespace
        if [ -n "${domain_map[$id]}" ]; then
            CF_DOMAINS="$CF_DOMAINS
${domain_map[$id]}"
        fi
    done
fi

# Check if at least something was selected
if [ -z "$PROD_DOMAINS" ] && [ -z "$CF_DOMAINS" ]; then
    log_error "未选择任何域名或证书类型"
    exit 1
fi

# 5. Generate Configuration File
log_info "生成配置文件: $CONFIG_FILE"

# Build JSON configuration
CONFIG_JSON='{"production":[],"cf_origin":[]}'

if [ -n "$PROD_DOMAINS" ]; then
    while IFS= read -r domain; do
        [ -z "$domain" ] && continue
        CONFIG_JSON=$(echo "$CONFIG_JSON" | jq --arg d "$domain" '.production += [$d]')
    done <<< "$PROD_DOMAINS"
fi

if [ -n "$CF_DOMAINS" ]; then
    while IFS= read -r domain; do
        [ -z "$domain" ] && continue
        CONFIG_JSON=$(echo "$CONFIG_JSON" | jq --arg d "$domain" '.cf_origin += [$d]')
    done <<< "$CF_DOMAINS"
fi

echo "$CONFIG_JSON" | jq '.' > "$CONFIG_FILE"

log_success "配置已保存到: $CONFIG_FILE"
echo ""
echo "配置内容:"
cat "$CONFIG_FILE"
echo ""

# 6. Generate Worker Script
log_info "生成同步脚本: $SYNC_SCRIPT_PATH"

cat <<'WORKER_EOF' > "$SYNC_SCRIPT_PATH"
#!/bin/bash
# Server Toolkit - Certificate Sync Worker
# Auto-generated - Do not edit manually

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
mkdir -p "$CERT_DIR"
chmod 600 "$CERT_DIR"

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
WORKER_EOF

chmod +x "$SYNC_SCRIPT_PATH"

# 7. Setup Cron Job with #cert tag
log_info "配置定时任务 (每小时执行一次)..."
TAG="#cert"
CRON_CMD="0 * * * * $SYNC_SCRIPT_PATH >> $LOG_FILE 2>&1 $TAG"

# Remove all old cert jobs (with #cert tag)
crontab -l 2>/dev/null | grep -v "$TAG" > /tmp/cron.tmp || true

# Add new job
echo "$CRON_CMD" >> /tmp/cron.tmp
crontab /tmp/cron.tmp
rm /tmp/cron.tmp

log_success "定时任务已配置"

# 8. Run Initial Sync
log_info "正在执行首次同步..."
echo ""
"$SYNC_SCRIPT_PATH"

echo ""
log_success "证书同步配置完成！"
echo ""
echo -e "${COLOR_CYAN}=== 配置信息 ===${COLOR_RESET}"
echo -e "证书存储目录: ${COLOR_GREEN}$CERT_LOCAL_DIR${COLOR_RESET}"
echo -e "配置文件: ${COLOR_GREEN}$CONFIG_FILE${COLOR_RESET}"
echo -e "同步脚本: ${COLOR_GREEN}$SYNC_SCRIPT_PATH${COLOR_RESET}"
echo -e "日志文件: ${COLOR_GREEN}$LOG_FILE${COLOR_RESET}"
echo -e "定时任务: ${COLOR_GREEN}每小时执行一次${COLOR_RESET}"
echo ""
