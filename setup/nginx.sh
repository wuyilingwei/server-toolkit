#!/bin/bash
set -e

# 检查root权限
if [ "$EUID" -ne 0 ]; then
    echo "错误: 需要root权限执行此脚本"
    echo "请使用: sudo bash $0"
    exit 1
fi

# 检查系统兼容性
if ! command -v apt >/dev/null 2>&1; then
    echo "错误: 此脚本仅支持基于apt的系统（Ubuntu/Debian）"
    exit 1
fi

# 检查是否已安装nginx
if systemctl is-active --quiet nginx 2>/dev/null; then
    echo "警告: Nginx 已在运行，将重新配置默认站点"
fi

echo "🚀 Install nginx..."
sudo apt update
sudo apt install -y nginx

echo "📦 Backup existing site configuration..."
# 创建备份目录
BACKUP_DIR="/etc/nginx/backup/$(date +"%Y%m%d_%H%M%S")"
sudo mkdir -p "$BACKUP_DIR"
sudo chmod 755 "$BACKUP_DIR"

# 备份现有配置文件
BACKUP_COUNT=0
if [ -f /etc/nginx/sites-available/default ]; then
    sudo mv /etc/nginx/sites-available/default "$BACKUP_DIR/sites-available-default"
    echo "✅ 已备份 sites-available/default 到 $BACKUP_DIR/"
    BACKUP_COUNT=$((BACKUP_COUNT + 1))
fi
if [ -L /etc/nginx/sites-enabled/default ]; then
    sudo rm /etc/nginx/sites-enabled/default
    echo "✅ 已移除 sites-enabled/default 链接"
fi

if [ "$BACKUP_COUNT" -eq 0 ]; then
    echo "ℹ️  没有找到需要备份的默认配置文件"
    sudo rmdir "$BACKUP_DIR" 2>/dev/null || true
else
    echo "📁 备份完成，位置: $BACKUP_DIR"
fi

echo "🧹 Remove default site configuration (already backed up)..."

echo "🧹 Remove rsync + reload cron tasks (by tag) ..."
TAG="#rsync-nginx-default"
crontab -l 2>/dev/null | grep -v "$TAG" > /tmp/clean_cron || true
crontab /tmp/clean_cron 2>/dev/null || true
rm -f /tmp/clean_cron

echo "🔒 Configure nginx security settings..."
# 配置 server_tokens off，确保没有重复且正确设置
if grep -q "^[[:space:]]*server_tokens" /etc/nginx/nginx.conf; then
    # 如果已存在 server_tokens 配置，替换为 off
    sudo sed -i 's/^[[:space:]]*server_tokens.*$/\tserver_tokens off;/' /etc/nginx/nginx.conf
    echo "✅ 已更新现有的 server_tokens 为 off"
elif grep -q "^[[:space:]]*#[[:space:]]*server_tokens" /etc/nginx/nginx.conf; then
    # 如果存在注释的 server_tokens，替换为启用的 off
    sudo sed -i 's/^[[:space:]]*#[[:space:]]*server_tokens.*$/\tserver_tokens off;/' /etc/nginx/nginx.conf
    echo "✅ 已启用并设置 server_tokens off"
else
    # 如果不存在，添加到 http 块
    sudo sed -i '/http {/a\\tserver_tokens off;' /etc/nginx/nginx.conf
    echo "✅ 已添加 server_tokens off 到 nginx.conf"
fi

echo "🛠️ Write custom default site configuration..."
cat <<'EOF' | sudo tee /etc/nginx/sites-available/00-default > /dev/null
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    server_name _;

    location / {
        return 403 '<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Access Denied</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            background-color: #f4f4f4;
            color: #333;
            max-width: 700px;
            margin: 50px auto;
            padding: 20px;
            line-height: 1.6;
        }
        h1 {
            color: #cc0000;
        }
    </style>
</head>
<body>
    <h1>Access Denied</h1>
    <p>Your request could not be processed.</p>
    <p>Possible reasons include, but are not limited to:</p>
    <ul>
        <li>Direct IP access is not permitted.</li>
        <li>Missing or invalid domain, path, or query parameters.</li>
        <li>Unsupported request method or protocol.</li>
        <li>Insufficient authorization credentials.</li>
        <li>Security or access control policies in effect.</li>
        <li>Request blocked due to suspicious or flagged behavior.</li>
        <li>Server maintenance, reconfiguration, or migration in progress.</li>
    </ul>
    <p>If you believe this is an error, please contact the site administrator.</p>
</body>
</html>';
        add_header Content-Type text/html;
    }
}

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;

    server_name _;

    ssl_reject_handshake on;
}

EOF

echo "🔗 Enable 00-default configuration..."
sudo ln -sf /etc/nginx/sites-available/00-default /etc/nginx/sites-enabled/00-default

echo "✅ Test nginx config..."
sudo nginx -t

echo "🔁 Restart nginx..."
sudo systemctl restart nginx

echo "✅ nginx installation and configuration completed. Default site is in effect."
