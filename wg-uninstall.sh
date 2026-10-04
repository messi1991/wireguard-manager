#!/bin/bash
# ============================================================================
# wg-uninstall —— WireGuard Manager 卸载脚本
#
#   * 默认先把 /etc/wireguard 备份到 /root/ 再删除
#   * 停止并禁用 wg-quick、清理残留 iptables 规则与全局命令
#   * 加 --purge-packages 可一并卸载 wireguard / qrencode 软件包
#
# 用法：
#   sudo wg-uninstall                   # 卸载交互组件（自动备份）
#   sudo wg-uninstall --purge-packages  # 同时卸载软件包
#   sudo wg-uninstall --yes             # 跳过确认（脚本化调用）
# ============================================================================

set -uo pipefail

WG_IF="${WG_IF:-wg0}"
WG_DIR="/etc/wireguard"
SELF_PATH="/usr/local/bin/wg-uninstall"
PURGE_PKGS=0
ASSUME_YES=0

for arg in "$@"; do
  case "$arg" in
    --purge-packages) PURGE_PKGS=1 ;;
    --yes|-y)         ASSUME_YES=1 ;;
    -h|--help)
      echo "用法: sudo wg-uninstall [--purge-packages] [--yes]"
      exit 0 ;;
    *)
      echo "[!] 未知参数: $arg"
      echo "用法: sudo wg-uninstall [--purge-packages] [--yes]"
      exit 1 ;;
  esac
done

if [ "$EUID" -ne 0 ]; then
  echo "[-] 请使用 root 权限运行: sudo wg-uninstall"
  exit 1
fi

# 端口规划统一从 install.sh 写入的状态文件读取，避免各脚本写死不同数值
SRV_PORT_MIN=20000; SRV_PORT_MAX=60000; SRV_LISTEN_PORT=51820
if [ -r "$WG_DIR/.port_range" ]; then
  # shellcheck disable=SC1090
  . "$WG_DIR/.port_range"
fi

# 记录安装时使用的默认出口网卡（install.sh 会写入 /etc/wireguard/.default_if）
DEFAULT_IF=""
if [ -f "$WG_DIR/.default_if" ]; then
  DEFAULT_IF=$(cat "$WG_DIR/.default_if" 2>/dev/null)
fi
if [ -z "$DEFAULT_IF" ]; then
  DEFAULT_IF=$(ip route show default 2>/dev/null | awk '
    /default/ {
      for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }
    }' | head -n1)
fi
IP_FORWARD_BEFORE=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo "")

echo "=================================================="
echo "           WireGuard Manager 卸载程序"
echo "=================================================="
echo "将执行以下操作："
echo "  1. 备份 /etc/wireguard（如果存在）"
echo "  2. 停止并禁用 wg-quick@$WG_IF"
echo "  3. 清理 iptables 转发 / NAT 规则"
echo "  4. 删除 /etc/wireguard 及全局命令 wg-add/wg-list/wg-remove/wg-doctor/wg-uninstall"
echo "  5. 删除 /etc/sysctl.d/99-wg.conf（IP 转发配置）"
[ "$PURGE_PKGS" -eq 1 ] && echo "  6. 卸载软件包 wireguard / qrencode"
echo "--------------------------------------------------"

if [ "$ASSUME_YES" -ne 1 ]; then
  CONFIRM=""
  if [ -r /dev/tty ]; then
    read -r -p "确认继续卸载吗？输入 YES 继续: " CONFIRM < /dev/tty 2>/dev/null || true
  else
    CONFIRM=""
  fi
  if [ "$CONFIRM" != "YES" ]; then
    echo "[+] 操作已取消。"
    exit 0
  fi
fi

# 1. 备份 -------------------------------------------------------------------
if [ -d "$WG_DIR" ]; then
  BACKUP="/root/wireguard-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  if tar -czf "$BACKUP" -C /etc wireguard 2>/dev/null && [ -s "$BACKUP" ]; then
    chmod 600 "$BACKUP"
    echo "[+] 已备份配置到: $BACKUP"
  else
    rm -f "$BACKUP"
    echo "[!] 备份失败，出于安全考虑已中止卸载。"
    exit 1
  fi
else
  echo "[i] 未找到 $WG_DIR，跳过备份。"
fi

# 2. 停止并禁用服务（stop 会自动执行 PostDown 清理其添加的规则）------------
if systemctl list-unit-files 2>/dev/null | grep -q "wg-quick@$WG_IF"; then
  systemctl stop "wg-quick@$WG_IF" 2>/dev/null && echo "[+] 已停止 wg-quick@$WG_IF"
  systemctl disable "wg-quick@$WG_IF" 2>/dev/null && echo "[+] 已禁用 wg-quick@$WG_IF"
else
  echo "[i] 未发现 wg-quick@$WG_IF 服务单元。"
fi

# 3. 兜底清理 iptables 规则 -------------------------------------------------
# 优先复用 install.sh 生成的 nat.sh（up/down 对称、端口范围与安装时一致）；
# 若脚本不存在（例如旧版本安装），再按 .port_range 里的数值手工清理。
if [ -x "$WG_DIR/nat.sh" ]; then
  "$WG_DIR/nat.sh" down "$WG_IF" 2>/dev/null && echo "[+] 已通过 nat.sh 清理 WireGuard 规则。"
else
  for dir in -i -o; do
    while iptables -C FORWARD "$dir" "$WG_IF" -j ACCEPT 2>/dev/null; do
      iptables -D FORWARD "$dir" "$WG_IF" -j ACCEPT 2>/dev/null || break
    done
  done
  if [ -n "$DEFAULT_IF" ]; then
    while iptables -t nat -C POSTROUTING -o "$DEFAULT_IF" -j MASQUERADE 2>/dev/null; do
      iptables -t nat -D POSTROUTING -o "$DEFAULT_IF" -j MASQUERADE 2>/dev/null || break
    done
  fi
  while iptables -t nat -C PREROUTING -p udp --dport "${SRV_PORT_MIN}:${SRV_PORT_MAX}" -j DNAT --to-destination ":${SRV_LISTEN_PORT}" 2>/dev/null; do
    iptables -t nat -D PREROUTING -p udp --dport "${SRV_PORT_MIN}:${SRV_PORT_MAX}" -j DNAT --to-destination ":${SRV_LISTEN_PORT}" 2>/dev/null || break
  done
fi
# PostUp 里是动态探测网卡，因此安装时的网卡名可能与当前不同，两个都清一遍
if [ -n "$DEFAULT_IF" ]; then
  LIVE_IF=$(ip route show default 2>/dev/null | awk '
    /default/ { for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }' | head -n1)
  [ -n "$LIVE_IF" ] && [ "$LIVE_IF" != "$DEFAULT_IF" ] \
    && { while iptables -t nat -C POSTROUTING -o "$LIVE_IF" -j MASQUERADE 2>/dev/null; do
           iptables -t nat -D POSTROUTING -o "$LIVE_IF" -j MASQUERADE 2>/dev/null || break
         done; }
fi
echo "[+] 已清理残留 iptables 规则（如有）。"

# 4. 删除配置与全局命令 -----------------------------------------------------
rm -rf "$WG_DIR"
rm -f /etc/sysctl.d/99-wg.conf /etc/sysctl.d/wg.conf
rm -f /usr/local/bin/wg-add \
      /usr/local/bin/wg-list \
      /usr/local/bin/wg-remove \
      /usr/local/bin/wg-doctor
echo "[+] 已删除配置目录与全局命令。"

# ufw 规则（可能被重复添加，循环删除）
if command -v ufw >/dev/null 2>&1; then
  while ufw status 2>/dev/null | grep -q "${SRV_PORT_MIN}:${SRV_PORT_MAX}/udp"; do
    ufw delete allow "${SRV_PORT_MIN}:${SRV_PORT_MAX}/udp" >/dev/null 2>&1 || break
  done
fi

# 恢复 sysctl：删除配置文件后 sysctl --system 不会自动复位已生效的值，
# 这里显式恢复为卸载前的取值。
sysctl --system >/dev/null 2>&1 || true
if [ -n "$IP_FORWARD_BEFORE" ] && [ "$IP_FORWARD_BEFORE" != "1" ]; then
  sysctl -w net.ipv4.ip_forward="$IP_FORWARD_BEFORE" >/dev/null 2>&1 \
    && echo "[+] 已恢复 net.ipv4.ip_forward=$IP_FORWARD_BEFORE"
fi

# 5. 可选卸载软件包 ---------------------------------------------------------
if [ "$PURGE_PKGS" -eq 1 ]; then
  echo "[+] 正在卸载软件包 wireguard / qrencode ..."
  if ! DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y wireguard qrencode 2>/dev/null; then
    echo "[!] 软件包卸载失败，请手动执行: apt-get remove --purge -y wireguard qrencode"
  fi
  apt-get autoremove -y >/dev/null 2>&1 || true
fi

# 6. 删除脚本自身 -----------------------------------------------------------
# 放在所有逻辑最后：Linux 允许删除正在运行的脚本，删除 inode 不影响当前进程。
# 之前用 `[ "$SELF_PATH" != "$0" ]` 判断会导致「sudo wg-uninstall」（最常见用法）
# 恰好跳过删除，命令残留。
rm -f "$SELF_PATH"
[ -f "$SELF_PATH" ] || echo "[+] 已删除全局命令 wg-uninstall。"

echo "=================================================="
echo "[+] 卸载完成。"
if [ -n "${BACKUP:-}" ]; then
  echo "[i] 配置备份保留在: $BACKUP"
fi
echo "=================================================="