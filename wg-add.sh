#!/bin/bash
# ============================================================================
# wg-add —— 添加一个 WireGuard 客户端
# ============================================================================

set -uo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "[-] 请使用 root 权限运行此脚本"
  exit 1
fi

WG_DIR="/etc/wireguard"
CLIENT_DIR="$WG_DIR/clients"
WG_CONF="$WG_DIR/wg0.conf"
WG_IF="${WG_IF:-wg0}"
# 可通过环境变量覆盖 DNS，例如：WG_DNS="223.5.5.5, 119.29.29.29" sudo wg-add iphone
# 默认使用国内 DNS：1.1.1.1 / 8.8.8.8 在中国大陆常被污染或不可达，
# 会导致“能连上但打不开网页”。
DNS_SERVERS="${WG_DNS:-223.5.5.5, 119.29.29.29}"

# 端口规划统一从 install.sh 写入的 /etc/wireguard/.port_range 读取，
# 保证与 nat.sh 里的 DNAT 规则范围永远一致（不匹配会导致客户端连不上）。
SRV_PORT_MIN=20000; SRV_PORT_MAX=60000; SRV_LISTEN_PORT=51820
if [ -r "$WG_DIR/.port_range" ]; then
  # shellcheck disable=SC1090
  . "$WG_DIR/.port_range"
fi
PORT_MIN="${SRV_PORT_MIN:-20000}"
PORT_MAX="${SRV_PORT_MAX:-60000}"

is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
if ! is_uint "$PORT_MIN" || ! is_uint "$PORT_MAX" \
   || [ "$PORT_MIN" -lt 1 ] || [ "$PORT_MAX" -gt 65535 ] || [ "$PORT_MIN" -ge "$PORT_MAX" ]; then
  echo "[-] /etc/wireguard/.port_range 中的端口范围非法，请重跑 install.sh 修复。"
  exit 1
fi

if [ ! -f "$WG_CONF" ]; then
  echo "[-] 未找到 $WG_CONF，请先运行 install.sh 初始化服务端。"
  exit 1
fi
if [ ! -s "$WG_DIR/server_public.key" ]; then
  echo "[-] 未找到服务端公钥 $WG_DIR/server_public.key，请先运行 install.sh。"
  exit 1
fi

if [ -z "${1:-}" ]; then
  CLIENT_NAME=""
  if [ -r /dev/tty ]; then
    read -r -p "请输入新客户端名称 (例如 iphone-pro, macbook-work): " CLIENT_NAME < /dev/tty 2>/dev/null || true
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
USED_IPS=$(grep -oE "10\.0\.0\.[0-9]+" "$WG_CONF" | awk -F. '{print $4}' | sort -n | uniq || true)
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

CLIENT_PRIV_KEY=$(wg genkey) || { echo "[-] 生成客户端私钥失败。"; exit 1; }
CLIENT_PUB_KEY=$(echo "$CLIENT_PRIV_KEY" | wg pubkey) || { echo "[-] 生成客户端公钥失败。"; exit 1; }
SERVER_PUB_KEY=$(cat "$WG_DIR/server_public.key")

PUBLIC_IP=""
for api in https://api.ipify.org https://ifconfig.me https://ipv4.icanhazip.com; do
  PUBLIC_IP=$(curl -4 -fsS --max-time 5 "$api" 2>/dev/null) && [ -n "$PUBLIC_IP" ] && break
  PUBLIC_IP=""
done
if [ -z "$PUBLIC_IP" ] && [ -r /dev/tty ]; then
  read -r -p "未能自动获取公网 IP，请手动输入: " PUBLIC_IP < /dev/tty 2>/dev/null || true
fi
if [ -z "$PUBLIC_IP" ]; then
  echo "[-] 无法获取服务器公网 IP，客户端将无法连接。"
  exit 1
fi

# 在服务端 DNAT 覆盖的端口范围内随机取一个未被占用的端口
USED_PORTS=$(grep -ohE "^[[:space:]]*Endpoint[[:space:]]*=[[:space:]]*[^ ]*:[0-9]+" \
  "$CLIENT_DIR"/*.conf 2>/dev/null | grep -oE '[0-9]+$' || true)
PORT_RANGE=$((PORT_MAX - PORT_MIN + 1))
CLIENT_PORT=""
for _ in $(seq 1 500); do
  candidate=$((RANDOM % PORT_RANGE + PORT_MIN))
  if ! echo "$USED_PORTS" | grep -qx "$candidate"; then
    CLIENT_PORT="$candidate"
    break
  fi
done
if [ -z "$CLIENT_PORT" ]; then
  # 不再静默随机兜底（可能撞端口），直接报错退出
  echo "[-] 端口池已满 ($PORT_MIN-$PORT_MAX)，无法为客户端分配端口。"
  exit 1
fi

# 先写客户端配置到临时文件，最后再统一提交，避免中途失败留下半成品
CLIENT_CONF_PATH="$CLIENT_DIR/$CLIENT_NAME.conf"
CLIENT_CONF_TMP=$(mktemp)
CONF_BAK=$(mktemp)
trap 'rm -f "$CLIENT_CONF_TMP" "$CONF_BAK"' EXIT

cat > "$CLIENT_CONF_TMP" <<EOF
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

# 追加 Peer 之前先做完整文件级备份。
# 不能用 `head -n $(wc -l)` 截断的方式回滚：wg0.conf 若结尾没有换行符，
# wc -l 会少算一行，回滚时会把最后一行整行丢掉（等于顺手弄坏了 Interface 段）。
cp "$WG_CONF" "$CONF_BAK" || { echo "[-] 备份 $WG_CONF 失败，操作中止。"; exit 1; }

cat >> "$WG_CONF" <<EOF

[Peer]
# Name: $CLIENT_NAME
PublicKey = $CLIENT_PUB_KEY
AllowedIPs = $CLIENT_IP/32
EOF

rollback() {
  if cp "$CONF_BAK" "$WG_CONF"; then
    chmod 600 "$WG_CONF"
    echo "[!] 已回滚本次对 $WG_CONF 的修改（恢复到添加前的完整内容）。"
  else
    echo "[!] 回滚失败！请手动用备份恢复: $CONF_BAK"
  fi
}

# 热重载：若配置非法 / wg0 未启动，必须显式报错并回滚，
# 否则 wg0.conf 里会残留一个没有客户端配置的“孤儿 Peer”并永久占用该 IP。
if ! wg-quick strip "$WG_IF" >/dev/null 2>&1; then
  echo "[-] $WG_CONF 语法非法（可能是历史脏数据），已中止添加。"
  rollback
  echo "    请检查: $WG_CONF   或运行 sudo wg-doctor"
  exit 1
fi

if ! wg syncconf "$WG_IF" <(wg-quick strip "$WG_IF"); then
  echo "[-] 重载 $WG_IF 失败！请检查 wg-quick@$WG_IF 是否在运行。"
  rollback
  echo "    systemctl status wg-quick@$WG_IF"
  exit 1
fi

# 重载成功后再落盘客户端配置
mv "$CLIENT_CONF_TMP" "$CLIENT_CONF_PATH"
chmod 600 "$CLIENT_CONF_PATH"

echo "=================================================="
echo "[+] 客户端 '$CLIENT_NAME' 配置生成成功！"
echo "[+] 配置文件保存在: $CLIENT_CONF_PATH"
echo "[+] 内网 IP: $CLIENT_IP    Endpoint: $PUBLIC_IP:$CLIENT_PORT"
echo "--------------------------------------------------"
if command -v qrencode >/dev/null 2>&1; then
  echo "手机端扫码连接 (WireGuard App)："
  qrencode -t ansiutf8 < "$CLIENT_CONF_PATH"
else
  echo "[!] 未安装 qrencode，无法显示二维码（不影响配置已生效）。"
  echo "    安装后重跑 wg-add 或直接查看配置: cat $CLIENT_CONF_PATH"
  echo "    电脑端可直接导入该文件；macOS 命令行接入见 README 的 macOS 章节。"
fi
echo "=================================================="