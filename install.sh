#!/bin/bash
# ============================================================================
# install.sh —— WireGuard Manager 服务端一键安装 / 初始化
#
#   * 支持 `curl ... | bash`（交互统一从 /dev/tty 读取）
#   * 重复执行不会清空已有客户端：先备份 wg0.conf，只保留其中合法的 [Peer]
#   * 关键步骤全部做退出码检查，失败即中止（不再假装“安装成功”）
#
# 可选环境变量：
#   WG_PORT_MIN / WG_PORT_MAX  客户端随机端口范围，默认 20000 / 60000
#   WG_LISTEN_PORT             服务端实际监听端口，默认 51820
#   WG_REPO_URL                管理脚本仓库地址
# ============================================================================

set -uo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "[-] 请使用 root 权限运行此脚本 (sudo)"
  exit 1
fi

# ---------------------------------------------------------------------------
# 参数校验
# ---------------------------------------------------------------------------
is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

PORT_MIN="${WG_PORT_MIN:-20000}"
PORT_MAX="${WG_PORT_MAX:-60000}"
LISTEN_PORT="${WG_LISTEN_PORT:-51820}"

for v in PORT_MIN PORT_MAX LISTEN_PORT; do
  eval "val=\$$v"
  is_uint "$val" || { echo "[-] $v 必须是正整数，当前值: $val"; exit 1; }
done
if [ "$PORT_MIN" -lt 1 ] || [ "$PORT_MAX" -gt 65535 ] || [ "$PORT_MIN" -ge "$PORT_MAX" ]; then
  echo "[-] 端口范围非法: $PORT_MIN-$PORT_MAX（需 1 <= MIN < MAX <= 65535）"
  exit 1
fi
if [ "$LISTEN_PORT" -lt 1 ] || [ "$LISTEN_PORT" -gt 65535 ]; then
  echo "[-] WG_LISTEN_PORT 非法: $LISTEN_PORT（需 1-65535）"
  exit 1
fi
if [ "$LISTEN_PORT" -ge "$PORT_MIN" ] && [ "$LISTEN_PORT" -le "$PORT_MAX" ]; then
  # 注意：这不是致命问题 —— 客户端恰好抽到 LISTEN_PORT 时，DNAT 到自身等价于不转发，
  # 包依然会送达 wg0，因此这里只提示，不中断安装。
  echo "[i] 提示：监听端口 $LISTEN_PORT 落在客户端随机端口范围 $PORT_MIN-$PORT_MAX 内。"
  echo "    客户端抽到该端口时依然能正常连接（DNAT 到自身不改变目的地），无需处理。"
fi

echo "[+] 端口规划: 客户端随机端口 $PORT_MIN-$PORT_MAX/UDP -> 服务端监听 $LISTEN_PORT/UDP"

echo "[+] 正在更新系统并安装 WireGuard 及 qrencode..."
apt-get update || { echo "[-] apt-get update 失败，请检查网络/软件源。"; exit 1; }
if ! DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard iptables qrencode curl git; then
  echo "[-] 依赖安装失败（wireguard / iptables / qrencode / curl / git）。"
  exit 1
fi
for cmd in wg wg-quick ip iptables curl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "[-] 关键命令缺失: $cmd，安装中止。"; exit 1; }
done
command -v qrencode >/dev/null 2>&1 \
  || echo "[!] 未检测到 qrencode（二维码为可选功能），wg-add 仍可正常生成配置文件。"

# 兼容 `curl ... | bash` 一键安装：
# 这种模式下脚本自身的 stdin 就是管道，普通 read 会读走脚本后续内容，
# 因此交互必须从 /dev/tty 读取。
read_tty() {
  local __var="$1" __prompt="$2"
  # 先把目标变量置空：set -u 下 read 失败时若变量从未赋值，
  # 后续引用会直接报 “unbound variable”，看不到真正的错误信息。
  eval "$__var=\"\"" || true
  if [ -r /dev/tty ]; then
    read -r -p "$__prompt" "$__var" < /dev/tty 2>/dev/null || true
  fi
}

# 默认网卡名：不能用固定的 $5，因为 `default dev eth0 ...`（无 via 的点对点链路）
# 会把 proto/src 等字段取成网卡名，导致 MASQUERADE 规则写错 -> 客户端不能上网。
DEFAULT_INTERFACE=$(ip route show default 2>/dev/null | awk '
  /default/ {
    for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }
  }' | head -n1)
if [ -z "$DEFAULT_INTERFACE" ]; then
  DEFAULT_INTERFACE="eth0"
  echo "[!] 未能自动检测到默认网卡，默认使用: eth0"
else
  echo "[+] 检测到默认网卡: $DEFAULT_INTERFACE"
fi

# 获取公网 IP：强制 IPv4、带超时，任一失败都不影响后续逻辑
PUBLIC_IP=""
for api in https://api.ipify.org https://ifconfig.me https://ipv4.icanhazip.com; do
  PUBLIC_IP=$(curl -4 -fsS --max-time 5 "$api" 2>/dev/null) && [ -n "$PUBLIC_IP" ] && break
  PUBLIC_IP=""
done

read_tty INPUT_IP "确认你的服务器公网 IP [$PUBLIC_IP]: "
[ -n "${INPUT_IP:-}" ] && PUBLIC_IP="$INPUT_IP"
if [ -z "$PUBLIC_IP" ]; then
  echo "[-] 未能获取公网 IP，请重新运行并手动输入正确的公网 IP。"
  exit 1
fi
echo "[+] 使用公网 IP: $PUBLIC_IP"

WG_DIR="/etc/wireguard"
mkdir -p "$WG_DIR/clients"
chmod 700 "$WG_DIR"

# 记录端口规划与默认网卡，供 wg-add / wg-doctor / wg-uninstall 统一读取，
# 避免端口范围、网卡名在多个脚本里各写一份而产生不一致。
# 改端口前先比对旧值：已存在的客户端配置里写死了当时的端口，
# 改了范围它们会全部连不上，必须显式告警。
OLD_PORT_MIN=""; OLD_PORT_MAX=""; OLD_LISTEN_PORT=""
if [ -r "$WG_DIR/.port_range" ]; then
  OLD_PORT_MIN=$(awk -F= '$1=="PORT_MIN"{print $2}' "$WG_DIR/.port_range")
  OLD_PORT_MAX=$(awk -F= '$1=="PORT_MAX"{print $2}' "$WG_DIR/.port_range")
  OLD_LISTEN_PORT=$(awk -F= '$1=="LISTEN_PORT"{print $2}' "$WG_DIR/.port_range")
fi

printf 'PORT_MIN=%s\nPORT_MAX=%s\nLISTEN_PORT=%s\n' "$PORT_MIN" "$PORT_MAX" "$LISTEN_PORT" \
  > "$WG_DIR/.port_range"
chmod 600 "$WG_DIR/.port_range"
printf '%s\n' "$DEFAULT_INTERFACE" > "$WG_DIR/.default_if"
chmod 600 "$WG_DIR/.default_if"

# 端口变更告警：列出哪些已生成配置的 Endpoint 端口会失效
if [ -n "$OLD_PORT_MIN" ] && { [ "$OLD_PORT_MIN" != "$PORT_MIN" ] || [ "$OLD_PORT_MAX" != "$PORT_MAX" ] || [ "$OLD_LISTEN_PORT" != "$LISTEN_PORT" ]; }; then
  AFFECTED=""
  if [ -d "$WG_DIR/clients" ]; then
    for c in "$WG_DIR"/clients/*.conf; do
      [ -f "$c" ] || continue
      ep=$(awk '/^[[:space:]]*Endpoint/{print $3; exit}' "$c")
      [ -n "$ep" ] && AFFECTED="$AFFECTED\n    $(basename "$c"): $ep"
    done
  fi
  if [ -n "$AFFECTED" ]; then
    echo "[!] 警告：端口规划已变更（原 $OLD_PORT_MIN-$OLD_PORT_MAX -> $LISTEN_PORT，现 $PORT_MIN-$PORT_MAX -> $LISTEN_PORT）"
    printf "[!] 以下客户端配置的 Endpoint 端口将无法连接，需要删除后重新 wg-add：%b\n" "$AFFECTED"
  else
    echo "[i] 端口规划已变更（原 $OLD_PORT_MIN-$OLD_PORT_MAX/$OLD_LISTEN_PORT）。"
  fi
fi

echo "[+] 开启系统内核 IP 转发..."
cat > /etc/sysctl.d/99-wg.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.forwarding=1
EOF
sysctl --system >/dev/null 2>&1
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
sysctl -w net.ipv4.conf.all.forwarding=1 >/dev/null 2>&1

cd "$WG_DIR" || exit 1

# 服务端密钥：必须同时校验公钥可生成，否则说明 wg 工具异常
if [ ! -s "server_private.key" ] || [ ! -s "server_public.key" ]; then
  rm -f server_private.key server_public.key
  if ! wg genkey > server_private.key || [ ! -s server_private.key ]; then
    echo "[-] 生成服务端私钥失败，请确认 wireguard 已正确安装。"
    exit 1
  fi
  if ! wg pubkey < server_private.key > server_public.key || [ ! -s server_public.key ]; then
    echo "[-] 生成服务端公钥失败，请确认 wireguard 已正确安装。"
    exit 1
  fi
  chmod 600 server_private.key server_public.key
fi
SERVER_PRIV_KEY=$(cat server_private.key)

# 若已存在 wg0.conf（重复执行安装），先备份并保留已有客户端 Peer，
# 避免重装/修复时把已添加的设备全部清空。
#
# 注意：这里不能用 `awk 'BEGIN{RS=""}'` 的段落模式 —— 一旦原配置块之间
# 没有空行，整个文件会被当成一个段落匹配，导致 [Interface] 被一起保留并
# 追加到新文件后面，产生重复 [Interface] 段，wg-quick 直接启动失败。
# 下面改为逐段（以 [xxx] 行开头）扫描，只输出“含 PublicKey”的 [Peer] 块。
PEERS_TMP=""
PEER_COUNT=0
if [ -f "$WG_DIR/wg0.conf" ]; then
  BAK="$WG_DIR/wg0.conf.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$WG_DIR/wg0.conf" "$BAK" || { echo "[-] 备份 $WG_DIR/wg0.conf 失败，安装中止。"; exit 1; }
  echo "[!] 检测到已存在的 wg0.conf，已备份到 $BAK"

  ORIG_PEER_TOTAL=$(grep -c '^[[:space:]]*\[Peer\]' "$WG_DIR/wg0.conf" 2>/dev/null || true)
  ORIG_PEER_TOTAL=${ORIG_PEER_TOTAL:-0}

  if ! PEERS_TMP=$(mktemp); then
    echo "[-] 创建临时文件失败，安装中止（未修改 wg0.conf）。"
    exit 1
  fi
  # awk 必须成功；提取到的合法 Peer 数必须与原始数一致，否则一律中止，
  # 绝不允许出现“悄悄清空全部客户端”的情况。
  if ! awk '
    function flush() {
      if (inpeer && haspub) printf "%s", buf
      buf = ""; inpeer = 0; haspub = 0
    }
    { sub(/\r$/, "") }
    /^[ \t]*\[/ {
      # 先结算上一个段落，再决定当前行是新 Peer 的开头还是普通节
      flush()
      if ($0 ~ /^[ \t]*\[Peer\]/) { inpeer = 1; haspub = 0; buf = $0 ORS; next }
      next
    }
    {
      if (inpeer) {
        buf = buf $0 ORS
        if ($0 ~ /^[ \t]*PublicKey[ \t]*=/) haspub = 1
      }
    }
    END { flush() }
  ' "$WG_DIR/wg0.conf" > "$PEERS_TMP"; then
    rm -f "$PEERS_TMP"
    echo "[-] 解析原 wg0.conf 失败，安装中止（未修改 wg0.conf）。"
    exit 1
  fi

  PEER_COUNT=$(grep -c '^[[:space:]]*\[Peer\]' "$PEERS_TMP" 2>/dev/null || true)
  PEER_COUNT=${PEER_COUNT:-0}

  if [ "$PEER_COUNT" -ne "$ORIG_PEER_TOTAL" ]; then
    rm -f "$PEERS_TMP"; PEERS_TMP=""
    echo "[-] 安全中止：原 wg0.conf 有 $ORIG_PEER_TOTAL 个 [Peer]，但只识别到 $PEER_COUNT 个可保留的合法 Peer。"
    echo "    为避免误删客户端，本次未做任何修改。备份: $BAK"
    echo "    请人工检查该文件后重新运行。"
    exit 1
  fi

  if [ "$PEER_COUNT" -gt 0 ]; then
    echo "[+] 将保留已有的 $PEER_COUNT 个客户端 Peer。"
  else
    rm -f "$PEERS_TMP"; PEERS_TMP=""
  fi
fi

# PostUp / PostDown 的全部规则逻辑放进独立脚本 /etc/wireguard/nat.sh：
#   1. 默认网卡在开机时动态探测，避免网卡名变化导致 MASQUERADE/DNAT 失效
#   2. up / down 完全对称，避免“加了没删”造成规则残留
#   3. 端口范围只在生成时写死一份，避免 PostUp 与 wg-add 各写一套而脱钩
NAT_HELPER="$WG_DIR/nat.sh"
cat > "$NAT_HELPER" <<EOF
#!/bin/bash
# 由 install.sh 生成，请勿手改端口（改后重跑 install.sh 即可）
set -u
ACTION="\${1:?用法: nat.sh up|down <接口>}"
IF="\${2:?用法: nat.sh up|down <接口>}"
PORT_MIN=$PORT_MIN
PORT_MAX=$PORT_MAX
LISTEN_PORT=$LISTEN_PORT
DEF_IF=\$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if(\$i=="dev"){print \$(i+1); exit}}' | head -n1)

# 同一规则可能被重复添加，删除时循环直到不存在
del_filter()  { while iptables -C "\$@" 2>/dev/null; do iptables -D "\$@" 2>/dev/null || break; done; }
del_nat()     { while iptables -t nat -C "\$@" 2>/dev/null; do iptables -t nat -D "\$@" 2>/dev/null || break; done; }

case "\$ACTION" in
  up)
    iptables -C FORWARD -i "\$IF" -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i "\$IF" -j ACCEPT
    iptables -C FORWARD -o "\$IF" -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -o "\$IF" -j ACCEPT
    if [ -n "\$DEF_IF" ]; then
      iptables -t nat -C POSTROUTING -o "\$DEF_IF" -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A POSTROUTING -o "\$DEF_IF" -j MASQUERADE
    fi
    iptables -t nat -C PREROUTING -p udp --dport "\$PORT_MIN:\$PORT_MAX" -j DNAT --to-destination ":\$LISTEN_PORT" 2>/dev/null \
      || iptables -t nat -A PREROUTING -p udp --dport "\$PORT_MIN:\$PORT_MAX" -j DNAT --to-destination ":\$LISTEN_PORT"
    ;;
  down)
    del_filter FORWARD -i "\$IF" -j ACCEPT
    del_filter FORWARD -o "\$IF" -j ACCEPT
    [ -n "\$DEF_IF" ] && del_nat POSTROUTING -o "\$DEF_IF" -j MASQUERADE
    del_nat PREROUTING -p udp --dport "\$PORT_MIN:\$PORT_MAX" -j DNAT --to-destination ":\$LISTEN_PORT"
    ;;
  *)
    echo "用法: nat.sh up|down <接口>" >&2
    exit 1
    ;;
esac
exit 0
EOF
chmod 700 "$NAT_HELPER"

# 说明（这是“能握手但上不了网”的关键）：
# 全局代理模式下，客户端 <-> 外网 的回程报文会命中 FORWARD 的 -o wg0 方向。
# 如果系统 FORWARD 默认策略是 DROP（安装 Docker / 启用 ufw 时很常见），
# 只写 `-i wg0 -j ACCEPT` 会导致回程被丢弃。
# 因此 nat.sh up 会同时放行两个方向，并使用 -I 插到链首，避免被前面的 DROP 规则拦截。
{
  echo "[Interface]"
  echo "Address = 10.0.0.1/24"
  echo "ListenPort = $LISTEN_PORT"
  echo "PrivateKey = $SERVER_PRIV_KEY"
  echo "PostUp = $NAT_HELPER up %i"
  echo "PostDown = $NAT_HELPER down %i"
  echo ""
  # 回填保留的客户端 Peer（仅在确实存在时才写）
  if [ -n "$PEERS_TMP" ] && [ -s "$PEERS_TMP" ]; then
    cat "$PEERS_TMP"
    echo ""
  fi
} > "$WG_DIR/wg0.conf.new"

# 原子替换后立刻用 wg-quick strip 校验新配置；失败则回滚到备份（或删除残缺文件），
# 避免写坏配置导致 wg-quick 无法启动。
mv "$WG_DIR/wg0.conf.new" "$WG_DIR/wg0.conf"
chmod 600 "$WG_DIR/wg0.conf"
[ -n "$PEERS_TMP" ] && rm -f "$PEERS_TMP"

if ! wg-quick strip wg0 >/dev/null 2>&1; then
  echo "[-] 新生成的 wg0.conf 校验失败，已回滚。"
  if [ -n "${BAK:-}" ] && [ -f "$BAK" ]; then
    cp "$BAK" "$WG_DIR/wg0.conf"
    chmod 600 "$WG_DIR/wg0.conf"
    echo "    已恢复备份: $BAK"
  else
    rm -f "$WG_DIR/wg0.conf"
    echo "    已删除不合法的配置文件，请检查: $WG_DIR/wg0.conf"
  fi
  exit 1
fi

# 如果本机启用了 ufw，放行 WireGuard 端口范围，否则握手包会被 INPUT 链拦掉。
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "$PORT_MIN:$PORT_MAX/udp" >/dev/null 2>&1
  echo "[+] 检测到 ufw 已启用，已放行 $PORT_MIN:$PORT_MAX/udp。"
fi

if ! systemctl enable wg-quick@wg0 >/dev/null 2>&1; then
  echo "[!] 设置 wg-quick@wg0 开机自启失败，可稍后手动执行: systemctl enable wg-quick@wg0"
fi
if ! systemctl restart wg-quick@wg0; then
  echo "[-] wg-quick@wg0 启动失败！"
  echo "    请运行: sudo wg-doctor    或    sudo journalctl -u wg-quick@wg0 -n 50"
  exit 1
fi

echo "[+] 正在配置全局管理命令..."
REPO_URL="${WG_REPO_URL:-https://raw.githubusercontent.com/messi1991/wireguard-manager/main}"
INSTALL_FAILED=0
for f in wg-add wg-list wg-remove wg-doctor wg-uninstall; do
  if curl -fsSL --max-time 30 "$REPO_URL/$f.sh" -o "/usr/local/bin/$f" \
     && [ -s "/usr/local/bin/$f" ]; then
    chmod +x "/usr/local/bin/$f"
  else
    rm -f "/usr/local/bin/$f"
    echo "[-] 下载 $f.sh 失败（请检查网络或仓库地址）。"
    INSTALL_FAILED=1
  fi
done
if [ "$INSTALL_FAILED" -ne 0 ]; then
  echo "[-] 部分全局命令安装失败，服务端已可用，可从仓库手动补齐: $REPO_URL"
  exit 1
fi

echo "=================================================="
echo "[+] WireGuard 服务端安装与初始化成功！"
echo "[+] 服务端公网 IP: $PUBLIC_IP"
echo "[+] 默认出口网卡: $DEFAULT_INTERFACE（PostUp 会动态探测）"
echo "[+] 监听端口: $LISTEN_PORT/UDP（客户端使用 $PORT_MIN-$PORT_MAX 随机端口，经 DNAT 转发）"
echo "[+] 请确认云厂商安全组 / 防火墙已放行 $PORT_MIN:$PORT_MAX/UDP"
echo "[+] 网络异常时运行 sudo wg-doctor 生成诊断日志"
echo "[+] 需要卸载时运行 sudo wg-uninstall"
echo "=================================================="