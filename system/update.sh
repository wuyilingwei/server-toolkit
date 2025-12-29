#!/bin/bash
# System Update Script

echo "=========================================="
echo "         系统更新脚本"
echo "=========================================="
echo ""

# 检查是否以 root 权限运行
if [ "$EUID" -ne 0 ]; then 
    echo "错误: 此脚本需要 root 权限运行"
    echo "请使用 sudo 执行此脚本"
    exit 1
fi

echo "正在更新软件包列表..."
apt update

echo ""
echo "正在升级已安装的软件包..."
apt upgrade -y

echo ""
echo "正在清理不需要的软件包..."
apt autoremove -y
apt autoclean

echo ""
echo "=========================================="
echo "         系统更新完成！"
echo "=========================================="
