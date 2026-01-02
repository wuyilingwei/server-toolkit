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
echo -e "${COLOR_YELLOW}建议设置目录权限为 700 (仅所有者可读写执行) 以保护证书安全${COLOR_RESET}"
echo -n "是否设置 cert/local 目录权限为 700? (y/n，默认: y，Enter确认): "
read set_perm

if [ -z "$set_perm" ] || [ "$set_perm" = "y" ] || [ "$set_perm" = "Y" ]; then
    chmod 700 "$CERT_LOCAL_DIR"
    log_success "已设置 cert/local 目录权限为 700"
else
    log_warning "跳过权限设置，当前权限: $(stat -c '%a' "$CERT_LOCAL_DIR")"
fi

# 2. List Available Certificate Keys
log_info "正在获取可用的证书密钥列表..."

RESPONSE=$(curl -s -m 10 -X POST "$SYS_VAULT_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $SYS_DEVICE_UUID" \
    -d '{"ops": [{"id": "list_certs", "type": "list", "module": "certs"}]}')

# Check for errors safely - handle potential control characters in response
if [ -z "$RESPONSE" ]; then
    log_error "获取列表失败: 空响应"
    exit 1
fi

# Validate and parse JSON response directly without modifying control characters
# jq can handle properly escaped \n in JSON strings
if ! echo "$RESPONSE" | jq -e '.[0].status == 200' >/dev/null 2>&1; then
    ERR_MSG=$(echo "$RESPONSE" | jq -r 'if type=="array" then .[0].error // .[0].message else .error // .message end // "Unknown error"' 2>/dev/null) || ERR_MSG="Response format error"
    log_error "获取列表失败: ${ERR_MSG}"
    exit 1
fi

# Parse keys from list response
ALL_KEYS=$(echo "$RESPONSE" | jq -r '.[0].data[] | .key' 2>/dev/null)

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

# 检查每个域名的可用证书类型
echo -e "${COLOR_BLUE}=== 检测到的域名和可用证书类型 ===${COLOR_RESET}"
i=1
declare -A domain_map
declare -A prod_available
declare -A cf_available

while IFS= read -r domain; do
    echo "[$i] $domain"
    domain_map[$i]="$domain"
    
    # 检查生产证书
    prod_certs=""
    if echo "$ALL_KEYS" | grep -q "^${domain}-cert$"; then
        prod_certs="${prod_certs}cert "
    fi
    if echo "$ALL_KEYS" | grep -q "^${domain}-fullchain$"; then
        prod_certs="${prod_certs}fullchain "
    fi
    if echo "$ALL_KEYS" | grep -q "^${domain}-privkey$"; then
        prod_certs="${prod_certs}privkey "
    fi
    
    # 检查源站证书
    cf_certs=""
    if echo "$ALL_KEYS" | grep -q "^${domain}-cf-cert$"; then
        cf_certs="${cf_certs}cf-cert "
    fi
    if echo "$ALL_KEYS" | grep -q "^${domain}-cf-privkey$"; then
        cf_certs="${cf_certs}cf-privkey "
    fi
    
    if [ -n "$prod_certs" ]; then
        echo "    生产证书: ${COLOR_GREEN}${prod_certs}${COLOR_RESET}"
        prod_available[$i]="true"
    fi
    
    if [ -n "$cf_certs" ]; then
        echo "    源站证书: ${COLOR_YELLOW}${cf_certs}${COLOR_RESET}"
        cf_available[$i]="true"
    fi
    
    if [ -z "$prod_certs" ] && [ -z "$cf_certs" ]; then
        echo "    ${COLOR_RED}无可用证书${COLOR_RESET}"
    fi
    
    ((i++))
done <<< "$DOMAINS"
echo ""

# 3. Select Domains for Production Certificates
echo -e "${COLOR_GREEN}=== 选择要同步的生产证书 ===${COLOR_RESET}"
echo "生产证书包含: domain-cert, domain-fullchain, domain-privkey"
echo ""

# 检查是否已有配置
current_prod_domains=""
if [ -f "$CONFIG_FILE" ]; then
    current_prod_domains=$(jq -r '.production[]?' "$CONFIG_FILE" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
fi

echo -e "${COLOR_BLUE}可选择的生产证书域名:${COLOR_RESET}"

# 按正确顺序显示有生产证书的域名
prod_available_list=""
for ((idx=1; idx<=i-1; idx++)); do
    if [ "${prod_available[$idx]}" = "true" ]; then
        echo "[$idx] ${domain_map[$idx]}"
        if [ -n "$prod_available_list" ]; then
            prod_available_list="$prod_available_list,$idx"
        else
            prod_available_list="$idx"
        fi
    fi
done

if [ -z "$prod_available_list" ]; then
    echo -e "${COLOR_RED}没有可用的生产证书${COLOR_RESET}"
    echo ""
else
    echo ""
    if [ -n "$current_prod_domains" ]; then
        echo -e "${COLOR_CYAN}当前已配置的生产证书: $current_prod_domains${COLOR_RESET}"
        echo -n "请输入要同步的域名编号 (逗号分隔，例如 1,3 或输入 'all' 同步所有，Enter保持不变): "
    else
        echo -n "请输入要同步的域名编号 (逗号分隔，例如 1,3 或输入 'all' 同步所有，留空跳过): "
    fi
    read prod_selection
fi

PROD_DOMAINS=""
if [ -z "$prod_selection" ] && [ -n "$current_prod_domains" ]; then
    # 空选择且有现有配置，保持不变
    IFS=',' read -ra current_domains <<< "$current_prod_domains"
    for domain in "${current_domains[@]}"; do
        PROD_DOMAINS="$PROD_DOMAINS
$domain"
    done
    log_success "保持现有的生产证书配置"
elif [ "$prod_selection" = "all" ]; then
    # 只选择有生产证书的域名
    for idx in $(seq 1 $((i-1))); do
        if [ "${prod_available[$idx]}" = "true" ]; then
            PROD_DOMAINS="$PROD_DOMAINS
${domain_map[$idx]}"
        fi
    done
elif [ -n "$prod_selection" ]; then
    IFS=',' read -ra ADDR <<< "$prod_selection"
    for id in "${ADDR[@]}"; do
        id=$(echo "$id" | xargs)  # trim whitespace
        if [ -n "${domain_map[$id]}" ] && [ "${prod_available[$id]}" = "true" ]; then
            PROD_DOMAINS="$PROD_DOMAINS
${domain_map[$id]}"
        elif [ -n "${domain_map[$id]}" ]; then
            log_warning "域名 ${domain_map[$id]} 没有可用的生产证书，已跳过"
        fi
    done
fi


echo ""
echo -e "${COLOR_GREEN}=== 选择要同步的源站证书 (Cloudflare Origin) ===${COLOR_RESET}"
echo "源站证书包含: domain-cf-cert, domain-cf-privkey"
echo ""

# 检查是否已有配置
current_cf_domains=""
if [ -f "$CONFIG_FILE" ]; then
    current_cf_domains=$(jq -r '.cf_origin[]?' "$CONFIG_FILE" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
fi

echo -e "${COLOR_BLUE}可选择的源站证书域名:${COLOR_RESET}"

# 按正确顺序显示有源站证书的域名
cf_available_list=""
for ((idx=1; idx<=i-1; idx++)); do
    if [ "${cf_available[$idx]}" = "true" ]; then
        echo "[$idx] ${domain_map[$idx]}"
        if [ -n "$cf_available_list" ]; then
            cf_available_list="$cf_available_list,$idx"
        else
            cf_available_list="$idx"
        fi
    fi
done

if [ -z "$cf_available_list" ]; then
    echo -e "${COLOR_RED}没有可用的源站证书${COLOR_RESET}"
    echo ""
else
    echo ""
    if [ -n "$current_cf_domains" ]; then
        echo -e "${COLOR_CYAN}当前已配置的源站证书: $current_cf_domains${COLOR_RESET}"
        echo -n "请输入要同步的域名编号 (逗号分隔，例如 1,3 或输入 'all' 同步所有，Enter保持不变): "
    else
        echo -n "请输入要同步的域名编号 (逗号分隔，例如 1,3 或输入 'all' 同步所有，留空跳过): "
    fi
    read cf_selection
fi

CF_DOMAINS=""
if [ -z "$cf_selection" ] && [ -n "$current_cf_domains" ]; then
    # 空选择且有现有配置，保持不变
    IFS=',' read -ra current_domains <<< "$current_cf_domains"
    for domain in "${current_domains[@]}"; do
        CF_DOMAINS="$CF_DOMAINS
$domain"
    done
    log_success "保持现有的源站证书配置"
elif [ "$cf_selection" = "all" ]; then
    # 只选择有源站证书的域名
    for idx in $(seq 1 $((i-1))); do
        if [ "${cf_available[$idx]}" = "true" ]; then
            CF_DOMAINS="$CF_DOMAINS
${domain_map[$idx]}"
        fi
    done
elif [ -n "$cf_selection" ]; then
    IFS=',' read -ra ADDR <<< "$cf_selection"
    for id in "${ADDR[@]}"; do
        id=$(echo "$id" | xargs)  # trim whitespace
        if [ -n "${domain_map[$id]}" ] && [ "${cf_available[$id]}" = "true" ]; then
            CF_DOMAINS="$CF_DOMAINS
${domain_map[$id]}"
        elif [ -n "${domain_map[$id]}" ]; then
            log_warning "域名 ${domain_map[$id]} 没有可用的源站证书，已跳过"
        fi
    done
fi

# 显示选择结果
echo ""
echo -e "${COLOR_CYAN}=== 证书同步选择确认 ===${COLOR_RESET}"
if [ -n "$PROD_DOMAINS" ]; then
    echo -e "${COLOR_GREEN}已选择的生产证书域名:${COLOR_RESET}"
    while IFS= read -r domain; do
        [ -z "$domain" ] && continue
        echo "  - $domain (cert, fullchain, privkey)"
    done <<< "$PROD_DOMAINS"
else
    echo -e "${COLOR_YELLOW}未选择生产证书${COLOR_RESET}"
fi

if [ -n "$CF_DOMAINS" ]; then
    echo -e "${COLOR_GREEN}已选择的源站证书域名:${COLOR_RESET}"
    while IFS= read -r domain; do
        [ -z "$domain" ] && continue
        echo "  - $domain (cf-cert, cf-privkey)"
    done <<< "$CF_DOMAINS"
else
    echo -e "${COLOR_YELLOW}未选择源站证书${COLOR_RESET}"
fi
echo ""

# Check if at least something was selected
if [ -z "$PROD_DOMAINS" ] && [ -z "$CF_DOMAINS" ]; then
    echo ""
    log_warning "未选择任何域名或证书类型"
    echo ""
    echo -e "${COLOR_CYAN}您有以下选择:${COLOR_RESET}"
    echo "1. 重新运行该脚本进行选择"
    echo "2. 检查 Vault 中是否存在所需的证书密钥"
    echo "3. 确认您的设备 UUID 和 Vault URL 配置正确"
    echo ""
    echo -n "是否要继续配置符号链接和定时任务? (y/n, 默认: n): "
    read continue_setup
    
    if [ "$continue_setup" != "y" ] && [ "$continue_setup" != "Y" ]; then
        log_info "用户选择退出"
        exit 0
    else
        log_info "继续进行基本配置..."
    fi
fi

# 5. Ask about symbolic links
echo ""
echo -e "${COLOR_CYAN}=== 符号链接配置 ===${COLOR_RESET}"
echo "可以创建符号链接到常用的证书目录，方便其他服务使用"
echo ""

# 检查现有配置
current_etc_ssl="false"
current_nginx_ssl="false"
if [ -f "$CONFIG_FILE" ]; then
    current_etc_ssl=$(jq -r '.symlinks.etc_ssl // false' "$CONFIG_FILE" 2>/dev/null)
    current_nginx_ssl=$(jq -r '.symlinks.nginx_ssl // false' "$CONFIG_FILE" 2>/dev/null)
fi

if [ "$current_etc_ssl" = "true" ]; then
    echo -n "是否创建 /etc/ssl 符号链接? (当前: 已启用, y/n, Enter保持不变): "
else
    echo -n "是否创建 /etc/ssl 符号链接? (y/n，默认: n，Enter确认): "
fi
read link_etc_ssl
CREATE_ETC_SSL_LINK="false"
if [ -z "$link_etc_ssl" ] && [ "$current_etc_ssl" = "true" ]; then
    # 空选择且已启用，保持不变
    CREATE_ETC_SSL_LINK="true"
    log_success "保持 /etc/ssl 符号链接已启用"
elif [ "$link_etc_ssl" = "y" ] || [ "$link_etc_ssl" = "Y" ]; then
    CREATE_ETC_SSL_LINK="true"
    log_success "将创建 /etc/ssl 符号链接"
else
    log_info "不创建 /etc/ssl 符号链接"
fi

if [ "$current_nginx_ssl" = "true" ]; then
    echo -n "是否创建 /etc/nginx/ssl 符号链接? (当前: 已启用, y/n, Enter保持不变): "
else
    echo -n "是否创建 /etc/nginx/ssl 符号链接? (y/n，默认: n，Enter确认): "
fi
read link_nginx_ssl
CREATE_NGINX_SSL_LINK="false"
if [ -z "$link_nginx_ssl" ] && [ "$current_nginx_ssl" = "true" ]; then
    # 空选择且已启用，保持不变
    CREATE_NGINX_SSL_LINK="true"
    log_success "保持 /etc/nginx/ssl 符号链接已启用"
elif [ "$link_nginx_ssl" = "y" ] || [ "$link_nginx_ssl" = "Y" ]; then
    CREATE_NGINX_SSL_LINK="true"
    log_success "将创建 /etc/nginx/ssl 符号链接"
else
    log_info "不创建 /etc/nginx/ssl 符号链接"
fi

# 6. Generate Configuration File
log_info "生成配置文件: $CONFIG_FILE"

# Build JSON configuration
CONFIG_JSON='{"production":[],"cf_origin":[],"symlinks":{"etc_ssl":false,"nginx_ssl":false},"reload_command":""}'

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

# Add symlink configuration
CONFIG_JSON=$(echo "$CONFIG_JSON" | jq \
    --argjson etc_ssl "$CREATE_ETC_SSL_LINK" \
    --argjson nginx_ssl "$CREATE_NGINX_SSL_LINK" \
    '.symlinks.etc_ssl = $etc_ssl | .symlinks.nginx_ssl = $nginx_ssl')

# Add reload command configuration
if [ -n "$RELOAD_COMMAND" ]; then
    CONFIG_JSON=$(echo "$CONFIG_JSON" | jq --arg cmd "$RELOAD_COMMAND" '.reload_command = $cmd')
fi

echo "$CONFIG_JSON" | jq '.' > "$CONFIG_FILE"

log_success "配置已保存到: $CONFIG_FILE"
echo ""
echo "配置内容:"
cat "$CONFIG_FILE"
echo ""

# 7. Deploy Worker Script
log_info "部署同步脚本: $SYNC_SCRIPT_PATH"

# Get the directory where deploy.sh is located (scripts directory in repo)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_TEMPLATE="$SCRIPT_DIR/worker.sh"

# Check if template exists
if [ ! -f "$WORKER_TEMPLATE" ]; then
    log_error "工作脚本模板不存在: $WORKER_TEMPLATE"
    exit 1
fi

# Copy worker template to storage directory
cp "$WORKER_TEMPLATE" "$SYNC_SCRIPT_PATH"

chmod +x "$SYNC_SCRIPT_PATH"

# 8. Setup Cron Job with #server-toolkit-cert tag
log_info "配置定时任务 (每小时执行一次)..."
TAG="# server-toolkit-cert"
CRON_CMD="0 * * * * $SYNC_SCRIPT_PATH >> $LOG_FILE 2>&1 $TAG"

# Remove all old cert jobs (with server-toolkit-cert tag)
crontab -l 2>/dev/null | grep -v "server-toolkit-cert" > /tmp/cron.tmp || true

# Add new job
echo "$CRON_CMD" >> /tmp/cron.tmp
crontab /tmp/cron.tmp
rm /tmp/cron.tmp

log_success "定时任务已配置"

# 10. 配置自定义重载命令
echo ""
echo -e "${COLOR_CYAN}=== 服务重载命令配置 ===${COLOR_RESET}"

# 从配置文件读取当前命令
current_reload_cmd=""
if [ -f "$CONFIG_FILE" ]; then
    current_reload_cmd=$(jq -r '.reload_command // ""' "$CONFIG_FILE" 2>/dev/null)
fi

if [ -n "$current_reload_cmd" ]; then
    echo -n "请输入证书更新后的重载命令 (当前: $current_reload_cmd，Enter保持不变): "
else
    echo -n "请输入证书更新后的重载命令 (推荐: nginx -t && nginx -s reload): "
fi
read reload_cmd

# 处理重载命令配置
RELOAD_COMMAND=""
if [ -z "$reload_cmd" ] && [ -n "$current_reload_cmd" ]; then
    # 空选择且有现有配置，保持不变
    RELOAD_COMMAND="$current_reload_cmd"
    log_success "保持现有的重载命令: $current_reload_cmd"
elif [ -n "$reload_cmd" ]; then
    RELOAD_COMMAND="$reload_cmd"
    log_success "重载命令已设置: $reload_cmd"
else
    log_warning "未设置重载命令，证书更新后不会自动重载服务"
fi

# 11. Run Initial Sync
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
