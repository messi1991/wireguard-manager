#!/usr/bin/env python3
"""Local systemd timer monitor. Traffic is host-NIC aggregate, not per-device."""
from __future__ import annotations
import json
import os
import re
import shutil
import subprocess
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ETC = Path('/etc/sing-box-manager')
STATE_DIR = Path('/var/lib/sing-box-manager')
STATE = STATE_DIR / 'traffic.json'
TG_FILE = ETC / 'telegram.json'
MONITOR_FILE = ETC / 'monitor.json'

DEFAULTS = {
    # Defaults are conservative. Set values > 0 in monitor.json to enable alerts.
    'interval_alert_mb': 0,
    'daily_alert_gb': 0,
    'monthly_alert_gb': 0,
    'disk_alert_percent': 90,
    'certificate_alert_days': 14
}


def read_json(path: Path, default):
    try:
        return json.loads(path.read_text(encoding='utf-8'))
    except (FileNotFoundError, json.JSONDecodeError):
        return default


def write_json(path: Path, obj: dict):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def send_tg(text: str) -> bool:
    d = read_json(TG_FILE, {})
    token, chat_id = d.get('bot_token'), d.get('chat_id')
    if not token or not chat_id:
        return False
    body = urllib.parse.urlencode({'chat_id': chat_id, 'text': text, 'disable_web_page_preview': 'true'}).encode()
    req = urllib.request.Request(
        f'https://api.telegram.org/bot{token}/sendMessage',
        data=body, method='POST', headers={'Content-Type': 'application/x-www-form-urlencoded'})
    try:
        with urllib.request.urlopen(req, timeout=12) as r:
            return bool(json.loads(r.read().decode()).get('ok'))
    except Exception:
        return False


def active(service: str) -> bool:
    p = subprocess.run(['systemctl', 'is-active', '--quiet', service])
    return p.returncode == 0


def default_iface() -> str | None:
    p = subprocess.run(['ip', 'route', 'get', '1.1.1.1'], text=True, capture_output=True)
    if p.returncode == 0:
        parts = p.stdout.split()
        if 'dev' in parts:
            i = parts.index('dev')
            if i + 1 < len(parts):
                return parts[i + 1]
    return None


def iface_counters(iface: str) -> tuple[int, int] | None:
    try:
        for line in Path('/proc/net/dev').read_text().splitlines()[2:]:
            if ':' not in line:
                continue
            name, values = line.split(':', 1)
            if name.strip() == iface:
                nums = [int(x) for x in values.split()]
                return nums[0], nums[8]
    except Exception:
        pass
    return None


def disk_percent() -> int:
    return int(shutil.disk_usage('/').used * 100 / max(1, shutil.disk_usage('/').total))


def cert_days_left() -> int | None:
    settings = read_json(ETC / 'settings.json', {})
    s = settings.get('server', {})
    if not s.get('hy2_enabled'):
        return None
    cert = s.get('certificate_path', '')
    if not cert or not Path(cert).exists():
        return -1
    p = subprocess.run(['openssl', 'x509', '-in', cert, '-noout', '-enddate'], capture_output=True, text=True)
    if p.returncode != 0 or '=' not in p.stdout:
        return -1
    end = p.stdout.strip().split('=', 1)[1]
    try:
        dt = datetime.strptime(end, '%b %d %H:%M:%S %Y %Z').replace(tzinfo=timezone.utc)
        return int((dt - datetime.now(timezone.utc)).total_seconds() // 86400)
    except ValueError:
        return None



def recent_ssh_failures() -> int:
    p = subprocess.run(
        ['journalctl', '-u', 'ssh.service', '-u', 'sshd.service', '--since', '5 minutes ago', '--no-pager', '-o', 'cat'],
        text=True, capture_output=True)
    if p.returncode != 0:
        return 0
    markers = ('failed password', 'failed publickey', 'invalid user', 'authentication failure')
    return sum(1 for line in p.stdout.lower().splitlines() if any(x in line for x in markers))


def main():
    cfg = DEFAULTS | read_json(MONITOR_FILE, {})
    now = datetime.now().astimezone()
    now_iso = now.isoformat(timespec='seconds')
    iface = default_iface()
    if not iface:
        return
    counters = iface_counters(iface)
    if counters is None:
        return
    rx, tx = counters
    st = read_json(STATE, {})
    alerts = []

    if st.get('last_rx') is not None and st.get('interface') == iface:
        delta_rx = max(0, rx - int(st.get('last_rx', rx)))
        delta_tx = max(0, tx - int(st.get('last_tx', tx)))
        delta = delta_rx + delta_tx
    else:
        # First sample, reboot/reset, or interface change: establish a new baseline.
        delta_rx = delta_tx = delta = 0

    day_key, month_key = now.strftime('%Y-%m-%d'), now.strftime('%Y-%m')
    day_total = int(st.get('day_total', 0)) if st.get('day_key') == day_key else 0
    month_total = int(st.get('month_total', 0)) if st.get('month_key') == month_key else 0
    day_total += delta
    month_total += delta

    interval_limit = float(cfg.get('interval_alert_mb', 0)) * 1024 * 1024
    day_limit = float(cfg.get('daily_alert_gb', 0)) * 1024**3
    month_limit = float(cfg.get('monthly_alert_gb', 0)) * 1024**3

    if interval_limit > 0 and delta >= interval_limit:
        last_alert = int(st.get('interval_alert_ts', 0))
        now_ts = int(now.timestamp())
        # Avoid Telegram flooding during a sustained high-traffic period.
        if now_ts - last_alert >= 1800:
            alerts.append(f'流量突增：最近一次采样间隔网卡收发合计 {delta / 1024**2:.1f} MB。')
            st['interval_alert_ts'] = now_ts
    if day_limit > 0 and day_total >= day_limit and st.get('day_alert_key') != day_key:
        alerts.append(f'今日网卡累计流量已达到 {day_total / 1024**3:.2f} GB。')
        st['day_alert_key'] = day_key
    if month_limit > 0 and month_total >= month_limit and st.get('month_alert_key') != month_key:
        alerts.append(f'本月网卡累计流量已达到 {month_total / 1024**3:.2f} GB。')
        st['month_alert_key'] = month_key

    service_ok = active('sing-box')
    if not service_ok and st.get('singbox_was_active', True):
        alerts.append('sing-box 服务当前不在 active 状态，请检查：journalctl -u sing-box -n 100 --no-pager')
    if service_ok and st.get('singbox_was_active') is False:
        alerts.append('sing-box 服务已恢复运行。')
    st['singbox_was_active'] = service_ok

    fail2ban_ok = active('fail2ban')
    if not fail2ban_ok and st.get('fail2ban_was_active', True):
        alerts.append('Fail2ban 服务当前未运行，请检查 systemctl status fail2ban。')
    if fail2ban_ok and st.get('fail2ban_was_active') is False:
        alerts.append('Fail2ban 服务已恢复运行。')
    st['fail2ban_was_active'] = fail2ban_ok

    ssh_fail_limit = int(cfg.get('ssh_failures_5m', 10))
    ssh_fail_count = recent_ssh_failures()
    if ssh_fail_limit > 0 and ssh_fail_count >= ssh_fail_limit:
        last_ssh_alert = int(st.get('ssh_alert_ts', 0))
        now_ts = int(now.timestamp())
        if now_ts - last_ssh_alert >= 1800:
            alerts.append(f'SSH 登录失败异常：最近 5 分钟检测到 {ssh_fail_count} 条失败/无效用户记录。')
            st['ssh_alert_ts'] = now_ts

    dp = disk_percent()
    disk_limit = int(cfg.get('disk_alert_percent', 90))
    if dp >= disk_limit and st.get('disk_alerted') is not True:
        alerts.append(f'根分区使用率达到 {dp}%，请检查日志和磁盘空间。')
        st['disk_alerted'] = True
    elif dp < max(1, disk_limit - 5):
        st['disk_alerted'] = False

    days = cert_days_left()
    cert_threshold = int(cfg.get('certificate_alert_days', 14))
    if days is not None and days < cert_threshold:
        cert_key = str(days)
        if st.get('cert_alert_key') != cert_key:
            if days < 0:
                alerts.append('Hysteria2 TLS 证书无法读取或已过期，请检查 Certbot。')
            else:
                alerts.append(f'Hysteria2 TLS 证书将在 {days} 天后到期。')
            st['cert_alert_key'] = cert_key
    elif days is not None:
        st.pop('cert_alert_key', None)

    st.update({
        'interface': iface, 'last_rx': rx, 'last_tx': tx,
        'rx_total': int(st.get('rx_total', 0)) + delta_rx,
        'tx_total': int(st.get('tx_total', 0)) + delta_tx,
        'day_key': day_key, 'day_total': day_total,
        'month_key': month_key, 'month_total': month_total,
        'sample_time': now_iso
    })
    write_json(STATE, st)

    if alerts:
        msg = 'sing-box 服务器监控告警\n' + '\n'.join('• ' + a for a in alerts)
        msg += f'\n时间：{now_iso}\n网卡：{iface}'
        send_tg(msg)


if __name__ == '__main__':
    main()
