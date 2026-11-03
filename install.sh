#!/usr/bin/env bash
set -Eeuo pipefail

# Replace this with your public GitHub repository, e.g. myname/singbox-node-kit.
REPO="${SINGBOX_NODE_REPO:-YOUR_GITHUB_USERNAME/singbox-node-kit}"
BRANCH="${SINGBOX_NODE_BRANCH:-main}"
INSTALL_DIR="/opt/singbox-node"

if [[ $EUID -ne 0 ]]; then
  echo "请使用 root 执行：sudo bash install.sh" >&2
  exit 1
fi

if [[ "$REPO" == YOUR_GITHUB_USERNAME/* || ! "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "请设置 SINGBOX_NODE_REPO=GitHub用户名/仓库名。" >&2
  echo "示例：sudo SINGBOX_NODE_REPO=myname/singbox-node-kit bash install.sh" >&2
  exit 1
fi

if [[ -f /etc/sing-box-manager/settings.json ]]; then
  echo "检测到已安装的 sing-box-node 项目。为避免覆盖配置，安装程序退出。" >&2
  exit 1
fi
if command -v sing-box >/dev/null 2>&1 || [[ -e /etc/sing-box/config.json ]]; then
  echo "检测到系统已有 sing-box 或配置文件。此脚本只面向全新节点，不会覆盖既有部署。" >&2
  exit 1
fi
for managed_path in \
  /etc/apt/sources.list.d/sagernet.sources \
  /etc/apt/keyrings/sagernet.asc \
  /etc/fail2ban/jail.d/singbox-node-sshd.local \
  /etc/systemd/system/singbox-node-monitor.service \
  /etc/systemd/system/singbox-node-monitor.timer \
  /usr/local/bin/sbx; do
  if [[ -e "$managed_path" ]]; then
    echo "发现已有路径 $managed_path。安装退出以避免覆盖非本项目文件。" >&2
    exit 1
  fi
done

if [[ ! -r /etc/os-release ]]; then
  echo "无法识别系统版本。" >&2; exit 1
fi
. /etc/os-release
if [[ "$ID" != "ubuntu" ]]; then
  echo "本脚本目前只针对 Ubuntu 编写；检测到：${PRETTY_NAME:-$ID}" >&2
  exit 1
fi
case "${VERSION_ID:-}" in
  22.04|24.04|26.04) ;;
  *) echo "支持 Ubuntu 22.04 / 24.04 / 26.04 LTS；当前版本：${VERSION_ID:-unknown}" >&2; exit 1 ;;
esac

command -v systemctl >/dev/null || { echo "需要 systemd。" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl wget gnupg python3 qrencode openssl dnsutils

ARCHIVE_URL="https://codeload.github.com/${REPO}/tar.gz/refs/heads/${BRANCH}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "下载管理脚本：${REPO}/${BRANCH}"
wget -q --tries=3 --timeout=20 -O "$TMP_DIR/project.tar.gz" "$ARCHIVE_URL"
tar -xzf "$TMP_DIR/project.tar.gz" -C "$TMP_DIR"
SRC_DIR="$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d | head -n1)"
[[ -n "$SRC_DIR" ]] || { echo "GitHub 项目压缩包结构不正确。" >&2; exit 1; }
install -d -m 700 "$INSTALL_DIR"
install -m 755 "$SRC_DIR/sbx.py" "$INSTALL_DIR/sbx.py"
install -m 755 "$SRC_DIR/monitor.py" "$INSTALL_DIR/monitor.py"

read -r -p "服务器连接地址（域名或公网 IPv4；留空自动检测）： " SERVER_ADDR
if [[ -z "$SERVER_ADDR" ]]; then
  SERVER_ADDR="$(curl -4fsS --max-time 8 https://api.ipify.org || true)"
fi
if [[ -z "$SERVER_ADDR" ]]; then
  read -r -p "无法自动检测，请输入 VPS 公网 IPv4： " SERVER_ADDR
fi
if [[ -z "$SERVER_ADDR" ]]; then echo "服务器地址不能为空。" >&2; exit 1; fi
if ! [[ "$SERVER_ADDR" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ || "$SERVER_ADDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "服务器连接地址必须是域名或 IPv4 地址。" >&2; exit 1
fi

read -r -p "用于 Hysteria2 TLS 的域名（没有可留空，仅部署 VLESS）： " DOMAIN
read -r -p "REALITY 握手目标域名 [www.microsoft.com]： " REALITY_SNI
REALITY_SNI="${REALITY_SNI:-www.microsoft.com}"
if ! [[ "$REALITY_SNI" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]]; then
  echo "REALITY 握手目标必须是域名。" >&2; exit 1
fi

# This is a fresh-node installer: refuse to overwrite services already bound to the proxy ports.
if ss -lntH 2>/dev/null | awk '$4 ~ /:443$/ {found=1} END {exit !found}'; then
  echo "TCP 443 已有程序监听。为避免覆盖现有服务，安装退出。" >&2
  ss -lntp | grep -E '(:443[[:space:]]|:443$)' || true
  exit 1
fi
if [[ -n "$DOMAIN" ]] && ss -lnuH 2>/dev/null | awk '$4 ~ /:443$/ {found=1} END {exit !found}'; then
  echo "UDP 443 已有程序监听。Hysteria2 无法使用该端口，安装退出。" >&2
  ss -lnup | grep -E '(:443[[:space:]]|:443$)' || true
  exit 1
fi

UFW_ADDED_TCP=0; UFW_ADDED_UDP=0; UFW_ADDED_HTTP=0; UFW_CONFIGURED=0
read -r -p "是否由脚本配置 UFW 防火墙？[Y/n]： " DO_UFW
if [[ ! "$DO_UFW" =~ ^[Nn]$ ]]; then
  UFW_CONFIGURED=1
  apt-get install -y ufw
  SSH_PORT="$(sshd -T 2>/dev/null | awk 'tolower($1)=="port" {print $2; exit}')"
  SSH_PORT="${SSH_PORT:-22}"
  if ! ufw status 2>/dev/null | grep -Eq "${SSH_PORT}/tcp[[:space:]]+ALLOW"; then ufw allow "${SSH_PORT}/tcp" >/dev/null; fi
  if ! ufw status 2>/dev/null | grep -Eq '443/tcp[[:space:]]+ALLOW'; then ufw allow 443/tcp >/dev/null; UFW_ADDED_TCP=1; fi
  # Open the HTTP-01 challenge port before Certbot runs.
  if [[ -n "$DOMAIN" ]] && ! ufw status 2>/dev/null | grep -Eq '80/tcp[[:space:]]+ALLOW'; then ufw allow 80/tcp >/dev/null; UFW_ADDED_HTTP=1; fi
  if [[ -n "$DOMAIN" ]] && ! ufw status 2>/dev/null | grep -Eq '443/udp[[:space:]]+ALLOW'; then ufw allow 443/udp >/dev/null; UFW_ADDED_UDP=1; fi
  if ! ufw status | grep -q '^Status: active'; then
    echo "即将启用 UFW。已先允许 SSH TCP/${SSH_PORT}，但请确认 Vultr 防火墙也允许该 SSH 端口。"
    read -r -p "启用 UFW？[y/N]： " ENABLE_UFW
    [[ "$ENABLE_UFW" =~ ^[Yy]$ ]] && ufw --force enable
  fi
fi

CERT_PATH=""
KEY_PATH=""
HY2_ENABLED=0
EMAIL=""
if [[ -n "$DOMAIN" ]]; then
  if ! [[ "$DOMAIN" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]]; then
    echo "域名格式不正确：$DOMAIN" >&2; exit 1
  fi
  DNS_IPS="$(dig +short A "$DOMAIN" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || true)"
  if [[ -z "$DNS_IPS" ]]; then
    echo "域名没有可用的 IPv4 A 记录，无法按当前 HTTP-01 方式申请证书。" >&2
    exit 1
  fi
  if [[ "$SERVER_ADDR" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && ! grep -Fxq "$SERVER_ADDR" <<<"$DNS_IPS"; then
    echo "警告：域名 A 记录解析结果为 $DNS_IPS，与服务器地址 $SERVER_ADDR 不一致。"
    read -r -p "仍然继续申请证书？[y/N]： " CONT
    [[ "$CONT" =~ ^[Yy]$ ]] || exit 1
  fi
  DNS_AAAA="$(dig +short AAAA "$DOMAIN" || true)"
  if [[ -n "$DNS_AAAA" ]]; then
    echo "检测到域名还有 AAAA 记录：$DNS_AAAA。请确认 IPv6 也指向此 VPS 并允许 TCP/80，否则建议删除错误 AAAA 记录。"
    read -r -p "已确认 AAAA 记录正确，继续？[y/N]： " CONT6
    [[ "$CONT6" =~ ^[Yy]$ ]] || exit 1
  fi
  read -r -p "Let's Encrypt 联系邮箱： " EMAIL
  if [[ -z "$EMAIL" ]]; then echo "启用 Hysteria2 时需要联系邮箱。" >&2; exit 1; fi
  apt-get install -y certbot
  if ss -lntH 2>/dev/null | awk '$4 ~ /:80$/ {found=1} END {exit !found}'; then
    echo "TCP 80 已被占用，Certbot standalone 不能自动验证。请先释放端口 80 后重试。" >&2
    exit 1
  fi
  echo "申请 Let's Encrypt 证书。请确认域名 DNS A 记录直指该 VPS，且未开启 CDN 代理。"
  certbot certonly --standalone --preferred-challenges http -d "$DOMAIN" \
    --non-interactive --agree-tos -m "$EMAIL"
  CERT_PATH="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
  KEY_PATH="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
  [[ -s "$CERT_PATH" && -s "$KEY_PATH" ]] || { echo "证书申请失败。" >&2; exit 1; }
  HY2_ENABLED=1
fi

# Install sing-box from the project's official APT repository; use stable, not beta.
install -d -m 755 /etc/apt/keyrings
curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
chmod 644 /etc/apt/keyrings/sagernet.asc
cat > /etc/apt/sources.list.d/sagernet.sources <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF
apt-get update
apt-get install -y sing-box
command -v sing-box >/dev/null || { echo "sing-box 安装失败。" >&2; exit 1; }
sing-box version

KEYS="$(sing-box generate reality-keypair)"
PRIVATE_KEY="$(printf '%s\n' "$KEYS" | sed -n 's/^PrivateKey:[[:space:]]*//p' | head -n1)"
PUBLIC_KEY="$(printf '%s\n' "$KEYS" | sed -n 's/^PublicKey:[[:space:]]*//p' | head -n1)"
SHORT_ID="$(openssl rand -hex 8)"
if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
  echo "无法生成 REALITY 密钥对。" >&2; exit 1
fi

python3 "$INSTALL_DIR/sbx.py" init --stdin <<EOF
{
  "address": "$SERVER_ADDR",
  "domain": "$DOMAIN",
  "reality_sni": "$REALITY_SNI",
  "private_key": "$PRIVATE_KEY",
  "public_key": "$PUBLIC_KEY",
  "short_id": "$SHORT_ID",
  "cert_path": "$CERT_PATH",
  "key_path": "$KEY_PATH"
}
EOF

read -r -p "第一个设备名称 [windows-pc]： " FIRST_DEVICE
FIRST_DEVICE="${FIRST_DEVICE:-windows-pc}"

# Store exactly which UFW rules this installer added so uninstall can remove only those.
python3 - "$UFW_ADDED_TCP" "$UFW_ADDED_UDP" "$UFW_ADDED_HTTP" <<'PY'
import json,sys
p='/etc/sing-box-manager/settings.json'
d=json.load(open(p))
d['ufw_added']={'443/tcp':sys.argv[1]=='1','443/udp':sys.argv[2]=='1','80/tcp':sys.argv[3]=='1'}
open(p,'w').write(json.dumps(d,ensure_ascii=False,indent=2)+'\n')
PY
chmod 600 /etc/sing-box-manager/settings.json

# SSH jail is narrowly scoped; do not alter sshd authentication settings automatically.
apt-get install -y fail2ban
cat > /etc/fail2ban/jail.d/singbox-node-sshd.local <<'EOF'
[sshd]
enabled = true
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF
systemctl enable --now fail2ban

# Certbot deploy hook copies renewed certificate and restarts the Hysteria2 listener.
if [[ "$HY2_ENABLED" == 1 ]]; then
  if [[ -e /etc/letsencrypt/renewal-hooks/deploy/singbox-node-reload.sh ]]; then
    echo "证书续期 hook 已存在，拒绝覆盖。" >&2; exit 1
  fi
  cat > /etc/letsencrypt/renewal-hooks/deploy/singbox-node-reload.sh <<EOF
#!/usr/bin/env bash
set -e
if [[ "\${RENEWED_LINEAGE:-}" == "/etc/letsencrypt/live/${DOMAIN}" ]]; then
  systemctl restart sing-box
fi
EOF
  chmod 700 /etc/letsencrypt/renewal-hooks/deploy/singbox-node-reload.sh
fi

# Add first device and start the service only after config validation succeeds.
python3 "$INSTALL_DIR/sbx.py" add "$FIRST_DEVICE"
systemctl enable --now sing-box

cat > /usr/local/bin/sbx <<EOF
#!/usr/bin/env bash
exec /usr/bin/python3 ${INSTALL_DIR}/sbx.py "\$@"
EOF
chmod 755 /usr/local/bin/sbx

install -m 644 "$SRC_DIR/systemd/singbox-node-monitor.service" /etc/systemd/system/singbox-node-monitor.service
install -m 644 "$SRC_DIR/systemd/singbox-node-monitor.timer" /etc/systemd/system/singbox-node-monitor.timer
install -d -m 700 /etc/sing-box-manager /var/lib/sing-box-manager
cat > /etc/sing-box-manager/monitor.json <<'EOF'
{
  "interval_alert_mb": 1024,
  "daily_alert_gb": 0,
  "monthly_alert_gb": 0,
  "disk_alert_percent": 90,
  "certificate_alert_days": 14,
  "ssh_failures_5m": 10
}
EOF
chmod 600 /etc/sing-box-manager/monitor.json
systemctl daemon-reload
systemctl enable --now singbox-node-monitor.timer

# Certificate renewal is managed by Certbot's timer; the deploy hook restarts sing-box.
echo
echo "安装完成。"
echo "常用命令："
echo "  sudo sbx add <设备名>       新增设备并导出客户端文件"
echo "  sudo sbx remove <设备名>    撤销设备"
echo "  sudo sbx list               列出设备"
echo "  sudo sbx export <设备名>    重新生成客户端文件"
echo "  sudo sbx status             服务状态"
echo "  sudo sbx traffic            查看网卡总流量统计（非逐设备统计）"
echo "  sudo sbx monitor-config     设置 Telegram 流量告警阈值"
echo "  sudo sbx logs               查看 sing-box 日志"
echo "  sudo sbx tg-set             配置 Telegram Bot"
echo "  sudo sbx tg-test            测试 Telegram 通知"
echo "  sudo sbx uninstall          移除整个项目（需二次确认）"
echo
if [[ "$HY2_ENABLED" == 1 ]]; then
  echo "已启用 VLESS + REALITY (TCP/443) 和 Hysteria2 (UDP/443)。"
else
  echo "已启用 VLESS + REALITY (TCP/443)。Hysteria2 因缺少域名证书未启用。"
fi
echo "客户端文件在：/var/lib/sing-box-manager/exports/${FIRST_DEVICE}/"
echo "注意：配置文件含设备凭据，只通过可信的 SSH/SFTP 方式下载。"
echo "默认不开放 Web 管理端口；只开放实际使用的代理端口和证书续期所需 TCP/80。"
if [[ "$UFW_CONFIGURED" == 0 ]]; then
  echo "注意：脚本未配置 UFW，请自行确认 UFW / VPS 云防火墙允许 SSH、TCP/443；启用 Hysteria2 时还需 UDP/443 和 TCP/80。"
elif ! ufw status 2>/dev/null | grep -q '^Status: active'; then
  echo "注意：UFW 当前未启用，请在 VPS 云防火墙放行 SSH、TCP/443；启用 Hysteria2 时还需 UDP/443 和 TCP/80。"
fi
echo "首次使用 Telegram：sudo sbx tg-set && sudo sbx tg-test"
