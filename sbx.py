#!/usr/bin/env python3
"""Minimal local manager for a personal sing-box server. No database, no public panel."""
from __future__ import annotations
import argparse
import base64
import copy
import getpass
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import uuid
import zipfile
from datetime import datetime, timezone
from pathlib import Path

CONFIG = Path('/etc/sing-box/config.json')
ETC_DIR = Path('/etc/sing-box-manager')
SETTINGS = ETC_DIR / 'settings.json'
STATE_DIR = Path('/var/lib/sing-box-manager')
EXPORT_DIR = STATE_DIR / 'exports'
BACKUP_DIR = Path('/var/backups/sing-box-manager')


def run(cmd: list[str], check: bool = True, capture: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=check, text=True,
                          stdout=subprocess.PIPE if capture else None,
                          stderr=subprocess.PIPE if capture else None)


def require_root() -> None:
    if os.geteuid() != 0:
        raise SystemExit('请使用 sudo 或 root 运行此命令。')


def atomic_json(path: Path, obj: dict, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=path.name + '.', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(obj, f, ensure_ascii=False, indent=2)
            f.write('\n')
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def load_settings() -> dict:
    if not SETTINGS.exists():
        raise SystemExit('项目尚未初始化。请先运行安装脚本。')
    return json.loads(SETTINGS.read_text(encoding='utf-8'))


def save_backup() -> None:
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(BACKUP_DIR, 0o700)
    stamp = datetime.now().strftime('%Y%m%d-%H%M%S')
    for p in (SETTINGS, CONFIG):
        if p.exists():
            dst = BACKUP_DIR / f'{stamp}-{p.name}'
            shutil.copy2(p, dst)
            os.chmod(dst, 0o600)


def validate_name(name: str) -> str:
    name = name.strip().lower()
    if not re.fullmatch(r'[a-z0-9][a-z0-9_-]{0,30}', name):
        raise SystemExit('设备名只允许 1-31 位：小写字母、数字、下划线和短横线，且必须以字母或数字开头。')
    return name


def quote_yaml(s: str) -> str:
    # JSON strings are valid YAML quoted scalars.
    return json.dumps(str(s), ensure_ascii=False)


def make_config(cfg: dict) -> dict:
    srv = cfg['server']
    devices = cfg.get('devices', {})
    users = [
        {'name': name, 'uuid': item['uuid'], 'flow': 'xtls-rprx-vision'}
        for name, item in sorted(devices.items())
    ]
    inbounds = []
    if users:
        inbounds.append({
            'type': 'vless',
            'tag': 'vless-reality-in',
            'listen': '0.0.0.0',
            'listen_port': int(srv.get('vless_port', 443)),
            'users': users,
            'tls': {
                'enabled': True,
                'reality': {
                    'enabled': True,
                    'handshake': {
                        'server': srv['reality_sni'],
                        'server_port': 443
                    },
                    'private_key': srv['reality_private_key'],
                    'short_id': [srv['reality_short_id']]
                }
            }
        })
    if srv.get('hy2_enabled') and devices:
        hy2_users = [
            {'name': name, 'password': item['hy2_password']}
            for name, item in sorted(devices.items())
        ]
        inbounds.append({
            'type': 'hysteria2',
            'tag': 'hysteria2-in',
            'listen': '0.0.0.0',
            'listen_port': int(srv.get('hy2_port', 443)),
            'users': hy2_users,
            'tls': {
                'enabled': True,
                'certificate_path': srv['certificate_path'],
                'key_path': srv['private_key_path']
            }
        })
    return {
        'log': {'level': 'warn', 'timestamp': True},
        'inbounds': inbounds,
        'outbounds': [{'type': 'direct', 'tag': 'direct'}],
        'route': {'final': 'direct'}
    }


def validate_config(path: Path) -> None:
    try:
        run(['sing-box', 'check', '-c', str(path)])
    except subprocess.CalledProcessError as e:
        raise SystemExit('sing-box 配置检查失败：\n' + (e.stderr or e.stdout or str(e)))


def apply_config(cfg: dict, restart: bool = True) -> None:
    CONFIG.parent.mkdir(parents=True, exist_ok=True)
    new_cfg = make_config(cfg)
    fd, tmp = tempfile.mkstemp(prefix='config.json.', dir=str(CONFIG.parent))
    old_config = CONFIG.read_bytes() if CONFIG.exists() else None
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(new_cfg, f, ensure_ascii=False, indent=2)
            f.write('\n')
        os.chmod(tmp, 0o600)
        validate_config(Path(tmp))
        save_backup()
        os.replace(tmp, CONFIG)
        os.chmod(CONFIG, 0o600)
        if restart:
            run(['systemctl', 'restart', 'sing-box'], capture=True)
            run(['systemctl', 'is-active', '--quiet', 'sing-box'], capture=True)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        # Restore the previous working config if the new config fails to start.
        if old_config is not None:
            CONFIG.write_bytes(old_config)
            os.chmod(CONFIG, 0o600)
            if restart:
                run(['systemctl', 'restart', 'sing-box'], check=False, capture=True)
        else:
            CONFIG.unlink(missing_ok=True)
        raise


def create_vless_uri(cfg: dict, dev: dict, name: str) -> str:
    s = cfg['server']
    q = {
        'encryption': 'none',
        'flow': 'xtls-rprx-vision',
        'security': 'reality',
        'sni': s['reality_sni'],
        'fp': 'chrome',
        'pbk': s['reality_public_key'],
        'sid': s['reality_short_id'],
        'type': 'tcp'
    }
    query = urllib.parse.urlencode(q, quote_via=urllib.parse.quote)
    fragment = urllib.parse.quote(f'VLESS-REALITY-{name}', safe='')
    return f"vless://{dev['uuid']}@{s['address']}:{s['vless_port']}?{query}#{fragment}"


def create_hy2_uri(cfg: dict, dev: dict, name: str) -> str | None:
    s = cfg['server']
    if not s.get('hy2_enabled'):
        return None
    password = urllib.parse.quote(dev['hy2_password'], safe='')
    host = s['address']
    sni = s['domain']
    fragment = urllib.parse.quote(f'Hysteria2-{name}', safe='')
    query = urllib.parse.urlencode({'sni': sni}, quote_via=urllib.parse.quote)
    return f'hysteria2://{password}@{host}:{s["hy2_port"]}/?{query}#{fragment}'


def make_singbox_profile(cfg: dict, dev: dict, name: str) -> dict:
    s = cfg['server']
    outbounds = [
        {
            'type': 'vless', 'tag': 'VLESS-REALITY',
            'server': s['address'], 'server_port': int(s['vless_port']),
            'uuid': dev['uuid'], 'flow': 'xtls-rprx-vision',
            'tls': {
                'enabled': True,
                'server_name': s['reality_sni'],
                'utls': {'enabled': True, 'fingerprint': 'chrome'},
                'reality': {
                    'enabled': True,
                    'public_key': s['reality_public_key'],
                    'short_id': s['reality_short_id']
                }
            }
        },
        {'type': 'direct', 'tag': 'direct'}
    ]
    selector_items = ['VLESS-REALITY']
    if s.get('hy2_enabled'):
        outbounds.insert(1, {
            'type': 'hysteria2', 'tag': 'Hysteria2',
            'server': s['address'], 'server_port': int(s['hy2_port']),
            'password': dev['hy2_password'],
            'tls': {'enabled': True, 'server_name': s['domain']}
        })
        selector_items.append('Hysteria2')
    outbounds.insert(0, {
        'type': 'selector', 'tag': 'proxy',
        'outbounds': selector_items,
        'default': 'VLESS-REALITY'
    })
    return {
        'log': {'level': 'warn'},
        'dns': {
            'servers': [
                {
                    'type': 'https', 'tag': 'dns-remote',
                    'server': '1.1.1.1', 'server_port': 443,
                    'path': '/dns-query',
                    'tls': {'enabled': True, 'server_name': 'cloudflare-dns.com'},
                    'detour': 'proxy'
                }
            ],
            'final': 'dns-remote',
            'strategy': 'prefer_ipv4'
        },
        'inbounds': [
            {
                'type': 'tun', 'tag': 'tun-in',
                'address': ['172.19.0.1/30', 'fdfe:dcba:9876::1/126'],
                'auto_route': True
            }
        ],
        'outbounds': outbounds,
        'route': {'auto_detect_interface': True, 'final': 'proxy'}
    }


def make_clash_yaml(cfg: dict, dev: dict, name: str) -> str:
    s = cfg['server']
    lines = ['mixed-port: 7890', 'allow-lan: false', 'mode: rule', 'log-level: info', 'ipv6: false', 'proxies:']
    lines += [
        f'  - name: {quote_yaml("VLESS-REALITY-" + name)}',
        '    type: vless',
        f'    server: {quote_yaml(s["address"])}',
        f'    port: {int(s["vless_port"])}',
        f'    uuid: {quote_yaml(dev["uuid"])}',
        '    network: tcp',
        '    tls: true',
        '    udp: true',
        '    flow: xtls-rprx-vision',
        f'    servername: {quote_yaml(s["reality_sni"])}',
        '    client-fingerprint: chrome',
        '    reality-opts:',
        f'      public-key: {quote_yaml(s["reality_public_key"])}',
        f'      short-id: {quote_yaml(s["reality_short_id"])}'
    ]
    proxy_names = ['VLESS-REALITY-' + name]
    if s.get('hy2_enabled'):
        lines += [
            f'  - name: {quote_yaml("Hysteria2-" + name)}',
            '    type: hysteria2',
            f'    server: {quote_yaml(s["address"])}',
            f'    port: {int(s["hy2_port"])}',
            f'    password: {quote_yaml(dev["hy2_password"])}',
            f'    sni: {quote_yaml(s["domain"])}',
            '    skip-cert-verify: false',
            '    udp: true'
        ]
        proxy_names.append('Hysteria2-' + name)
    lines += ['proxy-groups:', '  - name: PROXY', '    type: select', '    proxies:']
    lines += [f'      - {quote_yaml(n)}' for n in proxy_names]
    lines += ['rules:', '  - MATCH,PROXY', '']
    return '\n'.join(lines)


def export_device(cfg: dict, name: str) -> Path:
    if name not in cfg['devices']:
        raise SystemExit(f'没有找到设备：{name}')
    dev = cfg['devices'][name]
    out = EXPORT_DIR / name
    out.mkdir(parents=True, exist_ok=True)
    os.chmod(EXPORT_DIR, 0o700)
    os.chmod(out, 0o700)
    vless = create_vless_uri(cfg, dev, name)
    hy2 = create_hy2_uri(cfg, dev, name)
    uris = [vless] + ([hy2] if hy2 else [])
    (out / 'nodes.txt').write_text('\n'.join(uris) + '\n', encoding='utf-8')
    (out / 'v2rayn-subscription.txt').write_text(
        base64.b64encode('\n'.join(uris).encode()).decode() + '\n', encoding='utf-8')
    (out / 'sing-box.json').write_text(
        json.dumps(make_singbox_profile(cfg, dev, name), ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    (out / 'mihomo.yaml').write_text(make_clash_yaml(cfg, dev, name), encoding='utf-8')
    if shutil.which('qrencode'):
        run(['qrencode', '-o', str(out / 'vless.png'), '-s', '7', vless], capture=True)
        if hy2:
            run(['qrencode', '-o', str(out / 'hysteria2.png'), '-s', '7', hy2], capture=True)
    # One encrypted-transport-independent bundle for convenient SFTP download.
    bundle = out / f'{name}.zip'
    bundle.unlink(missing_ok=True)
    with zipfile.ZipFile(bundle, 'w', compression=zipfile.ZIP_DEFLATED) as zf:
        for p in sorted(out.iterdir()):
            if p.is_file() and p != bundle:
                zf.write(p, arcname=p.name)
    # Exported files contain credentials.
    for p in out.iterdir():
        if p.is_file():
            os.chmod(p, 0o600)
    return out


def cmd_init(args) -> None:
    require_root()
    if SETTINGS.exists():
        raise SystemExit('检测到现有项目数据，拒绝覆盖。')
    if args.stdin:
        data = json.load(sys.stdin)
    else:
        data = {
            'address': args.address, 'domain': args.domain,
            'reality_sni': args.reality_sni,
            'private_key': args.private_key, 'public_key': args.public_key,
            'short_id': args.short_id,
            'cert_path': args.cert_path, 'key_path': args.key_path
        }
    required = ('address', 'reality_sni', 'private_key', 'public_key', 'short_id')
    if any(not data.get(k) for k in required):
        raise SystemExit('初始化参数不完整。')
    ETC_DIR.mkdir(parents=True, exist_ok=True)
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    EXPORT_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(ETC_DIR, 0o700)
    os.chmod(STATE_DIR, 0o700)
    server = {
        'address': data['address'],
        'domain': data.get('domain') or '',
        'reality_sni': data['reality_sni'],
        'reality_private_key': data['private_key'],
        'reality_public_key': data['public_key'],
        'reality_short_id': data['short_id'],
        'vless_port': 443,
        'hy2_port': 443,
        'hy2_enabled': bool(data.get('domain') and data.get('cert_path') and data.get('key_path')),
        'certificate_path': data.get('cert_path') or '',
        'private_key_path': data.get('key_path') or ''
    }
    cfg = {'schema': 1, 'server': server, 'devices': {}, 'ufw_added': {}}
    atomic_json(SETTINGS, cfg)
    print('初始化完成。')


def cmd_add(args) -> None:
    require_root()
    name = validate_name(args.name)
    cfg = load_settings()
    if name in cfg['devices']:
        raise SystemExit(f'设备已存在：{name}')
    new_dev = {'uuid': str(uuid.uuid4()), 'hy2_password': secrets.token_urlsafe(28)}
    cfg2 = copy.deepcopy(cfg)
    cfg2['devices'][name] = new_dev
    apply_config(cfg2, restart=not args.no_restart)
    atomic_json(SETTINGS, cfg2)
    path = export_device(cfg2, name)
    print(f'已添加设备：{name}')
    print(f'配置导出目录：{path}')
    print(f'一体化下载包：{path / (name + ".zip")}')
    print('请通过 SSH/SFTP 下载设备 ZIP；目录内配置文件含认证凭据，请勿公开分享。')
    if cfg2['server']['hy2_enabled']:
        print('客户端导入：v2rayN 使用 v2rayn-subscription.txt；Clash Verge Rev 使用 mihomo.yaml；sing-box 使用 sing-box.json。')
    else:
        print('当前未配置域名证书，已只生成 VLESS + REALITY。')


def cmd_remove(args) -> None:
    require_root()
    name = validate_name(args.name)
    cfg = load_settings()
    if name not in cfg['devices']:
        raise SystemExit(f'没有找到设备：{name}')
    if len(cfg['devices']) <= 1:
        raise SystemExit('这是最后一台设备。请先添加另一台设备，或使用 sudo sbx uninstall 移除整个项目。')
    if not args.yes:
        answer = input(f'确认撤销设备 {name} 的凭据并重启 sing-box？输入 YES：').strip()
        if answer != 'YES':
            raise SystemExit('已取消。')
    cfg2 = copy.deepcopy(cfg)
    del cfg2['devices'][name]
    apply_config(cfg2, restart=True)
    atomic_json(SETTINGS, cfg2)
    shutil.rmtree(EXPORT_DIR / name, ignore_errors=True)
    print(f'已撤销设备：{name}。其他设备凭据不受影响。')


def cmd_list(args) -> None:
    cfg = load_settings()
    if not cfg['devices']:
        print('尚无设备。添加：sudo sbx add <device-name>')
        return
    print(f"{'设备名':<22} {'VLESS':<10} {'Hysteria2':<12}")
    for name, dev in sorted(cfg['devices'].items()):
        print(f"{name:<22} {'启用':<10} {'启用' if cfg['server']['hy2_enabled'] else '未启用':<12}")


def cmd_export(args) -> None:
    require_root()
    cfg = load_settings()
    name = validate_name(args.name)
    path = export_device(cfg, name)
    print(path)


def cmd_status(args) -> None:
    cfg = load_settings()
    print('sing-box 版本：')
    run(['sing-box', 'version'], capture=False)
    print('\n服务状态：')
    run(['systemctl', 'status', 'sing-box', '--no-pager', '-l'], check=False, capture=False)
    print('\n端口配置：')
    print(f"VLESS TCP: {cfg['server']['vless_port']}")
    print(f"Hysteria2 UDP: {cfg['server']['hy2_port']} ({'启用' if cfg['server']['hy2_enabled'] else '未启用'})")
    print(f"设备数：{len(cfg['devices'])}")


def cmd_logs(args) -> None:
    run(['journalctl', '-u', 'sing-box', '-n', str(args.lines), '--no-pager'], check=False, capture=False)


def cmd_traffic(args) -> None:
    state_file = STATE_DIR / 'traffic.json'
    if state_file.exists():
        d = json.loads(state_file.read_text(encoding='utf-8'))
        print('最近一次监控采样：', d.get('sample_time', '未知'))
        print('网卡：', d.get('interface', '未知'))
        print('累计入站：', format_bytes(d.get('rx_total', 0)))
        print('累计出站：', format_bytes(d.get('tx_total', 0)))
        print('今日累计：', format_bytes(d.get('day_total', 0)))
        print('本月累计：', format_bytes(d.get('month_total', 0)))
        print('说明：以上是 VPS 出入口网卡总流量，不是逐设备精确用量。')
    else:
        print('尚无流量采样。监控定时器会在首次运行后创建统计。')
        print('注意：这里显示 VPS 网卡总流量，不是逐设备精确流量。')


def format_bytes(n: int) -> str:
    value = float(n)
    for unit in ('B', 'KB', 'MB', 'GB', 'TB'):
        if value < 1024 or unit == 'TB':
            return f'{value:.2f} {unit}'
        value /= 1024
    return f'{value:.2f} TB'


def cmd_tg_set(args) -> None:
    require_root()
    token = getpass.getpass('Telegram Bot Token（输入时不回显）: ').strip()
    chat_id = input('Telegram Chat ID: ').strip()
    if not re.fullmatch(r'\d{5,}:[A-Za-z0-9_-]{20,}', token):
        raise SystemExit('Bot Token 格式不正确。')
    if not re.fullmatch(r'-?\d{5,}', chat_id):
        raise SystemExit('Chat ID 格式不正确。')
    ETC_DIR.mkdir(parents=True, exist_ok=True)
    secret_file = ETC_DIR / 'telegram.json'
    atomic_json(secret_file, {'bot_token': token, 'chat_id': chat_id})
    print('Telegram 配置已保存，权限为 600。运行 sudo sbx tg-test 测试。')


def cmd_monitor_config(args) -> None:
    require_root()
    path = ETC_DIR / 'monitor.json'
    current = {'interval_alert_mb': 1024, 'daily_alert_gb': 0, 'monthly_alert_gb': 0, 'disk_alert_percent': 90, 'certificate_alert_days': 14, 'ssh_failures_5m': 10}
    if path.exists():
        try:
            current.update(json.loads(path.read_text(encoding='utf-8')))
        except json.JSONDecodeError:
            pass
    print('流量单位：MB / GB。输入 0 表示关闭该项告警。')
    for key, label in [('interval_alert_mb', '单次 5 分钟采样流量告警 MB'), ('daily_alert_gb', '每日累计网卡流量告警 GB'), ('monthly_alert_gb', '每月累计网卡流量告警 GB')]:
        raw = input(f'{label} [{current[key]}]：').strip()
        if raw:
            try:
                current[key] = float(raw)
                if current[key] < 0:
                    raise ValueError
            except ValueError:
                raise SystemExit('阈值必须为大于或等于 0 的数字。')
    atomic_json(path, current)
    print(f'监控阈值已保存：{path}')


def cmd_tg_test(args) -> None:
    require_root()
    secret_file = ETC_DIR / 'telegram.json'
    if not secret_file.exists():
        raise SystemExit('尚未设置 Telegram。运行 sudo sbx tg-set')
    d = json.loads(secret_file.read_text(encoding='utf-8'))
    import urllib.request
    from urllib.parse import urlencode
    payload = urlencode({'chat_id': d['chat_id'], 'text': 'sing-box 节点管理：Telegram 通知测试成功。'}).encode()
    req = urllib.request.Request(f"https://api.telegram.org/bot{d['bot_token']}/sendMessage", data=payload, method='POST')
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode())
    except Exception as exc:
        # Do not print the request URL because it contains the Bot Token.
        raise SystemExit(f'Telegram 请求失败：{type(exc).__name__}。请检查网络、Token 和 Chat ID。')
    if not data.get('ok'):
        raise SystemExit('Telegram API 返回失败，请检查 Token 和 Chat ID。')
    print('Telegram 测试消息发送成功。')


def cmd_uninstall(args) -> None:
    require_root()
    if not SETTINGS.exists():
        raise SystemExit('没有检测到已安装项目。')
    if not args.yes:
        print('此操作将停止并删除本项目的 sing-box 服务、配置和设备凭据。')
        print('不会删除 SSH 配置、WireGuard、Certbot 安装、证书或系统 UFW 默认策略。')
        answer = input('输入 REMOVE-SINGBOX-NODE 确认：').strip()
        if answer != 'REMOVE-SINGBOX-NODE':
            raise SystemExit('已取消。')
    cfg = load_settings()
    run(['systemctl', 'disable', '--now', 'singbox-node-monitor.timer'], check=False)
    run(['systemctl', 'disable', '--now', 'singbox-node-monitor.service'], check=False)
    for p in ['/etc/systemd/system/singbox-node-monitor.timer', '/etc/systemd/system/singbox-node-monitor.service', '/usr/local/bin/sbx']:
        Path(p).unlink(missing_ok=True)
    run(['systemctl', 'daemon-reload'], check=False)
    run(['systemctl', 'disable', '--now', 'sing-box'], check=False)
    # Remove only firewall rules that this project marked as newly created.
    if shutil.which('ufw'):
        for rule, added in cfg.get('ufw_added', {}).items():
            if added:
                run(['ufw', '--force', 'delete', 'allow', rule], check=False)
    run(['apt-get', 'remove', '-y', 'sing-box'], check=False, capture=False)
    # Remove only project-owned adjunct configuration.
    Path('/etc/fail2ban/jail.d/singbox-node-sshd.local').unlink(missing_ok=True)
    run(['systemctl', 'reload', 'fail2ban'], check=False)
    Path('/etc/letsencrypt/renewal-hooks/deploy/singbox-node-reload.sh').unlink(missing_ok=True)
    Path('/etc/sing-box/config.json').unlink(missing_ok=True)
    try:
        Path('/etc/sing-box').rmdir()
    except OSError:
        pass
    # Remove this project's APT source/key only.
    Path('/etc/apt/sources.list.d/sagernet.sources').unlink(missing_ok=True)
    Path('/etc/apt/keyrings/sagernet.asc').unlink(missing_ok=True)
    shutil.rmtree(ETC_DIR, ignore_errors=True)
    shutil.rmtree(STATE_DIR, ignore_errors=True)
    shutil.rmtree('/opt/singbox-node', ignore_errors=True)
    # Keep Certbot certificates because they may be shared by other services.
    # Keep backups unless --purge-backups is explicitly requested.
    if args.purge_backups:
        shutil.rmtree(BACKUP_DIR, ignore_errors=True)
    run(['systemctl', 'daemon-reload'], check=False)
    print('sing-box 节点项目已卸载。Certbot/证书、SSH、WireGuard、UFW 默认策略未删除。')
    if not args.purge_backups:
        print(f'配置备份仍保留在：{BACKUP_DIR}')


def main() -> None:
    p = argparse.ArgumentParser(prog='sbx', description='sing-box 个人节点管理工具')
    sub = p.add_subparsers(dest='cmd', required=True)
    x = sub.add_parser('init')
    x.add_argument('--stdin', action='store_true', help='从标准输入读取初始化 JSON，避免密钥出现在进程参数中')
    x.add_argument('--address')
    x.add_argument('--domain', default='')
    x.add_argument('--reality-sni')
    x.add_argument('--private-key')
    x.add_argument('--public-key')
    x.add_argument('--short-id')
    x.add_argument('--cert-path', default='')
    x.add_argument('--key-path', default='')
    x.set_defaults(func=cmd_init)
    x = sub.add_parser('add'); x.add_argument('name'); x.add_argument('--no-restart', action='store_true'); x.set_defaults(func=cmd_add)
    x = sub.add_parser('remove'); x.add_argument('name'); x.add_argument('-y', '--yes', action='store_true'); x.set_defaults(func=cmd_remove)
    x = sub.add_parser('list'); x.set_defaults(func=cmd_list)
    x = sub.add_parser('export'); x.add_argument('name'); x.set_defaults(func=cmd_export)
    x = sub.add_parser('status'); x.set_defaults(func=cmd_status)
    x = sub.add_parser('logs'); x.add_argument('-n', '--lines', type=int, default=80); x.set_defaults(func=cmd_logs)
    x = sub.add_parser('traffic'); x.set_defaults(func=cmd_traffic)
    x = sub.add_parser('tg-set'); x.set_defaults(func=cmd_tg_set)
    x = sub.add_parser('tg-test'); x.set_defaults(func=cmd_tg_test)
    x = sub.add_parser('monitor-config'); x.set_defaults(func=cmd_monitor_config)
    x = sub.add_parser('uninstall'); x.add_argument('-y', '--yes', action='store_true'); x.add_argument('--purge-backups', action='store_true'); x.set_defaults(func=cmd_uninstall)
    args = p.parse_args()
    args.func(args)


if __name__ == '__main__':
    main()
