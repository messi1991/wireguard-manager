#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "[-] 请使用 root 权限运行此脚本 (sudo)"
  exit 1
fi

echo "[+] 正在更新系统并安装 WireGuard 及 qrencode..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard iptables qrencode curl git

# 兼容 `curl ... | bash` 一键安装：
# 这种模式下脚本自身的 stdin 就是管道，普通 read 会读走脚本后续内容，
# 因此交互必须从 /dev/tty 读取。
read_tty() {
  local __var="$1" __prompt="$2"
  if [ -r /dev/tty ]; then
    read -r -p "$__prompt" "$__var" < /dev/tty || true
  else
    eval "$__var="
  fi
}

DEFAULT_INTERFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)
if [ -z "$DEFAULT_INTERFACE" ]; then
  DEFAULT_INTERFACE="eth0"
  echo "[!] 未能自动检测到默认网卡，默认使用: eth0"
else
  echo "[+] 检测到默认网卡: $DEFAULT_INTERFACE"
fi

# 获取公网 IP：强制 IPv4、带超时，任一失败都不影响后续逻辑
PUBLIC_IP=""
for api in https://api.ipify.org https://ifconfig.me https://ipv4.icanhazip.com; do
  PUBLIC_IP=$(curl -4 -fsS --max-time 5 "$api" 2>/dev/null)
  [ -n "$PUBLIC_IP" ] && break
  PUBLIC_IP=""
done

read_tty INPUT_IP "确认你的服务器公网 IP [$PUBLIC_IP]: "
[ -n "$INPUT_IP" ] && PUBLIC_IP="$INPUT_IP"
if [ -z "$PUBLIC_IP" ]; then
  echo "[-] 未能获取公网 IP，请重新运行并手动输入正确的公网 IP。"
  exit 1
fi
echo "[+] 使用公网 IP: $PUBLIC_IP"

WG_DIR="/etc/wireguard"
mkdir -p "$WG_DIR/clients"
chmod 700 "$WG_DIR"

echo "[+] 开启系统内核 IP 转发..."
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wg.conf
sysctl --system >/dev/null 2>&1
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1

cd "$WG_DIR" || exit 1
if [ ! -f "server_private.key" ]; then
  wg genkey | tee server_private.key | wg pubkey > server_public.key
  chmod 600 server_private.key
fi
SERVER_PRIV_KEY=$(cat server_private.key)

# 若已存在 wg0.conf（重复执行安装），先备份并保留已有客户端 Peer，
# 避免重装/修复时把已添加的设备全部清空；同时清理没有 PublicKey 的非法 [Peer] 块。
PEERS_TMP=""
if [ -f "$WG_DIR/wg0.conf" ]; then
  BAK="$WG_DIR/wg0.conf.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$WG_DIR/wg0.conf" "$BAK"
  echo "[!] 检测到已存在的 wg0.conf，已备份到 $BAK"
  PEERS_TMP=$(mktemp)
  awk 'BEGIN{RS="";ORS="\n\n"} /\[Peer\]/ && /PublicKey/' "$WG_DIR/wg0.conf" > "$PEERS_TMP"
  if [ -s "$PEERS_TMP" ]; then
    echo "[+] 将保留已有的 $(grep -c '^\[Peer\]' "$PEERS_TMP") 个客户端 Peer。"
  fi
fi

# 说明（这是“能握手但上不了网”的关键）：
# 全局代理模式下，客户端 <-> 外网 的回程报文会命中 FORWARD 的 -o wg0 方向。
# 如果系统 FORWARD 默认策略是 DROP（安装 Docker / 启用 ufw 时很常见），
# 只写 `-i wg0 -j ACCEPT` 会导致回程被丢弃。
# 这里同时放行两个方向，并使用 -I 插到链首，避免被前面的 DROP 规则拦截。
cat > "$WG_DIR/wg0.conf" <<EOF
[Interface]
Address = 10.0.0.1/24
ListenPort = 51820
PrivateKey = $SERVER_PRIV_KEY
PostUp = iptables -C FORWARD -i %i -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i %i -j ACCEPT; iptables -C FORWARD -o %i -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -o %i -j ACCEPT; iptables -t nat -C POSTROUTING -o $DEFAULT_INTERFACE -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o $DEFAULT_INTERFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT 2>/dev/null || true; iptables -D FORWARD -o %i -j ACCEPT 2>/dev/null || true; iptables -t nat -D POSTROUTING -o $DEFAULT_INTERFACE -j MASQUERADE 2>/dev/null || true
EOF

# 回填保留的客户端 Peer
if [ -n "$PEERS_TMP" ] && [ -s "$PEERS_TMP" ]; then
  echo "" >> "$WG_DIR/wg0.conf"
  cat "$PEERS_TMP" >> "$WG_DIR/wg0.conf"
fi
[ -n "$PEERS_TMP" ] && rm -f "$PEERS_TMP"

chmod 600 "$WG_DIR/wg0.conf"

# 如果本机启用了 ufw，放行 WireGuard 端口，否则握手包会被 INPUT 链拦掉。
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 51820/udp >/dev/null 2>&1
  echo "[+] 检测到 ufw 已启用，已放行 51820/udp。"
fi

systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

echo "[+] 正在配置全局管理命令..."
REPO_URL="https://raw.githubusercontent.com/messi1991/wireguard-manager/main"

curl -fsSL "$REPO_URL/wg-add.sh" -o /usr/local/bin/wg-add
curl -fsSL "$REPO_URL/wg-list.sh" -o /usr/local/bin/wg-list
curl -fsSL "$REPO_URL/wg-remove.sh" -o /usr/local/bin/wg-remove
curl -fsSL "$REPO_URL/wg-doctor.sh" -o /usr/local/bin/wg-doctor
curl -fsSL "$REPO_URL/wg-uninstall.sh" -o /usr/local/bin/wg-uninstall

chmod +x /usr/local/bin/wg-add
chmod +x /usr/local/bin/wg-list
chmod +x /usr/local/bin/wg-remove
chmod +x /usr/local/bin/wg-doctor
chmod +x /usr/local/bin/wg-uninstall

echo "=================================================="
echo "[+] WireGuard 服务端安装与初始化成功！"
echo "[+] 服务端公网 IP: $PUBLIC_IP"
echo "[+] 监听端口: 51820 (UDP)"
echo "[+] 请确认云厂商安全组 / 防火墙已放行 51820/UDP"
echo "[+] 网络异常时运行 sudo wg-doctor 生成诊断日志"
echo "[+] 需要卸载时运行 sudo wg-uninstall"
echo "=================================================="
