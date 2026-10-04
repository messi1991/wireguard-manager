#!/bin/bash
# ============================================================================
# wg-remove —— 精准删除一个 WireGuard 客户端
#
# 用法：
#   sudo wg-remove <客户端名>
#   sudo wg-remove <客户端名> --yes     # 跳过二次确认
# ============================================================================

set -uo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "[-] 请使用 root 权限运行此脚本"
  exit 1
fi

WG_DIR="/etc/wireguard"
WG_CONF="$WG_DIR/wg0.conf"
CLIENT_DIR="$WG_DIR/clients"
WG_IF="${WG_IF:-wg0}"
ASSUME_YES=0
CLIENT_NAME=""

# 参数解析：只接受「客户端名」与已知开关，未知参数直接报错，
# 避免 `wg-remove --yes` 把开关当成设备名、或拼错的参数被静默忽略。
for arg in "$@"; do
  case "$arg" in
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help)
      echo "用法: sudo wg-remove <客户端名> [--yes]"
      exit 0 ;;
    -*)
      echo "[!] 未知参数: $arg"
      echo "用法: sudo wg-remove <客户端名> [--yes]"
      exit 1 ;;
    *)
      if [ -n "$CLIENT_NAME" ]; then
        echo "[!] 只能一次删除一个客户端，多余参数: $arg"
        echo "用法: sudo wg-remove <客户端名> [--yes]"
        exit 1
      fi
      CLIENT_NAME="$arg"
      ;;
  esac
done

if [ ! -f "$WG_CONF" ]; then
  echo "[-] 未找到 $WG_CONF，请先运行 install.sh 初始化服务端。"
  exit 1
fi

if [ -z "$CLIENT_NAME" ]; then
  if [ -r /dev/tty ]; then
    read -r -p "请输入要精准删除的客户端名称: " CLIENT_NAME < /dev/tty 2>/dev/null || true
  else
    CLIENT_NAME=""
  fi
fi

if [ -z "$CLIENT_NAME" ]; then
  echo "[-] 客户端名称不能为空！"
  exit 1
fi

if ! echo "$CLIENT_NAME" | grep -qE '^[A-Za-z0-9_.-]+$'; then
  echo "[-] 客户端名称只能包含字母、数字、下划线(_)、点(.)和短横线(-)。"
  exit 1
fi

if [ ! -f "$CLIENT_DIR/$CLIENT_NAME.conf" ]; then
  echo "[-] 未找到名为 '$CLIENT_NAME' 的客户端，请先通过 wg-list 查看。"
  exit 1
fi

# 关键前置校验：必须能在 wg0.conf 中定位到该客户端的 [Peer] 块。
# 否则说明配置里没有带 "# Name: xxx" 注释的对应块（例如手工添加的 Peer），
# 此时若继续执行，脚本会“删不掉却报告成功”，客户端密钥依然有效 -> 安全漏洞。
#
# 统一使用“去掉行首空白与 # 后比较”的方式做匹配（下面 awk 用同样规则），
# 因此可以兼容 "#  Name: x"、"# Name : x" 等写法，避免两处规则不一致。
if ! awk -v want="$CLIENT_NAME" '
  { line = $0
    sub(/\r$/, "", line)
    sub(/^[ \t]+/, "", line)
    sub(/^[#]+[ \t]*/, "", line)
    sub(/^Name[ \t]*:[ \t]*/, "", line)
    sub(/[ \t]+$/, "", line)
    if (line == want) found = 1 }
  END { exit(found ? 0 : 1) }
' "$WG_CONF"; then
  echo "[-] 在 $WG_CONF 中未找到客户端 '$CLIENT_NAME' 的 [Peer] 块。"
  echo "    为避免误报成功，本次不做任何修改。"
  echo "    请手动检查该文件的 [Peer] 段（是否缺少 '# Name: $CLIENT_NAME' 注释）。"
  exit 1
fi

if [ "$ASSUME_YES" -ne 1 ]; then
  CONFIRM=""
  if [ -r /dev/tty ]; then
    read -r -p "[!] 确认要彻底删除客户端 '$CLIENT_NAME' 吗？[y/N]: " CONFIRM < /dev/tty 2>/dev/null || true
  else
    CONFIRM=""
  fi
  if ! echo "$CONFIRM" | grep -qE '^[Yy]$'; then
    echo "[+] 操作已取消。"
    exit 0
  fi
fi

# 修改前先备份，便于重载失败时回滚
BACKUP="$WG_CONF.bak.$(date +%Y%m%d-%H%M%S)"
cp "$WG_CONF" "$BACKUP" || { echo "[-] 备份 $WG_CONF 失败，操作中止。"; exit 1; }

# 精准删除服务端 wg0.conf 中对应的整个 [Peer] 块。
# 旧实现 `sed "/# Name: X/,+2d"` 只删了 3 行，会把 [Peer] 头留在文件里，
# 形成一个没有 PublicKey 的非法 Peer，导致 wg syncconf 报错、
# wg-quick@wg0 无法启动，所有客户端一起断网。
# 下面的实现按 “[ 行” 划分段落，不依赖空行分隔，且只丢弃目标 Peer 块。
# 名称比较用「规范化后精确比对」而不是拼进正则，避免正则注入。
TMP_CONF=$(mktemp)
CLIENT_CONF_BAK=$(mktemp)
trap 'rm -f "$TMP_CONF" "$CLIENT_CONF_BAK"' EXIT

awk -v want="$CLIENT_NAME" '
  function norm(s) {
    sub(/\r$/, "", s)
    sub(/^[ \t]+/, "", s)
    sub(/^[#]+[ \t]*/, "", s)
    sub(/^Name[ \t]*:[ \t]*/, "", s)
    sub(/[ \t]+$/, "", s)
    return s
  }
  function flush() {
    if (inpeer && keep) printf "%s", buf
    buf = ""; inpeer = 0; keep = 1
  }
  /^[ \t]*\[/ {
    # 先结算上一个 Peer 块（保留的才输出），再处理当前行
    flush()
    if ($0 ~ /^[ \t]*\[Peer\]/) { inpeer = 1; keep = 1; buf = $0 ORS; next }
    print; next
  }
  {
    if (inpeer) {
      # 目标块一旦命中标记行，整个块都要丢弃
      if (keep && norm($0) == want) keep = 0
      buf = buf $0 ORS
    } else {
      print
    }
  }
  END { flush() }
' "$WG_CONF" > "$TMP_CONF"

# 删除后必须确实找不到该 Peer 注释，否则放弃修改（保留原文件）。
if awk -v want="$CLIENT_NAME" '
  { line = $0
    sub(/\r$/, "", line); sub(/^[ \t]+/, "", line); sub(/^[#]+[ \t]*/, "", line)
    sub(/^Name[ \t]*:[ \t]*/, "", line); sub(/[ \t]+$/, "", line)
    if (line == want) found = 1 }
  END { exit(found ? 0 : 1) }
' "$TMP_CONF"; then
  rm -f "$TMP_CONF"
  echo "[-] 未能从 $WG_CONF 中移除客户端 '$CLIENT_NAME' 的 Peer 块，已放弃修改。"
  exit 1
fi

mv "$TMP_CONF" "$WG_CONF"
chmod 600 "$WG_CONF"

# 语法校验失败立即回滚到备份，原文件保持不变
if ! wg-quick strip "$WG_IF" >/dev/null 2>&1; then
  echo "[-] 删除后的 $WG_CONF 语法校验失败，已放弃修改（原文件已恢复）。"
  cp "$BACKUP" "$WG_CONF"
  chmod 600 "$WG_CONF"
  exit 1
fi

# 删除客户端配置文件（先留一份临时副本，热重载失败时要能一起恢复）
CLIENT_CONF_PATH="$CLIENT_DIR/$CLIENT_NAME.conf"
[ -f "$CLIENT_CONF_PATH" ] && cp "$CLIENT_CONF_PATH" "$CLIENT_CONF_BAK"
rm -f "$CLIENT_CONF_PATH"

# 热重载生效，即时断开该客户端连接
if ! wg syncconf "$WG_IF" <(wg-quick strip "$WG_IF"); then
  echo "[-] 重载 $WG_IF 失败！正在恢复原配置与客户端配置: $BACKUP"
  cp "$BACKUP" "$WG_CONF"
  chmod 600 "$WG_CONF"
  if [ -f "$CLIENT_CONF_BAK" ]; then
    cp "$CLIENT_CONF_BAK" "$CLIENT_CONF_PATH"
    chmod 600 "$CLIENT_CONF_PATH"
    echo "    已恢复客户端配置: $CLIENT_CONF_PATH"
  fi
  wg syncconf "$WG_IF" <(wg-quick strip "$WG_IF") >/dev/null 2>&1 || true
  echo "    请运行: sudo wg-doctor    或    sudo journalctl -u wg-quick@$WG_IF -n 50"
  exit 1
fi

echo "[+] 客户端 '$CLIENT_NAME' 已被精准删除，相关权限已吊销。"
echo "[i] 原配置备份: $BACKUP"