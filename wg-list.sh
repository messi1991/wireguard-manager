#!/bin/bash
# ============================================================================
# wg-list —— 查看已注册的客户端（内网 IP / Endpoint / 公钥 / 握手状态）
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

# 一次性取回所有 peer 的最近握手时间，避免每个客户端都调用一次 wg
HANDSHAKE_MAP=""
if command -v wg >/dev/null 2>&1 && wg show "$WG_IF" >/dev/null 2>&1; then
  HANDSHAKE_MAP=$(wg show "$WG_IF" latest-handshakes 2>/dev/null)
fi
NOW_TS=$(date +%s)

# 与服务端 wg0.conf 比对：客户端配置存在，但 Peer 可能已被手工删掉
peer_registered() {
  awk -v want="$1" '
    { line = $0
      sub(/\r$/, "", line); sub(/^[ \t]+/, "", line); sub(/^[#]+[ \t]*/, "", line)
      sub(/^Name[ \t]*:[ \t]*/, "", line); sub(/[ \t]+$/, "", line)
      if (line == want) found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$WG_CONF"
}

human_since() {
  local ts="$1"
  local ago=$(( NOW_TS - ts ))
  if   [ "$ago" -lt 60 ];    then echo "${ago} 秒前"
  elif [ "$ago" -lt 3600 ];  then echo "$(( ago / 60 )) 分钟前"
  elif [ "$ago" -lt 86400 ]; then echo "$(( ago / 3600 )) 小时前"
  else                           echo "$(( ago / 86400 )) 天前"
  fi
}

echo "=================================================="
echo "          已注册的 WireGuard 客户端列表           "
echo "=================================================="
echo "接口: $WG_IF"
if [ ! -d "$CLIENT_DIR" ] || [ -z "$(ls -A "$CLIENT_DIR" 2>/dev/null)" ]; then
  echo "当前暂无任何客户端配置。"
  echo "=================================================="
  exit 0
fi

for conf in "$CLIENT_DIR"/*.conf; do
  [ -f "$conf" ] || continue
  name=$(basename "$conf" .conf)

  ip=$(awk '/^[[:space:]]*Address/{print $3; exit}' "$conf")
  endpoint=$(awk '/^[[:space:]]*Endpoint/{print $3; exit}' "$conf")
  privkey=$(awk '/^[[:space:]]*PrivateKey/{print $3; exit}' "$conf")
  # 注意：客户端配置里的 [Peer] PublicKey 是“服务端公钥”，
  # 而 wg show latest-handshashes 的键是“客户端自己的公钥”，
  # 所以必须由 PrivateKey 推导，直接拿 Peer 的 PublicKey 去比对永远匹配不上。
  client_pub=""
  if [ -n "$privkey" ] && command -v wg >/dev/null 2>&1; then
    client_pub=$(printf '%s' "$privkey" | wg pubkey 2>/dev/null || true)
  fi
  short_pub=$(printf '%s' "$client_pub" | cut -c1-12)

  if [ -f "$WG_CONF" ] && peer_registered "$name"; then
    status="已注册"
  else
    status="[异常] 服务端 $WG_IF.conf 中未找到对应 Peer"
  fi

  handshake="未握手"
  if [ -n "$client_pub" ] && [ -n "$HANDSHAKE_MAP" ]; then
    ts=$(printf '%s\n' "$HANDSHAKE_MAP" | awk -v k="$client_pub" '$1==k{print $2; exit}')
    case "${ts:-0}" in
      ''|0) : ;;
      *[!0-9]*) : ;;
      *) handshake=$(human_since "$ts") ;;
    esac
  fi

  echo "- 客户端名: $name"
  echo "    内网IP: ${ip:-未知}    Endpoint: ${endpoint:-未知}    公钥: ${short_pub:-未知}"
  echo "    最近握手: $handshake    状态: $status"
done

echo "=================================================="
echo "删除设备请使用: sudo wg-remove <客户端名>"