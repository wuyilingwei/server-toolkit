#!/bin/bash
# SSH Security Deployment Script

# Configuration constants
DOCKER_NETWORK_CIDR="172.16.0.0/12"
COMMON_PORTS="22,80,443"

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

# Storage directory for persistent data
STORAGE_DIR="$WORKDIR/storage/ssh-security"
mkdir -p "$STORAGE_DIR"

echo -e "${COLOR_BLUE}========================================${COLOR_RESET}"
echo -e "${COLOR_BLUE}      SSH Security 部署脚本${COLOR_RESET}"
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
cp "$WORKDIR/scripts/ssh-security/worker.sh" "$WORKER_SCRIPT"
chmod +x "$WORKER_SCRIPT"

echo -e "${COLOR_GREEN}✓ Worker 脚本已部署到: $WORKER_SCRIPT${COLOR_RESET}"

# 3.5. 选择防火墙模式
echo -e "\n${COLOR_BLUE}步骤 3.5: 选择防火墙模式${COLOR_RESET}"
echo -e "${COLOR_YELLOW}请选择 IP 白名单策略模式:${COLOR_RESET}"
echo -e "${COLOR_CYAN}  [1] 宽松模式 (loose)${COLOR_RESET} - 仅限制 SSH 端口 22 到白名单"
echo -e "${COLOR_CYAN}  [2] 严格模式 (strict)${COLOR_RESET} - 除常用端口($COMMON_PORTS)外，所有端口仅允许本机、Docker 和白名单访问"
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
# 清理旧的 ssh-security 规则
iptables -S INPUT | grep "#ssh-security" | sed "s/-A/iptables -D/" | bash 2>/dev/null || true

# 根据模式设置规则
if [ "$FIREWALL_MODE" = "strict" ]; then
    echo -e "${COLOR_YELLOW}严格模式: 配置全局防火墙规则${COLOR_RESET}"
    # 严格模式：除了常用端口，其他端口只允许本机、Docker和白名单访问
    # 注意：这些规则会被 worker.sh 维护和更新
    
    # 基础规则：允许已建立的连接
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT -m comment --comment "#ssh-security" 2>/dev/null || true
    
    # 允许本机访问
    iptables -A INPUT -i lo -j ACCEPT -m comment --comment "#ssh-security"
    
    # 允许 Docker 网络访问
    iptables -A INPUT -s "$DOCKER_NETWORK_CIDR" -j ACCEPT -m comment --comment "#ssh-security"
    
    # 允许常用端口从任何来源访问
    iptables -A INPUT -p tcp -m multiport --dports "$COMMON_PORTS" -j ACCEPT -m comment --comment "#ssh-security"
    
    # 其他所有端口拒绝（会被白名单规则优先覆盖）
    iptables -A INPUT -j DROP -m comment --comment "#ssh-security"
    
    echo -e "${COLOR_GREEN}✓ 严格模式规则已设置${COLOR_RESET}"
else
    echo -e "${COLOR_YELLOW}宽松模式: 仅限制 SSH 端口${COLOR_RESET}"
    # 宽松模式：只限制 SSH 端口 22
    iptables -A INPUT -p tcp --dport 22 -j DROP -m comment --comment "#ssh-security"
    echo -e "${COLOR_GREEN}✓ 宽松模式规则已设置（仅限制 SSH）${COLOR_RESET}"
fi

# 4. 管理 Crontab
echo -e "\n${COLOR_BLUE}步骤 4: 配置定时任务${COLOR_RESET}"
cron_add "ssh-security" "*/10 * * * *" "/bin/sh $WORKER_SCRIPT >> $LOG_FILE 2>&1"

# 5. 立即执行首次同步
echo -e "\n${COLOR_BLUE}步骤 5: 执行首次同步${COLOR_RESET}"
/bin/sh "$WORKER_SCRIPT"

echo -e "\n${COLOR_GREEN}========================================${COLOR_RESET}"
echo -e "${COLOR_GREEN}         部署完成！层级防护已就绪${COLOR_RESET}"
echo -e "${COLOR_GREEN}========================================${COLOR_RESET}"
echo -e "${COLOR_GREEN}防火墙模式: $FIREWALL_MODE${COLOR_RESET}"
if [ "$FIREWALL_MODE" = "strict" ]; then
    echo -e "${COLOR_GREEN}严格模式规则:${COLOR_RESET}"
    echo -e "${COLOR_GREEN}  • 允许本机 (localhost) 所有访问${COLOR_RESET}"
    echo -e "${COLOR_GREEN}  • 允许 Docker 网络 ($DOCKER_NETWORK_CIDR) 所有访问${COLOR_RESET}"
    echo -e "${COLOR_GREEN}  • 允许任意来源访问常用端口 ($COMMON_PORTS)${COLOR_RESET}"
    echo -e "${COLOR_GREEN}  • 白名单 IP 可访问所有端口${COLOR_RESET}"
    echo -e "${COLOR_GREEN}  • 其他来源访问其他端口: 拒绝${COLOR_RESET}"
else
    echo -e "${COLOR_GREEN}宽松模式规则:${COLOR_RESET}"
    echo -e "${COLOR_GREEN}  • 仅限制 SSH 端口 22 到白名单${COLOR_RESET}"
    echo -e "${COLOR_GREEN}  • 其他端口遵循系统默认规则${COLOR_RESET}"
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
