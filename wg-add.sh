#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "[-] 请使用 root 权限运行此脚本"
  exit 1
fi

WG_DIR="/etc/wireguard"
CLIENT_DIR="$WG_DIR/clients"
WG_CONF="$WG_DIR/wg0.conf"
# 可通过环境变量覆盖 DNS，例如：WG_DNS="223.5.5.5, 119.29.29.29" sudo wg-add iphone
# 注意：中国大陆网络下 1.1.1.1 / 8.8.8.8 常被污染或不可达，会导致“能连上但打不开网页”。
DNS_SERVERS="${WG_DNS:-1.1.1.1, 8.8.8.8}"

if [ ! -f "$WG_CONF" ]; then
  echo "[-] 未找到 $WG_CONF，请先运行 install.sh 初始化服务端。"
  exit 1
fi

if [ -z "$1" ]; then
  if [ -r /dev/tty ]; then
    read -r -p "请输入新客户端名称 (例如 iphone-pro, macbook-work): " CLIENT_NAME < /dev/tty
  else
    CLIENT_NAME=""
  fi
else
  CLIENT_NAME="$1"
fi

if [ -z "$CLIENT_NAME" ]; then
  echo "[-] 客户端名称不能为空！"
  exit 1
fi

# 名称会被写入配置并用作文本匹配，限制字符集，避免匹配错误/路径穿越。
if ! echo "$CLIENT_NAME" | grep -qE '^[A-Za-z0-9_.-]+$'; then
  echo "[-] 客户端名称只能包含字母、数字、下划线(_)、点(.)和短横线(-)。"
  exit 1
fi

mkdir -p "$CLIENT_DIR"
if [ -f "$CLIENT_DIR/$CLIENT_NAME.conf" ]; then
  echo "[-] 客户端 '$CLIENT_NAME' 已经存在！请使用不同的名称。"
  exit 1
fi

# 收集所有已占用的地址，分配“最小的空闲 IP”（10.0.0.2 ~ 10.0.0.254）。
# 旧实现取“最后一个 IP + 1”，删除中间客户端后容易产生冲突。
USED_IPS=$(grep -oE "10\.0\.0\.[0-9]+" "$WG_CONF" | awk -F. '{print $4}' | sort -n | uniq)
NEW_IP_NUM=""
for i in $(seq 2 254); do
  if ! echo "$USED_IPS" | grep -qx "$i"; then
    NEW_IP_NUM="$i"
    break
  fi
done

if [ -z "$NEW_IP_NUM" ]; then
  echo "[-] IP 地址池已满 (10.0.0.2 - 10.0.0.254)"
  exit 1
fi

CLIENT_IP="10.0.0.$NEW_IP_NUM"
echo "[+] 为客户端 '$CLIENT_NAME' 分配内网 IP: $CLIENT_IP"

CLIENT_PRIV_KEY=$(wg genkey)
CLIENT_PUB_KEY=$(echo "$CLIENT_PRIV_KEY" | wg pubkey)
SERVER_PUB_KEY=$(cat "$WG_DIR/server_public.key")

PUBLIC_IP=""
for api in https://api.ipify.org https://ifconfig.me https://ipv4.icanhazip.com; do
  PUBLIC_IP=$(curl -4 -fsS --max-time 5 "$api" 2>/dev/null)
  [ -n "$PUBLIC_IP" ] && break
  PUBLIC_IP=""
done
if [ -z "$PUBLIC_IP" ] && [ -r /dev/tty ]; then
  read -r -p "未能自动获取公网 IP，请手动输入: " PUBLIC_IP < /dev/tty
fi
if [ -z "$PUBLIC_IP" ]; then
  echo "[-] 无法获取服务器公网 IP，客户端将无法连接。"
  exit 1
fi

cat >> "$WG_CONF" <<EOF

[Peer]
# Name: $CLIENT_NAME
PublicKey = $CLIENT_PUB_KEY
AllowedIPs = $CLIENT_IP/32
EOF

# 热重载：若配置非法 / wg0 未启动，必须显式报错，避免“以为加了其实没生效”。
if ! wg syncconf wg0 <(wg-quick strip wg0); then
  echo "[-] 重载 wg0 失败！请检查 $WG_CONF 是否合法、wg-quick@wg0 是否在运行。"
  echo "    systemctl status wg-quick@wg0"
  exit 1
fi

# 在 20000-60000 之间为客户端随机分配一个未被占用的端口
USED_PORTS=$(grep -oE "Endpoint = [^:]+:[0-9]+" "$CLIENT_DIR"/*.conf 2>/dev/null | awk -F: '{print $3}' || true)
CLIENT_PORT=""
for _ in {1..100}; do
  candidate=$((RANDOM % 40001 + 20000))
  if ! echo "$USED_PORTS" | grep -qx "$candidate"; then
    CLIENT_PORT="$candidate"
    break
  fi
done
[ -z "$CLIENT_PORT" ] && CLIENT_PORT=$((RANDOM % 40001 + 20000))

CLIENT_CONF_PATH="$CLIENT_DIR/$CLIENT_NAME.conf"
cat > "$CLIENT_CONF_PATH" <<EOF
[Interface]
PrivateKey = $CLIENT_PRIV_KEY
Address = $CLIENT_IP/32
DNS = $DNS_SERVERS

[Peer]
PublicKey = $SERVER_PUB_KEY
Endpoint = $PUBLIC_IP:$CLIENT_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
chmod 600 "$CLIENT_CONF_PATH"

echo "=================================================="
echo "[+] 客户端 '$CLIENT_NAME' 配置生成成功！"
echo "[+] 配置文件保存在: $CLIENT_CONF_PATH"
echo "[+] 内网 IP: $CLIENT_IP    Endpoint: $PUBLIC_IP:$CLIENT_PORT"
echo "--------------------------------------------------"
echo "手机端扫码连接 (WireGuard App)："
qrencode -t ansiutf8 < "$CLIENT_CONF_PATH"
echo "=================================================="
