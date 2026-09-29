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

WG_IF="${WG_IF:-wg0}"
WG_DIR="/etc/wireguard"
PURGE_PKGS=0
ASSUME_YES=0

for arg in "$@"; do
  case "$arg" in
    --purge-packages) PURGE_PKGS=1 ;;
    --yes|-y)         ASSUME_YES=1 ;;
    *) echo "[!] 未知参数: $arg";;
  esac
done

if [ "$EUID" -ne 0 ]; then
  echo "[-] 请使用 root 权限运行: sudo wg-uninstall"
  exit 1
fi

echo "=================================================="
echo "           WireGuard Manager 卸载程序"
echo "=================================================="
echo "将执行以下操作："
echo "  1. 备份 /etc/wireguard（如果存在）"
echo "  2. 停止并禁用 wg-quick@$WG_IF"
echo "  3. 清理 iptables 转发规则"
echo "  4. 删除 /etc/wireguard 及全局命令 wg-add/wg-list/wg-remove/wg-doctor/wg-uninstall"
echo "  5. 删除 /etc/sysctl.d/99-wg.conf（IP 转发配置）"
[ "$PURGE_PKGS" -eq 1 ] && echo "  6. 卸载软件包 wireguard / qrencode"
echo "--------------------------------------------------"

if [ "$ASSUME_YES" -ne 1 ]; then
  if [ -r /dev/tty ]; then
    read -r -p "确认继续卸载吗？输入 YES 继续: " CONFIRM < /dev/tty
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
  if tar -czf "$BACKUP" -C /etc wireguard 2>/dev/null; then
    chmod 600 "$BACKUP"
    echo "[+] 已备份配置到: $BACKUP"
  else
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

# 3. 兜底清理 iptables 规则（PostDown 失败时的保险）-------------------------
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
for dir in -i -o; do
  # 同一规则可能被重复添加，循环删除直到不存在
  while iptables -C FORWARD "$dir" "$WG_IF" -j ACCEPT 2>/dev/null; do
    iptables -D FORWARD "$dir" "$WG_IF" -j ACCEPT 2>/dev/null || break
  done
done
if [ -n "$DEFAULT_IF" ]; then
  while iptables -t nat -C POSTROUTING -o "$DEFAULT_IF" -j MASQUERADE 2>/dev/null; do
    iptables -t nat -D POSTROUTING -o "$DEFAULT_IF" -j MASQUERADE 2>/dev/null || break
  done
fi
echo "[+] 已清理残留 iptables 规则（如有）。"

# 4. 删除配置与全局命令 -----------------------------------------------------
rm -rf "$WG_DIR"
rm -f /etc/sysctl.d/99-wg.conf /etc/sysctl.d/wg.conf
rm -f /usr/local/bin/wg-add \
      /usr/local/bin/wg-list \
      /usr/local/bin/wg-remove \
      /usr/local/bin/wg-doctor \
      /usr/local/bin/wg-uninstall
echo "[+] 已删除配置目录与全局命令。"

# ufw 规则
if command -v ufw >/dev/null 2>&1; then
  ufw delete allow 51820/udp >/dev/null 2>&1 || true
fi

# 重新加载 sysctl（恢复默认转发行为）
sysctl --system >/dev/null 2>&1 || true

# 5. 可选卸载软件包 ---------------------------------------------------------
if [ "$PURGE_PKGS" -eq 1 ]; then
  echo "[+] 正在卸载软件包 wireguard / qrencode ..."
  DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y wireguard qrencode 2>/dev/null || \
    echo "[!] 软件包卸载失败，请手动执行: apt-get remove --purge -y wireguard qrencode"
  apt-get autoremove -y >/dev/null 2>&1 || true
fi

echo "=================================================="
echo "[+] 卸载完成。"
if [ -n "${BACKUP:-}" ]; then
  echo "[i] 配置备份保留在: $BACKUP"
fi
echo "=================================================="
