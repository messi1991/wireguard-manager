#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "[-] 请使用 root 权限运行此脚本 (sudo)"
  exit 1
fi

echo "[+] 正在更新系统并安装 WireGuard 及 qrencode..."
apt-get update
apt-get install -y wireguard iptables qrencode curl git

DEFAULT_INTERFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)
if [ -z "$DEFAULT_INTERFACE" ]; then
  DEFAULT_INTERFACE="eth0"
  echo "[!] 未能自动检测到默认网卡，默认使用: eth0"
else
  echo "[+] 检测到默认网卡: $DEFAULT_INTERFACE"
fi

PUBLIC_IP=$(curl -s https://api.ipify.org || curl -s ifconfig.me)
read -p "确认你的服务器公网 IP [$PUBLIC_IP]: " INPUT_IP
[ -n "$INPUT_IP" ] && PUBLIC_IP="$INPUT_IP"

WG_DIR="/etc/wireguard"
mkdir -p "$WG_DIR/clients"
chmod 700 "$WG_DIR"

echo "[+] 开启系统内核 IP 转发..."
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/wg.conf
sysctl --system

cd "$WG_DIR"
if [ ! -f "server_private.key" ]; then
  wg genkey | tee server_private.key | wg pubkey > server_public.key
  chmod 600 server_private.key
fi
SERVER_PRIV_KEY=$(cat server_private.key)
SERVER_PUB_KEY=$(cat server_public.key)

cat > "$WG_DIR/wg0.conf" <<EOF
[Interface]
Address = 10.0.0.1/24
ListenPort = 51820
PrivateKey = $SERVER_PRIV_KEY
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $DEFAULT_INTERFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $DEFAULT_INTERFACE -j MASQUERADE
EOF

chmod 600 "$WG_DIR/wg0.conf"

systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

echo "[+] 正在配置全局管理命令..."
REPO_URL="https://raw.githubusercontent.com/messi1991/wireguard-manager/main"

curl -sSL "$REPO_URL/wg-add.sh" -o /usr/local/bin/wg-add
curl -sSL "$REPO_URL/wg-list.sh" -o /usr/local/bin/wg-list
curl -sSL "$REPO_URL/wg-remove.sh" -o /usr/local/bin/wg-remove

chmod +x /usr/local/bin/wg-add
chmod +x /usr/local/bin/wg-list
chmod +x /usr/local/bin/wg-remove

echo "=================================================="
echo "[+] WireGuard 服务端安装与初始化成功！"
echo "[+] 服务端公网 IP: $PUBLIC_IP"
echo "[+] 监听端口: 51820"
echo "=================================================="