#!/bin/bash
set -e
SWAPFILE="${SWAPFILE:-/swapfile}"
SIZE="${1:-}"

[ "$EUID" -eq 0 ] || { echo "请以root运行（sudo）"; exit 1; }

# 1. 询问交换区大小
if [ -z "$SIZE" ]; then 
    read -rp "目标交换区大小(如 8G/512M，默认 2G): " SIZE
    SIZE="${SIZE:-2G}"
fi

parse(){ 
    s="$1"
    [[ $s =~ ^([0-9]+)([KkMmGgTt]?)$ ]] || { echo "无效大小: $s" >&2; exit 1; }
    n=${BASH_REMATCH[1]}
    u=${BASH_REMATCH[2]}
    case "$u" in 
        ""|[Gg]) echo $((n*1024));; 
        [Mm]) echo $n;; 
        [Kk]) echo $(((n+1023)/1024));; 
        [Tt]) echo $((n*1024*1024));; 
    esac
}

MIB="$(parse "$SIZE")"

# 2. 询问 Swappiness 并介绍
echo -e "\n[?] 什么是 Swappiness? (0-100)\n    - 较小值(如 10): 优先使用物理内存，减少磁盘IO，适合机械硬盘或低性能云硬盘。\n    - 较大值(如 60): 积极将冷数据换出到Swap，腾出内存给Cache，适合高并发场景。"
CUR_SWAP=$(cat /proc/sys/vm/swappiness)
read -rp "设置 Swappiness (当前 $CUR_SWAP, 建议 10, 默认不修改): " NEW_SWAP

# 3. 执行 Swap 创建
echo "[*] 设定 $SWAPFILE -> $MIB MiB ($SIZE)"
if awk "NR>1{print \$1}" /proc/swaps 2>/dev/null | grep -qx "$SWAPFILE"; then 
    echo "[*] swapoff $SWAPFILE"
    swapoff "$SWAPFILE"
fi

echo "[*] 创建 $SWAPFILE ..."
rm -f "$SWAPFILE"
if ! fallocate -l "$((MIB*1024*1024))" "$SWAPFILE" 2>/dev/null; then 
    dd if=/dev/zero of="$SWAPFILE" bs=1M count="$MIB" status=progress
fi

chmod 600 "$SWAPFILE"
mkswap "$SWAPFILE" >/dev/null
swapon "$SWAPFILE"

# 4. 持久化配置
if ! grep -qE "^[^#]*[[:space:]]$SWAPFILE[[:space:]]" /etc/fstab 2>/dev/null; then 
    echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
fi

# 5. 处理 Swappiness 持久化
if [ -n "$NEW_SWAP" ]; then
    sysctl vm.swappiness="$NEW_SWAP"
    sed -i "/^vm.swappiness/d" /etc/sysctl.conf
    echo "vm.swappiness=$NEW_SWAP" >> /etc/sysctl.conf
    echo "[+] Swappiness 已设为 $NEW_SWAP 并持久化"
fi

echo "[+] 任务完成:"
free -h
