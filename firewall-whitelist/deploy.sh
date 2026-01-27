#!/bin/bash
# Firewall Whitelist Deployment Script
# (Formerly: SSH Security)

# Configuration constants
DOCKER_NETWORK_CIDR="172.16.0.0/12"
HTTP_PORTS="80,443"  # Publicly accessible web service ports in strict mode
SSH_PORT="22"        # SSH port, always restricted to whitelist

# Module identifiers (for backward compatibility)
MODULE_ID="firewall-whitelist"
LEGACY_MODULE_ID="ssh-security"
IPTABLES_TAG="#firewall-whitelist"
LEGACY_IPTABLES_TAG="#ssh-security"

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

# 加载 helper 函数
if [ -f "$WORKDIR/helper.sh" ]; then
    source "$WORKDIR/helper.sh"
else
    echo "错误: 找不到 helper.sh"
    exit 1
fi

# Storage directory for persistent data (with backward compatibility)
STORAGE_DIR="$WORKDIR/storage/$MODULE_ID"
LEGACY_STORAGE_DIR="$WORKDIR/storage/$LEGACY_MODULE_ID"

# Migrate from old storage directory if it exists
if [ -d "$LEGACY_STORAGE_DIR" ] && [ ! -d "$STORAGE_DIR" ]; then
    echo -e "${COLOR_YELLOW}检测到旧版本数据目录，正在迁移...${COLOR_RESET}"
    mv "$LEGACY_STORAGE_DIR" "$STORAGE_DIR"
    echo -e "${COLOR_GREEN}✓ 数据迁移完成${COLOR_RESET}"
fi

mkdir -p "$STORAGE_DIR"

echo -e "${COLOR_BLUE}========================================${COLOR_RESET}"
echo -e "${COLOR_BLUE}      防火墙白名单部署脚本${COLOR_RESET}"
echo -e "${COLOR_BLUE}========================================${COLOR_RESET}"

# 1. 检查环境变量配置状态
echo -e "\n${COLOR_BLUE}步骤 1: 检查配置状态${COLOR_RESET}"

UUID_CONFIGURED=false
VAULT_CONFIGURED=false

if grep -q "SYS_DEVICE_UUID" /etc/environment; then
    UUID_CONFIGURED=true
    echo -e "${COLOR_GREEN}✓ SYS_DEVICE_UUID 已配置${COLOR_RESET}"
else
    echo -e "${COLOR_RED}✗ SYS_DEVICE_UUID 未配置${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}  请使用以下命令配置 UUID:${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}  echo 'SYS_DEVICE_UUID=\"your-uuid-here\"' >> /etc/environment${COLOR_RESET}"
fi

if grep -q "SYS_VAULT_URL" /etc/environment; then
    VAULT_CONFIGURED=true
    echo -e "${COLOR_GREEN}✓ SYS_VAULT_URL 已配置${COLOR_RESET}"
else
    echo -e "${COLOR_RED}✗ SYS_VAULT_URL 未配置${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}  请使用以下命令配置 Vault URL:${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}  echo 'SYS_VAULT_URL=\"https://your-vault-url/api/data\"' >> /etc/environment${COLOR_RESET}"
fi

if [ "$UUID_CONFIGURED" = false ] || [ "$VAULT_CONFIGURED" = false ]; then
    echo -e "\n${COLOR_RED}错误: 缺少必要配置。请完成配置后重新运行此脚本。${COLOR_RESET}"
    exit 1
fi

echo -e "${COLOR_GREEN}✓ 所有必要配置已就绪${COLOR_RESET}"

# 2. 安装依赖
echo -e "\n${COLOR_BLUE}步骤 2: 安装依赖软件包${COLOR_RESET}"
if ! apt update; then
    echo -e "${COLOR_RED}错误: 软件包列表更新失败${COLOR_RESET}"
    exit 1
fi
apt install -y jq curl ipset iptables

# 3. 部署 worker 脚本
echo -e "\n${COLOR_BLUE}步骤 3: 部署同步 worker 脚本${COLOR_RESET}"
WORKER_SCRIPT="$STORAGE_DIR/worker.sh"
LOG_FILE="$STORAGE_DIR/sync.log"

# 复制 worker 脚本模板到 storage 目录
cp "$WORKDIR/scripts/$MODULE_ID/worker.sh" "$WORKER_SCRIPT"
chmod +x "$WORKER_SCRIPT"

echo -e "${COLOR_GREEN}✓ Worker 脚本已部署到: $WORKER_SCRIPT${COLOR_RESET}"

# 3.5. 选择防火墙模式
echo -e "\n${COLOR_BLUE}步骤 3.5: 选择防火墙模式${COLOR_RESET}"
echo -e "${COLOR_YELLOW}请选择 IP 白名单策略模式:${COLOR_RESET}"
echo -e "${COLOR_CYAN}  [1] 宽松模式 (loose)${COLOR_RESET} - 仅限制 SSH 端口 22 到白名单"
echo -e "${COLOR_CYAN}  [2] 严格模式 (strict)${COLOR_RESET} - SSH 仅限白名单，HTTP/HTTPS 公开，其他端口仅限本机/Docker/白名单"
echo ""

# 读取用户选择并存储到配置文件
MODE_CONFIG="$STORAGE_DIR/firewall_mode.conf"
if [ -f "$MODE_CONFIG" ]; then
    CURRENT_MODE=$(cat "$MODE_CONFIG")
    echo -e "${COLOR_YELLOW}当前模式: $CURRENT_MODE${COLOR_RESET}"
fi

mode_choice=$(input_single_char "请输入选择 (1=宽松, 2=严格)" "1")

if [ "$mode_choice" = "2" ]; then
    FIREWALL_MODE="strict"
    echo -e "${COLOR_GREEN}✓ 已选择严格模式${COLOR_RESET}"
else
    FIREWALL_MODE="loose"
    echo -e "${COLOR_GREEN}✓ 已选择宽松模式${COLOR_RESET}"
fi

# 保存模式到配置文件
echo "$FIREWALL_MODE" > "$MODE_CONFIG"

# 3.6. 设置默认拒绝规则（在白名单同步前先拒绝）
echo -e "\n${COLOR_BLUE}步骤 3.6: 设置默认拒绝规则${COLOR_RESET}"
# 清理旧的规则（包括旧版本的标签）
iptables -S INPUT | grep "$LEGACY_IPTABLES_TAG" | sed "s/-A/iptables -D/" | bash 2>/dev/null || true
iptables -S INPUT | grep "$IPTABLES_TAG" | sed "s/-A/iptables -D/" | bash 2>/dev/null || true

# 根据模式设置规则
if [ "$FIREWALL_MODE" = "strict" ]; then
    echo -e "${COLOR_YELLOW}严格模式: 配置全局防火墙规则${COLOR_RESET}"
    # 严格模式：SSH 仅限白名单，HTTP/HTTPS 公开，其他端口仅限本机、Docker和白名单
    # 注意：这些规则会被 worker.sh 维护和更新
    
    # 基础规则：允许已建立的连接（系统可能已有此规则，但显式添加确保一致性）
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT -m comment --comment "$IPTABLES_TAG" 2>/dev/null || true
    
    # 允许本机访问
    iptables -A INPUT -i lo -j ACCEPT -m comment --comment "$IPTABLES_TAG"
    
    # 允许 Docker 网络访问
    iptables -A INPUT -s "$DOCKER_NETWORK_CIDR" -j ACCEPT -m comment --comment "$IPTABLES_TAG"
    
    # 严格模式: 仅允许 HTTP/HTTPS 从任何来源访问，SSH 仅限白名单
    iptables -A INPUT -p tcp -m multiport --dports "$HTTP_PORTS" -j ACCEPT -m comment --comment "$IPTABLES_TAG"
    
    # SSH 端口拒绝（会被白名单规则优先覆盖）
    iptables -A INPUT -p tcp --dport "$SSH_PORT" -j DROP -m comment --comment "$IPTABLES_TAG"
    
    # 其他所有端口拒绝（会被白名单规则优先覆盖）
    iptables -A INPUT -j DROP -m comment --comment "$IPTABLES_TAG"
    
    echo -e "${COLOR_GREEN}✓ 严格模式规则已设置${COLOR_RESET}"
else
    echo -e "${COLOR_YELLOW}宽松模式: 仅限制 SSH 端口${COLOR_RESET}"
    # 宽松模式：只限制 SSH 端口
    iptables -A INPUT -p tcp --dport "$SSH_PORT" -j DROP -m comment --comment "$IPTABLES_TAG"
    echo -e "${COLOR_GREEN}✓ 宽松模式规则已设置（仅限制 SSH）${COLOR_RESET}"
fi

# 4. 管理 Crontab
echo -e "\n${COLOR_BLUE}步骤 4: 配置定时任务${COLOR_RESET}"
# 清理旧的 cron 任务（如果存在）
cron_remove "$LEGACY_MODULE_ID"
# 添加新的 cron 任务
cron_add "$MODULE_ID" "*/10 * * * *" "/bin/sh $WORKER_SCRIPT >> $LOG_FILE 2>&1"

# 5. 立即执行首次同步
echo -e "\n${COLOR_BLUE}步骤 5: 执行首次同步${COLOR_RESET}"
/bin/sh "$WORKER_SCRIPT"

echo -e "\n${COLOR_GREEN}========================================${COLOR_RESET}"
echo -e "${COLOR_GREEN}         部署完成！层级防护已就绪${COLOR_RESET}"
echo -e "${COLOR_GREEN}========================================${COLOR_RESET}"
echo -e "${COLOR_GREEN}防火墙模式: $FIREWALL_MODE${COLOR_RESET}"
if [ "$FIREWALL_MODE" = "strict" ]; then
    echo -e "${COLOR_GREEN}严格模式规则:${COLOR_RESET}"
    echo -e "${COLOR_GREEN}  • 白名单 IP: 可访问所有端口 (最高优先级)${COLOR_RESET}"
    echo -e "${COLOR_GREEN}  • 本机 (localhost): 可访问所有端口${COLOR_RESET}"
    echo -e "${COLOR_GREEN}  • Docker 网络 ($DOCKER_NETWORK_CIDR): 可访问所有端口${COLOR_RESET}"
    echo -e "${COLOR_GREEN}  • HTTP/HTTPS (80/443): 任意来源可访问${COLOR_RESET}"
    echo -e "${COLOR_RED}  • SSH (22): 仅限白名单 ⚠️${COLOR_RESET}"
    echo -e "${COLOR_RED}  • 其他端口: 拒绝 ⚠️${COLOR_RESET}"
else
    echo -e "${COLOR_GREEN}宽松模式规则:${COLOR_RESET}"
    echo -e "${COLOR_GREEN}  • 白名单 IP: 可访问所有端口${COLOR_RESET}"
    echo -e "${COLOR_RED}  • SSH 端口 22: 仅限白名单 ⚠️${COLOR_RESET}"
    echo -e "${COLOR_GREEN}  • 其他端口: 遵循系统默认规则${COLOR_RESET}"
fi
echo -e "${COLOR_YELLOW}熔断: 若 API 异常，层级防护自动失效，确保管理入口可用${COLOR_RESET}"
echo -e "Worker 脚本: $WORKER_SCRIPT"
echo -e "日志文件: $LOG_FILE"
echo -e "模式配置: $MODE_CONFIG"
echo -e "${COLOR_GREEN}========================================${COLOR_RESET}"

# 6. 交互式卸载 Fail2ban
echo -e "\n${COLOR_BLUE}可选操作: 清理旧策略${COLOR_RESET}"
if dpkg -l | grep -q fail2ban; then
    confirm=$(input_single_char "检测到 Fail2ban 已安装，是否需要卸载以清理旧策略? (y/n)" "n")
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        apt purge fail2ban -y && apt autoremove -y
        echo -e "${COLOR_GREEN}Fail2ban 已卸载${COLOR_RESET}"
    else
        echo -e "${COLOR_YELLOW}已跳过卸载${COLOR_RESET}"
    fi
else
    echo -e "${COLOR_YELLOW}未检测到 Fail2ban，跳过卸载${COLOR_RESET}"
fi
