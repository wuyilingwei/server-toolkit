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

# Color codes
COLOR_RESET="\033[0m"
COLOR_BLUE="\033[1;34m"
COLOR_GREEN="\033[1;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_RED="\033[1;31m"

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
cp "$WORKDIR/ssh-security/worker.sh" "$WORKER_SCRIPT"
chmod +x "$WORKER_SCRIPT"

echo -e "${COLOR_GREEN}✓ Worker 脚本已部署到: $WORKER_SCRIPT${COLOR_RESET}"

# 4. 管理 Crontab
echo -e "\n${COLOR_BLUE}步骤 4: 配置定时任务${COLOR_RESET}"
crontab -l 2>/dev/null | grep -v "#rsync-fail2ban" | grep -v "#ssh-security" > /tmp/cron_tmp
echo "*/10 * * * * . /etc/environment; /bin/sh $WORKER_SCRIPT >> $LOG_FILE 2>&1 #ssh-security" >> /tmp/cron_tmp
crontab /tmp/cron_tmp
rm /tmp/cron_tmp

echo -e "${COLOR_GREEN}✓ 定时任务已配置（每10分钟执行一次）${COLOR_RESET}"

# 5. 立即执行首次同步
echo -e "\n${COLOR_BLUE}步骤 5: 执行首次同步${COLOR_RESET}"
/bin/sh "$WORKER_SCRIPT"

echo -e "\n${COLOR_GREEN}========================================${COLOR_RESET}"
echo -e "${COLOR_GREEN}         部署完成！层级防护已就绪${COLOR_RESET}"
echo -e "${COLOR_GREEN}========================================${COLOR_RESET}"
echo -e "${COLOR_GREEN}层级1: 白名单 IP 放行 (IPSET: vault_global_whitelist)${COLOR_RESET}"
echo -e "${COLOR_GREEN}层级2: 非白名单 SSH 丢弃 (DROP)${COLOR_RESET}"
echo -e "${COLOR_YELLOW}熔断: 若 API 异常，层级2 自动失效，确保管理入口可用${COLOR_RESET}"
echo -e "Worker 脚本: $WORKER_SCRIPT"
echo -e "日志文件: $LOG_FILE"
echo -e "${COLOR_GREEN}========================================${COLOR_RESET}"

# 6. 交互式卸载 Fail2ban
echo -e "\n${COLOR_BLUE}可选操作: 清理旧策略${COLOR_RESET}"
read -p "是否需要直接卸载 Fail2ban 以清理旧策略? (y/n): " confirm
if [ "$confirm" = "y" ]; then
    apt purge fail2ban -y && apt autoremove -y
    echo -e "${COLOR_GREEN}Fail2ban 已卸载${COLOR_RESET}"
else
    echo -e "${COLOR_YELLOW}已跳过卸载${COLOR_RESET}"
fi
