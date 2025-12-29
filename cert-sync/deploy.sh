#!/bin/bash
# Certificate Sync Module
# Syncs certificates from Vault to local /certs directory

# Default Configuration
DEFAULT_VAULT_URL="https://vault.wuyilingwei.com/api/data"
# Use installation directory
INSTALL_DIR="${SYS_TOOLKIT_DIR:-/srv/server-toolkit}"
SYNC_SCRIPT_PATH="$INSTALL_DIR/cert-sync/worker.sh"
LOG_FILE="$INSTALL_DIR/logs/cert-sync.log"

# Ensure directories exist
mkdir -p "$(dirname "$SYNC_SCRIPT_PATH")"
mkdir -p "$(dirname "$LOG_FILE")"

# Color codes
COLOR_RESET="\033[0m"
COLOR_GREEN="\033[1;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_RED="\033[1;31m"
COLOR_CYAN="\033[1;36m"

log_info() { echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET} $1"; }
log_success() { echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $1"; }
log_error() { echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $1"; }

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

# 2. List Available Certificates
log_info "正在获取授权的证书列表..."

RESPONSE=$(curl -s -m 10 -X POST "$SYS_VAULT_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $SYS_DEVICE_UUID" \
    -d '{"ops": [{"id": "list_certs", "type": "list", "module": "cert"}]}')

# Check for errors safely
if ! echo "$RESPONSE" | jq -e '.[0].status == 200' >/dev/null 2>&1; then
    ERR_MSG=$(echo "$RESPONSE" | jq -r 'if type=="array" then .[0].error // .[0].message else .error // .message end // "Unknown error"' 2>/dev/null)
    log_error "获取列表失败: ${ERR_MSG:-Response format error}"
    log_error "Response: $RESPONSE"
    exit 1
fi

# Parse domains
DOMAINS=$(echo "$RESPONSE" | jq -r '.[0].data.list[]? // empty')

if [ -z "$DOMAINS" ]; then
    log_error "未找到可用的证书授权"
    exit 1
fi

echo ""
echo -e "${COLOR_CYAN}=== 可用证书列表 ===${COLOR_RESET}"
i=1
declare -A domain_map
for domain in $DOMAINS; do
    echo "[$i] $domain"
    domain_map[$i]="$domain"
    ((i++))
done
echo ""

# 3. Select Certificates
echo -n "请输入要同步的编号 (逗号分隔，例如 1,3 或输入 'all' 同步所有): "
read selection

SELECTED_DOMAINS=""
if [ "$selection" = "all" ]; then
    SELECTED_DOMAINS="$DOMAINS"
else
    IFS=',' read -ra ADDR <<< "$selection"
    for id in "${ADDR[@]}"; do
        if [ -n "${domain_map[$id]}" ]; then
            SELECTED_DOMAINS="$SELECTED_DOMAINS ${domain_map[$id]}"
        fi
    done
fi

if [ -z "$SELECTED_DOMAINS" ]; then
    log_error "未选择任何域名"
    exit 1
fi

# 4. Generate Sync Script
log_info "生成同步脚本: $SYNC_SCRIPT_PATH"

cat <<EOF > "$SYNC_SCRIPT_PATH"
#!/bin/bash
# Server Toolkit - Certificate Sync
# Generated on $(date)

source /etc/environment
VAULT_URL="\${SYS_VAULT_URL:-$DEFAULT_VAULT_URL}"
TOKEN="\${SYS_DEVICE_UUID}"
LOG_FILE="$LOG_FILE"

log() {
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1"
}

sync_domain() {
    local domain="\$1"
    local cert_dir="/certs/\$domain"
    
    log "Syncing \$domain..."
    
    # Fetch cert data
    local payload="{\"ops\": [{\"id\": \"get_cert\", \"type\": \"read\", \"module\": \"cert\", \"key\": \"\$domain\"}]}"
    local response=\$(curl -s -m 30 -X POST "\$VAULT_URL" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer \$TOKEN" \
        -d "\$payload")
        
    # Check response
    if [ -z "\$response" ]; then
        log "Error: Empty response for \$domain"
        return 1
    fi
    
    # Check status
    if ! echo "\$response" | jq -e '.[0].status == 200' >/dev/null 2>&1; then
        log "Error: API returned error for \$domain"
        return 1
    fi
    
    mkdir -p "\$cert_dir"
    
    # Helper to format cert (handle literal \n and ensure proper line breaks)
    # Uses awk to replace literal '\n' sequences with actual newlines
    format_cert() {
        awk '{gsub(/\\\\n/,"\n"); print}'
    }
    
    # Extract Standard Certs (Parse from data array)
    echo "\$response" | jq -r '.[0].data[] | select(.key | endswith("-cert")) | .value // empty' | format_cert > "\$cert_dir/cert.pem"
    echo "\$response" | jq -r '.[0].data[] | select(.key | endswith("-fullchain")) | .value // empty' | format_cert > "\$cert_dir/fullchain.pem"
    echo "\$response" | jq -r '.[0].data[] | select(.key | endswith("-privkey")) | .value // empty' | format_cert > "\$cert_dir/privkey.pem"
    
    # Extract CF Origin Certs
    echo "\$response" | jq -r '.[0].data[] | select(.key | endswith("-cf-public")) | .value // empty' | format_cert > "\$cert_dir/cf-public.pem"
    echo "\$response" | jq -r '.[0].data[] | select(.key | endswith("-cf-private")) | .value // empty' | format_cert > "\$cert_dir/cf-private.pem"
    
    # Cleanup empty files
    find "\$cert_dir" -type f -empty -delete
    
    # Set permissions
    chmod 600 "\$cert_dir"/*.pem 2>/dev/null
    
    log "Sync completed for \$domain"
}

# Selected Domains
DOMAINS_TO_SYNC="$SELECTED_DOMAINS"

for domain in \$DOMAINS_TO_SYNC; do
    sync_domain "\$domain"
done
EOF

chmod +x "$SYNC_SCRIPT_PATH"

# 5. Setup Cron Job
log_info "配置定时任务 (每小时执行)..."
TAG="#st-cert-sync"
CRON_CMD="0 * * * * $SYNC_SCRIPT_PATH >> $LOG_FILE 2>&1 $TAG"

# Remove old job if exists (using tag)
crontab -l 2>/dev/null | grep -v "$TAG" > /tmp/cron.tmp

# Add new job
echo "$CRON_CMD" >> /tmp/cron.tmp
crontab /tmp/cron.tmp
rm /tmp/cron.tmp

# 6. Run Initial Sync
log_info "正在执行首次同步..."
"$SYNC_SCRIPT_PATH"

log_success "证书同步配置完成！"
log_info "证书存储目录: /certs/"
log_info "日志文件: $LOG_FILE"
