#!/bin/bash
set -e

# 检查root权限
if [ "$EUID" -ne 0 ]; then
    echo "错误: 需要root权限执行此脚本"
    echo "请使用: sudo bash $0"
    exit 1
fi

# 检查系统兼容性
if ! command -v apt-get >/dev/null 2>&1; then
    echo "错误: 此脚本仅支持基于apt的系统（Ubuntu/Debian）"
    exit 1
fi

# 检查是否已安装docker
if command -v docker >/dev/null 2>&1; then
    echo "警告: Docker 可能已安装，将更新或重新安装"
fi

# 检查系统架构
ARCH=$(dpkg --print-architecture)
case "$ARCH" in
    amd64|arm64)
        echo "支持的架构: $ARCH"
        ;;
    *)
        echo "警告: 未经测试的架构: $ARCH，可能存在兼容性问题"
        ;;
esac

echo "🛠️ Add Docker's official GPG key..."
sudo apt-get update
sudo apt-get install ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "🛠️ Add the repository to Apt sources..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update

echo "🚀 Install Docker..."
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose docker-compose-plugin

echo "✅ docker installation and configuration completed."