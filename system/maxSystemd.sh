#!/bin/bash
set -e

[ "$EUID" -eq 0 ] || { echo "请以root运行（sudo）"; exit 1; }

# 显示当前状态
echo ""
echo "=========================================="
echo "当前systemd日志状态："
echo "=========================================="
echo "当前磁盘使用情况："
df -h /
echo ""
echo "journald日志大小："
journalctl --disk-usage
echo ""

# 显示当前配置
if [ -f /etc/systemd/journald.conf ]; then
    echo "当前 journald.conf 配置："
    grep -E "^(SystemMaxUse|SystemKeepFree|SystemMaxFileSize)" /etc/systemd/journald.conf || echo "（没有自定义配置）"
    echo ""
fi

echo "警告: 即将对systemd日志进行以下操作："
echo "  - 清理日志到 100MB"
echo "  - 设置最大使用 200MB"
echo "  - 保留空间 500MB"
echo "  - 单文件最大 50MB"
echo "  - 重启 journald 服务"
echo ""

# 询问确认
read -rp "是否继续执行优化? (y/n, 默认y): " confirm
confirm="${confirm:-y}"

if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "操作已取消"
    exit 0
fi

echo "正在执行 systemd 日志优化..."
echo ""
echo ">>> 清理 systemd 日志到 100MB..."
journalctl --vacuum-size=100M

echo ">>> 设置 /etc/systemd/journald.conf 限制日志大小..."
sed -i "s/^#SystemMaxUse=.*/SystemMaxUse=200M/" /etc/systemd/journald.conf
sed -i "s/^#SystemKeepFree=.*/SystemKeepFree=500M/" /etc/systemd/journald.conf
sed -i "s/^#SystemMaxFileSize=.*/SystemMaxFileSize=50M/" /etc/systemd/journald.conf

# 如果没有这些字段，则追加
grep -q "^SystemMaxUse=" /etc/systemd/journald.conf || echo "SystemMaxUse=200M" >> /etc/systemd/journald.conf
grep -q "^SystemKeepFree=" /etc/systemd/journald.conf || echo "SystemKeepFree=500M" >> /etc/systemd/journald.conf
grep -q "^SystemMaxFileSize=" /etc/systemd/journald.conf || echo "SystemMaxFileSize=50M" >> /etc/systemd/journald.conf

echo ">>> 重启 journald 服务..."
systemctl restart systemd-journald

echo ">>> 可选：清理 apt 缓存（不会影响系统）..."
apt-get clean

echo ">>> 操作完成！当前磁盘占用："
df -h /
echo ""
echo "当前 journald 日志占用："
journalctl --disk-usage
