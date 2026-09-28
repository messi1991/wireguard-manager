#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "[-] 请使用 root 权限运行此脚本"
  exit 1
fi

WG_DIR="/etc/wireguard"
CLIENT_DIR="$WG_DIR/clients"
WG_CONF="$WG_DIR/wg0.conf"

if [ -z "$1" ]; then
  read -p "请输入新客户端名称 (例如 iphone-pro, macbook-work): " CLIENT_NAME
else
  CLIENT_NAME="$1"
fi

if [ -z "$CLIENT_NAME" ]; then
  echo "[-] 客户端名称不能为空！"
  exit 1
fi

if [ -f "$CLIENT_DIR/$CLIENT_NAME.conf" ]; then
  echo "[-] 客户端 '$CLIENT_NAME' 已经存在！请使用不同的名称。"
  exit 1
fi

# 智能计算下一个可用 IP (10.0.0.2 ~ 10.0.0.254)
LAST_IP=$(grep -oE "10\.0\.0\.[0-9]+" "$WG_CONF" | tail -n 1 | awk -F. '{print $4}')
if [ -z "$LAST_IP" ]; then
  NEW_IP_NUM=2
else
  NEW_IP_NUM=$((LAST_IP + 1))
fi

if [ "$NEW_IP_NUM" -gt 254 ]; then
  echo "[-] IP 地址池已满 (10.0.0.2 - 10.0.0.254)"
  exit 1
fi

CLIENT_IP="10.0.0.$NEW_IP_NUM"
echo "[+] 为客户端 '$CLIENT_NAME' 分配内网 IP: $CLIENT_IP"

CLIENT_PRIV_KEY=$(wg genkey)
CLIENT_PUB_KEY=$(echo "$CLIENT_PRIV_KEY" | wg pubkey)
SERVER_PUB_KEY=$(cat "$WG_DIR/server_public.key")
PUBLIC_IP=$(curl -s https://api.ipify.org || curl -s ifconfig.me)

cat >> "$WG_CONF" <<EOF

[Peer]
# Name: $CLIENT_NAME
PublicKey = $CLIENT_PUB_KEY
AllowedIPs = $CLIENT_IP/32
EOF

wg syncconf wg0 <(wg-quick strip wg0)

CLIENT_CONF_PATH="$CLIENT_DIR/$CLIENT_NAME.conf"
cat > "$CLIENT_CONF_PATH" <<EOF
[Interface]
PrivateKey = $CLIENT_PRIV_KEY
Address = $CLIENT_IP/32
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = $SERVER_PUB_KEY
Endpoint = $PUBLIC_IP:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

echo "=================================================="
echo "[+] 客户端 '$CLIENT_NAME' 配置生成成功！"
echo "[+] 配置文件保存在: $CLIENT_CONF_PATH"
echo "--------------------------------------------------"
echo "手机端扫码连接 (WireGuard App)："
qrencode -t ansiutf8 < "$CLIENT_CONF_PATH"
echo "=================================================="