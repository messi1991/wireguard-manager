#!/bin/bash
# ============================================================================
# wg-doctor —— WireGuard 只读诊断脚本
#
#   * 不修改任何配置/规则，只收集并打印排查所需的全部信息
#   * 自动对私钥、预共享密钥脱敏
#   * 结果同步保存到 /tmp/wg-doctor-<时间戳>.log，方便整体复制发给我
#
# 用法：
#   sudo wg-doctor              # 常规诊断
#   sudo wg-doctor --capture    # 额外抓取 8 秒 51820/UDP 握手包（需 tcpdump）
# ============================================================================

WG_IF="${WG_IF:-wg0}"
WG_DIR="/etc/wireguard"
WG_CONF="$WG_DIR/$WG_IF.conf"
CLIENT_DIR="$WG_DIR/clients"
WG_PORT="${WG_PORT:-51820}"
CAPTURE=0
[ "$1" = "--capture" ] && CAPTURE=1

if [ "$EUID" -ne 0 ]; then
  echo "[-] 请使用 root 权限运行: sudo wg-doctor"
  exit 1
fi

LOG="/tmp/wg-doctor-$(date +%Y%m%d-%H%M%S).log"
# 所有输出同时写入日志文件
exec > >(tee -a "$LOG") 2>&1

# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------
section() {
  echo
  echo "############################################################################"
  echo "## $*"
  echo "############################################################################"
}
run() { echo "\$ $*"; eval "$*" 2>&1 || echo "  [命令执行失败, exit=$?]"; }
mask() { sed -E 's/^(PrivateKey|PresharedKey)[[:space:]]*=.*/\1 = <已脱敏>/'; }
has() { command -v "$1" >/dev/null 2>&1; }

# 用于最后汇总
declare -a PROBLEMS=()
declare -a GOOD=()
problem() { PROBLEMS+=("$1"); }
good()    { GOOD+=("$1"); }

echo "WireGuard Doctor 诊断报告"
echo "生成时间 : $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "日志文件 : $LOG"
echo "接口     : $WG_IF     端口: ${WG_PORT}/UDP"

# ---------------------------------------------------------------------------
section "1. 系统与内核"
run "uname -a"
run "cat /etc/os-release 2>/dev/null | grep -E '^(PRETTY_NAME|VERSION)='"
run "uptime"
has wg && run "wg --version" || echo "  [x] 未找到 wg 命令，WireGuard 可能未安装"
run "lsmod | grep -i wireguard || echo '  [!] wireguard 内核模块未加载'"
has modinfo && run "modinfo wireguard 2>/dev/null | grep -E '^(version|filename)'"

# ---------------------------------------------------------------------------
section "2. WireGuard 服务状态"
run "systemctl is-enabled wg-quick@$WG_IF 2>&1"
run "systemctl is-active wg-quick@$WG_IF 2>&1"
run "systemctl status wg-quick@$WG_IF --no-pager -l 2>&1 | head -n 30"
if [ "$(systemctl is-active wg-quick@$WG_IF 2>/dev/null)" != "active" ]; then
  problem "wg-quick@$WG_IF 未运行（服务未启动或启动失败）"
else
  good "wg-quick@$WG_IF 正在运行"
fi

# ---------------------------------------------------------------------------
section "3. 网络接口 / 地址"
run "ip -br addr show $WG_IF 2>&1 || echo '  [!] 接口 $WG_IF 不存在'"
run "ip link show $WG_IF 2>&1"
if ip link show "$WG_IF" >/dev/null 2>&1; then
  good "接口 $WG_IF 存在"
else
  problem "接口 $WG_IF 不存在（wg-quick 未成功创建）"
fi

# ---------------------------------------------------------------------------
section "4. WireGuard 实时状态与握手"
run "wg show 2>&1"
run "wg show $WG_IF dump 2>&1 | awk -F'\\t' 'NR==1{print \"[服务端] listen_port=\" \$3} NR>1{print \"[Peer] pub=\" substr(\$1,1,12)\"... endpoint=\" \$3 \" allowed_ips=\" \$4 \" latest_handshake=\" \$5 \" rx=\" \$6 \" tx=\" \$7}'"
# 统计是否有握手
if has wg && wg show "$WG_IF" >/dev/null 2>&1; then
  HANDSHAKES=$(wg show "$WG_IF" latest-handshakes 2>/dev/null | awk '$2>0{c++} END{print c+0}')
  PEERS=$(wg show "$WG_IF" peers 2>/dev/null | wc -l | tr -d ' ')
  echo
  echo "  Peer 总数: ${PEERS:-0}    有过握手的 Peer 数: ${HANDSHAKES:-0}"
  if [ "${HANDSHAKES:-0}" -eq 0 ]; then
    problem "没有任何客户端完成过握手（连接层不通）：优先检查云安全组/防火墙是否放行 ${WG_PORT}/UDP、Endpoint 公网 IP 是否正确"
  else
    good "已有客户端成功握手，隧道密钥交换正常"
  fi
fi

# ---------------------------------------------------------------------------
section "5. 服务端配置 wg0.conf（已脱敏）"
if [ -f "$WG_CONF" ]; then
  run "ls -l $WG_CONF"
  echo "---------------- wg0.conf (脱敏) ----------------"
  mask < "$WG_CONF"
  echo "------------------------------------------------"
  # 检查是否有非法空 Peer（无 PublicKey）
  if mask < "$WG_CONF" | awk 'BEGIN{RS="";ORS="\n\n"} /\[Peer\]/ && !/PublicKey/' | grep -q '\[Peer\]'; then
    problem "wg0.conf 中存在没有 PublicKey 的非法 [Peer] 块，会导致 wg-quick 启动失败"
  fi
else
  problem "未找到配置文件 $WG_CONF"
fi

# ---------------------------------------------------------------------------
section "6. 客户端配置清单（已脱敏）"
if [ -d "$CLIENT_DIR" ] && [ -n "$(ls -A "$CLIENT_DIR" 2>/dev/null)" ]; then
  run "ls -l $CLIENT_DIR"
  for c in "$CLIENT_DIR"/*.conf; do
    [ -f "$c" ] || continue
    echo "---------------- $(basename "$c") (脱敏) ----------------"
    mask < "$c"
  done
else
  echo "  [!] $CLIENT_DIR 为空或不存在（还没有添加任何客户端）"
fi

# ---------------------------------------------------------------------------
section "7. 路由表"
run "ip route show"
run "ip route show default"
run "ip route show table all 2>/dev/null | grep -E \"$WG_IF|10\\.0\\.0\\.\" || echo '  [!] 未看到与 wg 相关的路由'"

# ---------------------------------------------------------------------------
section "8. 内核 IP 转发"
run "sysctl net.ipv4.ip_forward"
run "sysctl net.ipv4.conf.all.rp_filter 2>/dev/null"
run "cat /etc/sysctl.d/99-wg.conf 2>/dev/null || echo '  未找到 /etc/sysctl.d/99-wg.conf'"
if [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = "1" ]; then
  good "内核 IP 转发已开启"
else
  problem "内核 IP 转发未开启（net.ipv4.ip_forward != 1），客户端无法访问外网"
fi

# ---------------------------------------------------------------------------
section "9. iptables 规则（FORWARD / NAT 是关键）"
run "iptables -S 2>&1"
run "iptables -t nat -S 2>&1"
run "iptables -L FORWARD -n -v 2>&1"
run "iptables -t nat -L POSTROUTING -n -v 2>&1"

DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
echo
echo "  默认出口网卡: ${DEFAULT_IF:-未检测到}"
if iptables -C FORWARD -i "$WG_IF" -j ACCEPT 2>/dev/null; then
  good "FORWARD 已放行入方向 (-i $WG_IF)"
else
  problem "FORWARD 缺少入方向规则 (-i $WG_IF -j ACCEPT)"
fi
if iptables -C FORWARD -o "$WG_IF" -j ACCEPT 2>/dev/null; then
  good "FORWARD 已放行出方向 (-o $WG_IF)"
else
  problem "FORWARD 缺少出方向规则 (-o $WG_IF -j ACCEPT)：这是“能握手但打不开网页”的最常见原因"
fi
if [ -n "$DEFAULT_IF" ] && iptables -t nat -C POSTROUTING -o "$DEFAULT_IF" -j MASQUERADE 2>/dev/null; then
  good "NAT MASQUERADE 存在 (-o $DEFAULT_IF)"
else
  problem "NAT POSTROUTING 缺少 -o ${DEFAULT_IF:-eth0} -j MASQUERADE（客户端无法共享服务器公网出口）"
fi
echo
echo "  FORWARD 链默认策略:"
run "iptables -L FORWARD -n | head -n 1"

# ---------------------------------------------------------------------------
section "10. 防火墙（ufw / nftables）"
if has ufw; then
  run "ufw status verbose 2>&1"
else
  echo "  未安装 ufw"
fi
if has nft; then
  run "nft list ruleset 2>/dev/null | head -n 80"
fi

# ---------------------------------------------------------------------------
section "11. 端口监听"
run "ss -lunp 2>/dev/null | grep -E \"${WG_PORT}|wg\" || echo '  [!] 未发现监听 ${WG_PORT}/UDP 的进程'"
if ss -lunp 2>/dev/null | grep -q ":${WG_PORT}"; then
  good "已监听 ${WG_PORT}/UDP"
else
  problem "未监听 ${WG_PORT}/UDP（WireGuard 未真正启动）"
fi

# ---------------------------------------------------------------------------
section "12. 公网出口 IP 检测"
run "curl -4 -fsS --max-time 6 https://api.ipify.org 2>&1 || echo '  [!] 无法获取公网 IP（本机可能无外网）'"
echo "  （客户端配置里的 Endpoint 必须等于上面这个公网 IP）"

# ---------------------------------------------------------------------------
section "13. 连通性测试（从服务器自身发起）"
run "ping -c 2 -W 2 10.0.0.1 2>&1"
[ -n "$DEFAULT_IF" ] && run "ping -c 2 -W 2 -I $DEFAULT_IF 223.5.5.5 2>&1"
run "getent hosts www.baidu.com 2>&1 || echo '  [!] DNS 解析失败'"
run "curl -4 -fsS -o /dev/null -w 'curl https 状态码: %{http_code}, 耗时: %{time_total}s\n' --max-time 8 https://www.baidu.com 2>&1 || echo '  [!] HTTPS 出站请求失败'"
if has dig; then run "dig +short www.baidu.com @223.5.5.5 2>&1"; fi

# ---------------------------------------------------------------------------
section "14. 最近日志 / dmesg"
run "journalctl -u wg-quick@$WG_IF -n 80 --no-pager 2>&1"
run "dmesg 2>/dev/null | grep -i -E 'wireguard|wg0' | tail -n 30 || echo '  dmesg 中无 wireguard 记录'"

# ---------------------------------------------------------------------------
section "15. 连接跟踪 / conntrack"
if has conntrack; then
  run "conntrack -C 2>/dev/null"
  run "conntrack -L 2>/dev/null | grep -E '10\\.0\\.0\\.' | head -n 20 || echo '  未看到 10.0.0.x 的连接跟踪记录'"
else
  echo "  未安装 conntrack 工具（可选）"
fi

# ---------------------------------------------------------------------------
section "16. 可选：抓取握手包"
if [ "$CAPTURE" -eq 1 ]; then
  if has tcpdump; then
    echo "[*] 抓取 ${WG_PORT}/UDP 数据包 8 秒，请同时让某个客户端发起连接..."
    run "timeout 8 tcpdump -ni any udp port ${WG_PORT} -c 20 2>&1 || echo '  [!] 8 秒内未抓到任何 ${WG_PORT}/UDP 数据包（说明客户端握手包根本没到服务器：检查安全组/防火墙）'"
  else
    echo "  [i] 未安装 tcpdump，跳过。安装: apt-get install -y tcpdump"
  fi
else
  echo "  [i] 如需抓包验证握手是否到达服务器，请运行: sudo wg-doctor --capture"
fi

# ---------------------------------------------------------------------------
section "诊断结论"
if [ "${#PROBLEMS[@]}" -eq 0 ]; then
  echo "[+] 未发现明显配置问题。若客户端仍无法上网，请携带本日志文件继续排查："
  echo "    $LOG"
else
  echo "发现以下问题（按优先级处理）："
  i=1
  for p in "${PROBLEMS[@]}"; do echo "  $i) $p"; i=$((i+1)); done
fi
echo
echo "已通过的检查："
if [ "${#GOOD[@]}" -eq 0 ]; then echo "  （无）"; else
  for g in "${GOOD[@]}"; do echo "  [+] $g"; done
fi
echo
echo "==================================================================="
echo "完整日志已保存到: $LOG"
echo "可直接复制该文件内容发给维护者排查。"
echo "常用命令:"
echo "  sudo wg-doctor --capture     # 抓包验证握手是否到达"
echo "  sudo wg-uninstall            # 卸载（会自动备份配置）"
echo "==================================================================="
