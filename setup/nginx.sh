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

echo "🧹 Delete default site configuration..."
sudo rm -f /etc/nginx/sites-enabled/default
sudo rm -f /etc/nginx/sites-available/default

echo "📁 Create default page directory under /etc/nginx/ ..."
sudo mkdir -p /etc/nginx/default-site

echo "🧾 Write default Access Denied page..."
cat <<'EOF' | sudo tee /etc/nginx/default-site/index.html > /dev/null
<!DOCTYPE html> 
<html lang="en">
  <head>
    <meta charset="UTF-8" />
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
</html>
EOF

echo "🔐 Create self-signed certificate (fallback.crt / fallback.key)..."
AVAI=$((RANDOM % 50001 + 50000))
sudo openssl req -x509 -nodes -days $AVAI -newkey rsa:2048 \
-keyout /etc/nginx/fallback.key \
-out /etc/nginx/fallback.crt \
-subj "/CN=example.com" \
-addext "subjectAltName=DNS:_" >/dev/null 2>&1

echo "🧹 Remove rsync + reload cron tasks (by tag) ..."
TAG="#rsync-nginx-default"
crontab -l 2>/dev/null | grep -v "$TAG" > /tmp/clean_cron || true
crontab /tmp/clean_cron 2>/dev/null || true
rm -f /tmp/clean_cron

echo "🛠️ Write custom default site configuration..."
cat <<'EOF' | sudo tee /etc/nginx/sites-available/00-default > /dev/null
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    server_name _;

    root /etc/nginx/default-site;
    index index.html;

    location / {
        try_files /index.html =200;
    }
}

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;

    server_name _;

    ssl_certificate     /etc/nginx/fallback.crt;
    ssl_certificate_key /etc/nginx/fallback.key;

    return 444;
}
EOF

echo "🔗 Enable 00-default configuration..."
sudo ln -sf /etc/nginx/sites-available/00-default /etc/nginx/sites-enabled/00-default

echo "✅ Test nginx config..."
sudo nginx -t

echo "🔁 Restart nginx..."
sudo systemctl restart nginx

echo "✅ nginx installation and configuration completed. Default site is in effect."
