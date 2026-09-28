#!/bin/bash
if [ "$EUID" -ne 0 ]; then
  echo "[-] 请使用 root 权限运行此脚本"
  exit 1
fi

WG_DIR="/etc/wireguard"
WG_CONF="$WG_DIR/wg0.conf"
CLIENT_DIR="$WG_DIR/clients"

if [ -z "$1" ]; then
  read -p "请输入要精准删除的客户端名称: " CLIENT_NAME
else
  CLIENT_NAME="$1"
fi

if [ -z "$CLIENT_NAME" ]; then
  echo "[-] 客户端名称不能为空！"
  exit 1
fi

if [ ! -f "$CLIENT_DIR/$CLIENT_NAME.conf" ]; then
  echo "[-] 未找到名为 '$CLIENT_NAME' 的客户端，请先通过 wg-list 查看。"
  exit 1
fi

read -p "[!] 确认要彻底删除客户端 '$CLIENT_NAME' 吗？[y/N]: " CONFIRM
if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
  # 精准删除服务端 wg0.conf 中对应的 Peer 块（依据 # Name: 标识）
  sed -i "/# Name: $CLIENT_NAME/,+2d" "$WG_CONF"
  
  # 删除客户端配置文件
  rm -f "$CLIENT_DIR/$CLIENT_NAME.conf"
  
  # 热重载生效，即时断开该客户端连接
  wg syncconf wg0 <(wg-quick strip wg0)
  
  echo "[+] 客户端 '$CLIENT_NAME' 已被精准删除，相关权限已吊销。"
else
  echo "[+] 操作已取消。"
fi