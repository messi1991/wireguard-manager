# sing-box-node-kit（个人多设备节点）

面向**全新 Ubuntu VPS** 的个人 **sing-box** 节点安装与管理工具。它不是 3x-ui 面板，不安装数据库，也不开放公网 Web 管理端口。

> **注意**：该项目基于 **sing-box**（VLESS + REALITY + Vision / Hysteria 2），用于构建 **VPN 翻墙 / 代理节点**。仓库地址为 `messi1991/wireguard-manager`（项目名为 `wireguard-manager`）。

默认部署：

- VLESS + REALITY + Vision：TCP 443
- Hysteria 2：UDP 443（需要自己的域名和 Let's Encrypt 证书）
- systemd 管理 sing-box 和监控任务
- UFW 规则（可选）及 Fail2ban SSH jail
- 每台设备独立 UUID / Hysteria 2 密码
- 输出 v2rayN 分享链接、Mihomo YAML、sing-box JSON
- Telegram 服务、流量突增、磁盘和证书告警

> 本项目不承诺或保证任何协议可以长期绕过网络封锁。节点可用性受 IP、机房线路、协议识别和当地网络策略等因素影响。

## 支持环境

- Ubuntu 22.04 LTS / 24.04 LTS / 26.04 LTS
- systemd
- 建议 x86_64 或 ARM64 VPS
- 必须有 root 或 sudo 权限
- **项目类型**：VPN 翻墙 / 代理节点（基于 sing-box VLESS+REALITY / Hysteria 2）

当前 stable 仓库会安装 sing-box 稳定版，不安装 beta/alpha。2026-10-31 官方 Release 页面列出的最新稳定版本为 1.14.4；安装时 APT 会获取仓库当时的最新稳定包。

## GitHub 发布与安装

1. 在 GitHub 新建一个 **Public** 仓库，例如 `wireguard-manager`。
2. 将本目录中的文件和文件夹上传到仓库根目录，目录层级保持不变。
3. 不要上传服务器生成的 `settings.json`、`config.json`、UUID、密码、私钥、Telegram Token、订阅文件或证书。
4. 在新 Ubuntu VPS 上执行（将 `YOUR_GITHUB_USERNAME` 换成你的 GitHub 用户名）：

```bash
wget -O install.sh https://raw.githubusercontent.com/messi1991/wireguard-manager/main/install.sh
sudo SINGBOX_NODE_REPO=YOUR_GITHUB_USERNAME/wireguard-manager bash install.sh
```

建议先在本地或 VPS 上查看 `install.sh` 内容再用 root 执行。仓库必须是 Public，或者另行设计 GitHub 私有仓库认证；不要把 GitHub Token 写进脚本。

安装脚本从 GitHub 下载仓库归档，再通过 sing-box 官方 APT 仓库安装 stable 版本。官方 APT 源说明：<https://sing-box.sagernet.org/zh/installation/package-manager/>。

## 安装过程会询问什么

1. **服务器连接地址**：建议直接回车，让脚本自动检测 VPS 公网 IPv4。
2. **Hysteria 2 域名**：有自己的域名就填写；A 记录必须指向该 VPS。没有域名可以留空，此时只安装 VLESS + REALITY。
3. **REALITY 握手目标域名**：默认 `www.microsoft.com`。如果 VPS 到该域名网络不通，需换成 VPS 可正常建立 TLS 连接的目标域名。
4. **UFW**：默认会安装并准备允许 SSH 端口、TCP 443；启用 Hysteria 2 时还会允许 UDP 443 和证书续期用 TCP 80。启用前确认 Vultr/云厂商防火墙也允许 SSH 端口，避免锁在服务器外。
5. **首台设备名称**：例如 `windows-pc`。
6. 有 Hysteria 2 域名时，需要输入 Let's Encrypt 联系邮箱。

Hysteria 2 使用 HTTP-01 证书验证，域名 DNS A 记录必须指向 VPS，TCP 80 必须能从公网访问。不要把验证域名设置成代理到其他 CDN 源站的状态。证书续期由 Certbot 管理，续期成功后自动重启 sing-box。

## 端口

| 端口 | 协议 | 用途 | 条件 |
|---|---|---|---|
| SSH 原端口 | TCP | 管理服务器 | 保留现状 |
| 443 | TCP | VLESS + REALITY | 必须 |
| 443 | UDP | Hysteria 2 | 填写 Hysteria 2 域名时启用 |
| 80 | TCP | Let's Encrypt HTTP-01 续期 | 启用 Hysteria 2 时需要 |

不开放 8080、8443 等公网管理端口。脚本只对空闲的新节点端口进行部署；如果检测到已有程序占用 TCP/443 或需使用的 UDP/443，会退出，避免覆盖已有服务。

## 命令

```bash
sudo sbx add iphone          # 添加一台设备
sudo sbx add android         # 添加另一台设备
sudo sbx add macbook         # 添加 macOS 设备
sudo sbx list                # 查看已登记设备
sudo sbx export iphone       # 重新生成 iPhone 配置包
sudo sbx remove iphone      # 撤销指定设备（需要输入 YES）
sudo sbx status              # 查看版本和服务状态
sudo sbx logs                # 查看 sing-box 日志
sudo sbx traffic             # 查看网卡累计流量
sudo sbx monitor-config      # 修改 Telegram 流量阈值
sudo sbx tg-set              # 设置 Telegram Bot
sudo sbx tg-test             # 发送测试通知
sudo sbx uninstall           # 卸载整个项目（需要输入确认短语）
```

设备名只允许 1–31 位小写字母、数字、下划线和短横线，并以字母或数字开头。

`sbx remove` 会撤销该设备的认证凭据并删除其导出文件。为避免无意停服，最后一台设备不能单独删除；要结束整套部署，请运行 `sudo sbx uninstall`。

### 客户端文件

添加设备后会生成目录：

`/var/lib/sing-box-manager/exports/<device-name>/`

其中包括：

- `<device-name>.zip`：一体化下载包，最方便通过 SFTP 下载。
- `nodes.txt`：标准 VLESS / Hysteria 2 分享链接；v2rayN 可复制链接后从剪贴板导入。
- `v2rayn-subscription.txt`：Base64 编码的标准 URI 列表，供后续搭建订阅 URL 时使用；本项目默认不开放公网订阅服务。
- `mihomo.yaml`：导入 macOS Clash Verge Rev 的本地配置文件。
- `sing-box.json`：导入 iOS / Android sing-box 的配置文件。
- `vless.png` / `hysteria2.png`：二维码（安装了 qrencode 时生成）。

`<device-name>.zip` 和所有配置文件都包含认证凭据。文件权限限制为 root 可读写。通过 SSH/SFTP 下载后不要放进公开网盘或 GitHub。

如果 VPS 禁用了 root SSH 登录，使用普通 sudo 用户登录后，可将 ZIP 复制到该用户家目录再通过 SFTP 下载（把 `iphone` 换成设备名）：

```bash
sudo cp /var/lib/sing-box-manager/exports/iphone/iphone.zip "$HOME/iphone.zip"
sudo chown "$USER":"$(id -gn)" "$HOME/iphone.zip"
chmod 600 "$HOME/iphone.zip"
```

## Telegram 告警

1. 在 Telegram 的 `@BotFather` 创建 Bot，取得 Bot Token。
2. 打开刚创建的 Bot，发送 `/start`。
3. 获取你的个人 Chat ID。可以在浏览器访问 Telegram Bot API 的 `getUpdates` 接口读取；URL 中的 Token 是秘密，不能发送给别人或贴到公开 issue。
4. 在 VPS 执行：

```bash
sudo sbx tg-set
sudo sbx tg-test
```

Token 和 Chat ID 保存在 `/etc/sing-box-manager/telegram.json`，权限为 `600`。不要把它上传 GitHub。

监控任务每 5 分钟运行一次。默认告警：

- 最近一次 5 分钟采样的 VPS 网卡收发合计达到 1 GB（持续高流量时最多每 30 分钟重复提醒一次）
- sing-box 由运行变为停止，或停止后恢复
- 最近 5 分钟 SSH 认证失败/无效用户记录达到 10 条（30 分钟冷却）
- Fail2ban 服务停止或恢复
- 根分区使用率达到 90%
- Hysteria 2 TLS 证书距离到期不足 14 天

每日和每月累计告警默认关闭。执行 `sudo sbx monitor-config` 可以设定单次、每日和每月阈值，输入 `0` 关闭对应项。

### 流量统计的边界

当前默认 APT stable 构建没有内置 V2Ray API StatsService。监控脚本读取 VPS 默认出口网卡计数器，统计**整台 VPS 的收发流量**，不能准确区分 Windows、Mac、iPhone、Android 每台设备，也会包含服务器其他服务产生的流量。服务器重启或网卡更换时，累计值可能存在采样缺口。

若以后需要精确到每个 UUID 的流量，需要换成启用 `with_v2ray_api` 构建标签的 sing-box，并在服务端开启仅监听 `127.0.0.1` 的 Stats API，再由本地监控程序采集。官方文档说明 V2Ray API 不包含在默认构建中：<https://sing-box.sagernet.org/configuration/experimental/v2ray-api/>。本项目当前不自行编译内核，以避免给小型 Ubuntu VPS 增加 Go 编译、内存和升级维护负担。

## 安全设计

- 不安装 3x-ui，也不开放 Web 管理面板。
- 管理命令需要 root；项目设置和导出文件权限受限。
- 每台设备使用独立凭据，可单独撤销。
- Fail2ban 只增加项目自己的 SSH jail，不自动修改 `sshd_config`，避免远程锁定风险。
- UFW 仅记录并在卸载时移除本项目新加的代理/证书端口规则；不会关闭 UFW，也不删除 SSH、WireGuard 或系统默认策略。
- REALITY 私钥只保存在服务端设置和配置中，不导出到客户端文件。
- Telegram Token 只保存在 VPS 本地权限为 600 的文件中。

GitHub 仓库内仅保存程序源代码；服务器生成的密钥、设备配置、订阅和 Bot Token 均不应上传。

## 完整卸载

```bash
sudo sbx uninstall
```

输入 `REMOVE-SINGBOX-NODE` 确认。卸载会停止并删除本项目 sing-box 服务、配置、设备凭据、监控 timer、项目脚本及本项目建立的 UFW 代理端口规则。默认保留配置备份、Certbot 软件和证书、WireGuard、SSH 设置、UFW 默认策略及 Fail2ban 软件包。

如确认连配置备份也不要：

```bash
sudo sbx uninstall --purge-backups
```

## 本地检查

开发环境执行：

```bash
python3 -m py_compile sbx.py monitor.py
python3 -m unittest discover -s tests -v
bash -n install.sh
```

安装脚本在真实 VPS 上还会运行 `sing-box check`。本地单元测试不代替真实 Ubuntu、客户端导入和网络连通性测试。