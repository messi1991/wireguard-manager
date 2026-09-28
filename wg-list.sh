#!/bin/bash
if [ "$EUID" -ne 0 ]; then
  echo "[-] 请使用 root 权限运行此脚本"
  exit 1
fi

echo "=================================================="
echo "          已注册的 WireGuard 客户端列表           "
echo "=================================================="
if [ -d "/etc/wireguard/clients" ] && [ "$(ls -A /etc/wireguard/clients)" ]; then
  for conf in /etc/wireguard/clients/*.conf; do
    name=$(basename "$conf" .conf)
    ip=$(grep "Address" "$conf" | awk '{print $3}')
    echo "- 客户端名: $name | 内网IP: $ip"
  done
else
  echo "当前暂无任何客户端配置。"
fi
echo "=================================================="