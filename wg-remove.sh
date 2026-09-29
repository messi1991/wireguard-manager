#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "[-] 请使用 root 权限运行此脚本"
  exit 1
fi

WG_DIR="/etc/wireguard"
WG_CONF="$WG_DIR/wg0.conf"
CLIENT_DIR="$WG_DIR/clients"

if [ ! -f "$WG_CONF" ]; then
  echo "[-] 未找到 $WG_CONF，请先运行 install.sh 初始化服务端。"
  exit 1
fi

if [ -z "$1" ]; then
  if [ -r /dev/tty ]; then
    read -r -p "请输入要精准删除的客户端名称: " CLIENT_NAME < /dev/tty
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

if ! echo "$CLIENT_NAME" | grep -qE '^[A-Za-z0-9_.-]+$'; then
  echo "[-] 客户端名称只能包含字母、数字、下划线(_)、点(.)和短横线(-)。"
  exit 1
fi

if [ ! -f "$CLIENT_DIR/$CLIENT_NAME.conf" ]; then
  echo "[-] 未找到名为 '$CLIENT_NAME' 的客户端，请先通过 wg-list 查看。"
  exit 1
fi

read -r -p "[!] 确认要彻底删除客户端 '$CLIENT_NAME' 吗？[y/N]: " CONFIRM < /dev/tty
if ! echo "$CONFIRM" | grep -qE '^[Yy]$'; then
  echo "[+] 操作已取消。"
  exit 0
fi

# 精准删除服务端 wg0.conf 中对应的整个 [Peer] 块。
# 旧实现 `sed "/# Name: X/,+2d"` 只删了 3 行，会把 [Peer] 头留在文件里，
# 形成一个没有 PublicKey 的非法 Peer，导致 wg syncconf 报错、
# wg-quick@wg0 无法启动，所有客户端一起断网。
TMP_CONF=$(mktemp)
awk -v name="$CLIENT_NAME" '
  function flush() {
    if (inpeer && keep) {
      printf "%s", buf
    }
    buf = ""
  }
  /^\[Peer\]/ {
    flush()
    inpeer = 1
    keep = 1
    buf = $0 "\n"
    next
  }
  /^\[/ {
    flush()
    inpeer = 0
    print
    next
  }
  {
    if (inpeer) {
      buf = buf $0 "\n"
      if ($0 == "# Name: " name) {
        keep = 0
      }
    } else {
      print
    }
  }
  END { flush() }
' "$WG_CONF" > "$TMP_CONF"

if ! grep -qxF "# Name: $CLIENT_NAME" "$TMP_CONF"; then
  mv "$TMP_CONF" "$WG_CONF"
  chmod 600 "$WG_CONF"
else
  rm -f "$TMP_CONF"
  echo "[-] 未能从 $WG_CONF 中移除客户端 '$CLIENT_NAME' 的 Peer 块，已放弃修改。"
  exit 1
fi

# 删除客户端配置文件
rm -f "$CLIENT_DIR/$CLIENT_NAME.conf"

# 热重载生效，即时断开该客户端连接
if ! wg syncconf wg0 <(wg-quick strip wg0); then
  echo "[-] 重载 wg0 失败！请检查 $WG_CONF 与 wg-quick@wg0 状态。"
  exit 1
fi

echo "[+] 客户端 '$CLIENT_NAME' 已被精准删除，相关权限已吊销。"
