# WireGuard Manager

> 一套面向 Ubuntu 的轻量级 WireGuard 命令行管理脚本。一条命令完成服务端部署，之后用 `wg-add` / `wg-list` / `wg-remove` 即可管理所有客户端设备。

<p align="center">
  <b>一键安装 · 多设备 · 扫码即用 · 热重载 · 精准吊销</b>
</p>

---

## 目录

- [简介](#简介)
- [特性](#特性)
- [系统要求](#系统要求)
- [工作原理](#工作原理)
- [快速开始](#快速开始)
- [命令详解](#命令详解)
  - [wg-add —— 添加设备](#wg-add--添加设备)
  - [wg-list —— 查看设备](#wg-list--查看设备)
  - [wg-remove —— 删除设备](#wg-remove--删除设备)
  - [wg-doctor —— 一键诊断/打印日志](#wg-doctor--一键诊断打印日志)
  - [wg-uninstall —— 卸载](#wg-uninstall--卸载)
- [客户端配置说明](#客户端配置说明)
  - [如何导入](#如何导入)
- [macOS 命令行使用指南](#macos-命令行使用指南不使用-gui-客户端)
- [常见问题与排查](#常见问题与排查)
- [文件与目录结构](#文件与目录结构)
- [卸载](#卸载)
- [安全建议](#安全建议)
- [License](#license)

---

## 简介

WireGuard Manager 用纯 Bash 实现，封装了 WireGuard 服务端的初始化、密钥生成、客户端增删、NAT 转发与配置分发。安装后所有管理动作都是**热重载**，**无需重启服务、不影响在线设备**。生成的客户端配置默认为全局代理（`0.0.0.0/0`），手机扫码即可秒级接入。

---

## 特性

- **一键远程安装**：单行 `curl | bash`，自动安装依赖、生成密钥、开启转发、配置 NAT、注册全局命令。
- **多设备不限量**：手机、电脑、平板均可，自动分配不冲突的内网 IP（`10.0.0.2` ~ `10.0.0.254`，优先复用最小空闲地址）。
- **扫码即用**：添加设备时在终端打印二维码，手机 WireGuard App 直接扫描导入。
- **精准吊销**：按设备名删除整个 `[Peer]` 块，被删设备立即断开，**绝不影响其它设备**。
- **热重载**：通过 `wg syncconf` 平滑应用变更，零中断。
- **双向转发**：同时放行 `-i` / `-o` 两个方向的 FORWARD，避免回程被丢（Docker / ufw 环境常见问题）。
- **幂等与校验**：规则重复执行不会叠加；配置非法或重载失败会显式报错。
- **可定制 DNS**：默认 `223.5.5.5, 119.29.29.29`（国内可达），可通过环境变量 `WG_DNS` 覆盖。
- **一键诊断**：`wg-doctor` 只读收集服务状态、握手、路由、iptables、端口、连通性等日志并落盘，网络不通时一键取证。
- **一键卸载**：`wg-uninstall` 自动备份配置后清理服务、规则、命令，可选卸载软件包。

---

## 系统要求

| 项目 | 要求 |
| --- | --- |
| 操作系统 | Ubuntu 20.04 / 22.04 / 24.04（其他 Debian 系亦可） |
| 权限 | `root`（脚本会强制校验 `$EUID`） |
| 内存 / 磁盘 | 无特殊要求，占用极小 |
| 网络 | 服务器需有公网 IP，且安全组/防火墙放行 **`20000-60000/UDP`**（服务端实际监听 `51820`，随机端口经 DNAT 转发） |
| 内核 | 支持 WireGuard（Ubuntu 20.04+ 内置） |

> ⚠️ 云服务器请务必在**云厂商控制台的安全组**中放行 `20000-60000/UDP`，脚本无法修改云安全组。

---

## 工作原理

```
                 ┌──────────────────────────────┐
   手机 / 电脑    │        Ubuntu 服务器          │
  ┌──────────┐   │  ┌────────────────────────┐  │
  │ WG Client│───┼─▶│ wg0  10.0.0.1/24 :51820│  │
  │ 10.0.0.x │◀───┼──│  MASQUERADE → 默认网卡  │──┼──▶ Internet
  └──────────┘   │  └────────────────────────┘  │
                 │   /etc/wireguard/wg0.conf      │
                 │   /etc/wireguard/clients/*.conf│
                 └──────────────────────────────┘
```

- 服务端监听 `51820/UDP`，内网网段 `10.0.0.0/24`，网关为 `10.0.0.1`。
- 客户端使用 `20000-60000` 内的随机端口，服务器用 `PREROUTING DNAT` 转发到 `51820`，对外不暴露固定特征端口。
- 服务端开启 `net.ipv4.ip_forward=1`，并对默认网卡做 `MASQUERADE`，使客户端可访问外网。
- 每个客户端作为独立 `[Peer]` 写入 `wg0.conf`，并按名称在 `clients/` 下保存一份 `.conf`。

---

## 快速开始

在 Ubuntu 服务器上以 **root** 执行：

```bash
curl -fsSL https://raw.githubusercontent.com/messi1991/wireguard-manager/main/install.sh | bash
```

安装过程会：

1. 安装 `wireguard`、`iptables`、`qrencode`、`curl`、`git`（`qrencode` 缺失只会影响二维码显示，不影响安装结果）；
2. 自动探测默认网卡与公网 IP（可手动确认/修改）；
3. 开启内核 IP 转发；
4. 生成服务端密钥并写入 `/etc/wireguard/wg0.conf`；
5. 启动并设置 `wg-quick@wg0` 开机自启；
6. 下载五个管理脚本到 `/usr/local/bin/`（`wg-add`、`wg-list`、`wg-remove`、`wg-doctor`、`wg-uninstall`）。

安装完成后即可使用全局命令 `wg-add` / `wg-list` / `wg-remove` / `wg-doctor` / `wg-uninstall`。

> 重复执行 `install.sh` 不会清空已有客户端：脚本会先备份 `wg0.conf`，保留其中的 `[Peer]` 并顺手清理非法的空 `[Peer]` 块；
> 若识别到的合法 Peer 数量与原文件不一致，脚本会**直接中止**而不是冒险覆盖。
>
> 防火墙 / 转发规则由 `/etc/wireguard/nat.sh` 统一管理（`PostUp` 调用 `nat.sh up %i`，`PostDown` 调用 `nat.sh down %i`），
> 默认网卡在开机时**动态探测**，因此服务器重启后网卡名变化也不会导致“能握手但上不了网”。

### 自定义端口（可选）

安装时可用环境变量指定端口规划，需**先装再改**，改完重跑 `install.sh` 生效：

```bash
sudo WG_PORT_MIN=30000 WG_PORT_MAX=40000 WG_LISTEN_PORT=51821 bash install.sh
```

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `WG_PORT_MIN` / `WG_PORT_MAX` | `20000` / `60000` | 客户端随机端口范围（需放行该 UDP 范围） |
| `WG_LISTEN_PORT` | `51820` | 服务端真实监听端口 |
| `WG_REPO_URL` | 官方仓库地址 | 管理脚本下载源（内网/镜像可用） |

端口规划会写入 `/etc/wireguard/.port_range`，`wg-add` / `wg-doctor` / `wg-uninstall` 全部读取该文件，
`wg-quick@wg0` 的 `PostUp`/`PostDown` 也改为调用 `nat.sh`（端口与网卡都在一处），因此不会出现
“`wg-add` 分配的端口落在 DNAT 范围之外导致连不上”的情况。

> ⚠️ **改变端口范围会让已生成的客户端配置失效**（它们把端口写死在 `Endpoint` 里）。
> 重装时脚本会列出受影响的设备，需要 `sudo wg-remove <设备名>` 后重新 `sudo wg-add <设备名>`。

> `WG_DNS`（自定义 DNS）与端口不同，它是 `wg-add` 的按次环境变量，不影响服务端。

---

## 命令详解

> 所有管理命令均需 `sudo`（脚本会校验 root 权限）。

### wg-add —— 添加设备

```bash
sudo wg-add iphone          # 直接指定设备名
sudo wg-add                 # 交互式输入设备名
```

执行后会：

- 分配一个空闲内网 IP（优先最小空闲，从 `10.0.0.2` 起）；
- 生成客户端密钥，并把 `[Peer]` 追加到服务端 `wg0.conf`；
- 热重载使配置立即生效；
- 在 `/etc/wireguard/clients/<名称>.conf` 生成客户端配置（权限 `600`）；
- 在终端打印二维码。

**设备名限制**：仅允许字母、数字、下划线 `_`、点 `.`、短横线 `-`（正则 `^[A-Za-z0-9_.-]+$`）。

**端口分配**：从安装时设定的范围（默认 `20000-60000`）内随机取一个未占用端口，保证落在服务端 DNAT 规则覆盖范围内。

**安全回滚**：若 `wg0.conf` 语法校验或 `wg syncconf` 失败，脚本会自动把 `wg0.conf` 恢复到添加前的**完整内容**（文件级备份，不是按行截断），不会留下无效 Peer。

**通过环境变量自定义 DNS**：

```bash
# 中国大陆网络下推荐使用国内 DNS，避免解析失败导致“能连上但打不开网页”
WG_DNS="223.5.5.5, 119.29.29.29" sudo wg-add iphone
```

### wg-list —— 查看设备

```bash
sudo wg-list
```

输出示例：

```
==================================================
          已注册的 WireGuard 客户端列表
==================================================
接口: wg0
- 客户端名: iphone
    内网IP: 10.0.0.2/32    Endpoint: 1.2.3.4:20134    公钥: aBcDeFgHiJkL...
    最近握手: 12 秒前    状态: 已注册
- 客户端名: macbook
    内网IP: 10.0.0.3/32    Endpoint: 1.2.3.4:30987    公钥: zYxWvUtSrQpo...
    最近握手: 未握手    状态: 已注册
==================================================
```

> 「公钥」是该客户端自己的公钥（由配置里的私钥推导），因此「最近握手」一栏才准。
> 若某个设备显示 `[异常] 服务端 wg0.conf 中未找到对应 Peer`，说明客户端配置还在、但服务端 Peer 已被删除或手工改坏，用 `sudo wg-doctor` 检查 `wg0.conf`。

### wg-remove —— 删除设备

```bash
sudo wg-remove macbook      # 直接删除（推荐）
sudo wg-remove              # 交互式删除，需二次确认
sudo wg-remove macbook -y   # 跳过确认（脚本化调用）
```

删除操作会：

1. 从 `wg0.conf` 中移除该设备**整个 `[Peer]` 块**（包含 `[Peer]` 头）；
2. 删除 `/etc/wireguard/clients/<名称>.conf`；
3. 热重载，被删设备立即断开并被永久吊销。

其它在线设备完全不受影响。

### wg-doctor —— 一键诊断/打印日志

网络不通时，先运行诊断脚本，它会**只读**收集排查所需的全部信息（不会修改任何配置）：

```bash
sudo wg-doctor              # 常规诊断
sudo wg-doctor --capture    # 额外抓取 8 秒 51820/UDP 握手包（需 tcpdump）
```

内容包括：系统/内核、`wg-quick` 服务状态、`wg show` 握手、服务端与客户端配置（**私钥自动脱敏**）、路由表、IP 转发、iptables/ufw/nftables、端口监听、公网 IP、连通性测试、最近日志，并在结尾给出**问题清单与处理优先级**。

输出会同时保存到 `/tmp/wg-doctor-<时间戳>.log`，把该文件内容发给维护者即可快速定位。

### wg-uninstall —— 卸载

```bash
sudo wg-uninstall                   # 卸载，自动备份配置
sudo wg-uninstall --purge-packages  # 同时卸载 wireguard / qrencode 软件包
sudo wg-uninstall --yes             # 跳过确认（脚本化调用）
```

执行流程：备份 `/etc/wireguard` → 停止并禁用 `wg-quick@wg0` → 清理 iptables 规则 → 删除配置与全局命令 → 可选卸载软件包。备份默认保留在 `/root/wireguard-backup-<时间戳>.tar.gz`。未知参数会直接报错退出，不会执行卸载。

---

## 客户端配置说明

生成的客户端配置模板如下：

```ini
[Interface]
PrivateKey = <客户端私钥>
Address    = 10.0.0.2/32
DNS        = 223.5.5.5, 119.29.29.29

[Peer]
PublicKey           = <服务端公钥>
Endpoint            = <服务器公网IP>:<20000-60000 内的随机端口>
AllowedIPs          = 0.0.0.0/0
PersistentKeepalive = 25
```

| 字段 | 说明 |
| --- | --- |
| `Address` | 客户端内网地址，由脚本自动分配（取最小空闲地址） |
| `DNS` | 默认 `223.5.5.5, 119.29.29.29`，可用 `WG_DNS` 覆盖 |
| `Endpoint` | 服务器公网 IP + 随机端口；服务器端通过 DNAT 将 `20000-60000/UDP` 转发到真实监听的 `51820`（端口范围可在安装时用 `WG_PORT_MIN/MAX` 调整） |
| `AllowedIPs = 0.0.0.0/0` | 全局代理，所有流量走 VPN |
| `PersistentKeepalive = 25` | 维持 NAT 映射，防止长时间空闲掉线 |

### 如何导入

- **手机 / 平板**：打开 WireGuard App → 新建隧道 → 扫描终端二维码。
- **Windows / Linux 桌面**：忽略二维码，从服务器拉取配置文件后在客户端导入：

```bash
# 云主机常禁用 root 直接登录：先在服务器上拷到普通用户目录
ssh <普通用户>@<服务器IP> 'sudo cp /etc/wireguard/clients/<设备名>.conf ~/ && sudo chown $(whoami) ~/<设备名>.conf'
scp <普通用户>@<服务器IP>:<设备名>.conf ./
# 若服务器允许 root 登录，也可直接：
# scp root@<服务器IP>:/etc/wireguard/clients/<设备名>.conf ./
```

> 也可以用 `sudo wg-add` 时终端打印的路径，直接复制配置文件内容。

- **macOS**：同样先 `scp` 下载配置，再用命令行工具接入 → 见下方 [macOS 命令行使用指南](#macos-命令行使用指南不使用-gui-客户端)。

仅在需要访问内网、不需要全局代理时，可把 `AllowedIPs` 改为具体网段，例如 `AllowedIPs = 10.0.0.0/24`。

---

## macOS 命令行使用指南（不使用 GUI 客户端）

> 前提：服务器上已执行 `sudo wg-add macbook` 生成了配置文件，本节只讲**从服务器下载配置**并在 Mac 命令行接入。
> macOS 内核没有 WireGuard 模块，命令行方案用 [`wireguard-go`](https://github.com/WireGuard/wireguard-go) 在用户态实现。

### 步骤 1：安装命令行工具

```bash
brew install wireguard-tools wireguard-go
```

> `wireguard-tools` 提供 `wg` 命令；macOS 上的 `wg-quick` 不可用（依赖 Linux 的 `iptables`/`ip`），所以全部用 `wg` 手动下发配置。

### 步骤 2：从服务器下载配置文件

```bash
mkdir -p ~/wg && cd ~/wg
scp root@<服务器公网IP>:/etc/wireguard/clients/macbook.conf ./wg0.conf
chmod 600 wg0.conf
```

下载后确认内容完整（应有 `PrivateKey` / `Address` / `DNS` / `Endpoint`）：

```bash
cat wg0.conf
```

### 步骤 3：启动接口并下发配置

```bash
# 3.1 创建 utun 接口（前台保持运行；需要另开一个终端执行 3.2）
sudo wireguard-go wg0
```

另开一个终端：

```bash
cd ~/wg
# 3.2 从配置里取出需要的字段
PRIV=$(awk -F'= *' '/^PrivateKey/{gsub(/ /,"",$2);print $2;exit}' wg0.conf)
SRV=$(awk -F'= *' '/^PublicKey/{gsub(/ /,"",$2);print $2;exit}' wg0.conf)
EP=$(awk -F'= *' '/^Endpoint/{gsub(/ /,"",$2);print $2;exit}' wg0.conf)
IP=$(awk -F'= *' '/^Address/{gsub(/ /,"",$2);split($2,a,"/");print a[1];exit}' wg0.conf)
DNS=$(awk -F'= *' '/^DNS/{gsub(/^ +| +$/,"",$2);print $2;exit}' wg0.conf)

# 3.3 下发私钥与 Peer
printf '%s' "$PRIV" | sudo wg set wg0 private-key /dev/stdin
sudo wg set wg0 peer "$SRV" endpoint "$EP" allowed-ips 0.0.0.0/0 persistent-keepalive 25

# 3.4 配置接口地址（macOS 不会自动读取配置里的 Address）
sudo ifconfig wg0 inet "$IP" 10.0.0.1 netmask 255.255.255.0 up

# 3.5 配置 DNS（macOS 不会自动读取配置里的 DNS）
sudo networksetup -setdnsservers "Wi-Fi" $DNS
```

> 网络服务名先用 `networksetup -listallnetworkservices` 查看，有线网卡通常是 `Ethernet`，无线是 `Wi-Fi`。

### 步骤 4：验证连接

```bash
sudo wg show
```

- `latest handshake` 出现时间戳、`transfer` 有收发 → 握手成功；
- 没有握手 → 用同一份配置在手机上试一下，能连则说明 Mac 侧命令有问题，不能连则是服务端/安全组问题。

再验证出口 IP：

```bash
curl -4 https://api.ipify.org; echo
```

### 步骤 5：断开连接

```bash
# 5.1 断开时在运行 wireguard-go 的那个终端按 Ctrl+C
# 或另开终端执行
sudo kill $(pgrep -f 'wireguard-go wg0')
```

### 一键启停脚本（可选）

把下面两个脚本放到 `~/wg/` 下，日常只用这两个命令：

```bash
#!/bin/bash
# ~/wg/wg-up.sh  连接
set -e
cd "$(dirname "$0")"
sudo pkill -f 'wireguard-go wg0' 2>/dev/null || true
sudo wireguard-go wg0 &
sleep 1
PRIV=$(awk -F'= *' '/^PrivateKey/{gsub(/ /,"",$2);print $2;exit}' wg0.conf)
SRV=$(awk -F'= *' '/^PublicKey/{gsub(/ /,"",$2);print $2;exit}' wg0.conf)
EP=$(awk -F'= *' '/^Endpoint/{gsub(/ /,"",$2);print $2;exit}' wg0.conf)
IP=$(awk -F'= *' '/^Address/{gsub(/ /,"",$2);split($2,a,"/");print a[1];exit}' wg0.conf)
DNS=$(awk -F'= *' '/^DNS/{gsub(/^ +| +$/,"",$2);print $2;exit}' wg0.conf)
printf '%s' "$PRIV" | sudo wg set wg0 private-key /dev/stdin
sudo wg set wg0 peer "$SRV" endpoint "$EP" allowed-ips 0.0.0.0/0 persistent-keepalive 25
sudo ifconfig wg0 inet "$IP" 10.0.0.1 netmask 255.255.255.0 up
sudo networksetup -setdnsservers "Wi-Fi" $DNS
sudo wg show
```

```bash
#!/bin/bash
# ~/wg/wg-down.sh  断开
sudo pkill -f 'wireguard-go wg0' 2>/dev/null || echo "隧道未运行"
```

```bash
chmod +x ~/wg/wg-up.sh ~/wg/wg-down.sh
sudo ~/wg/wg-up.sh      # 连接
sudo ~/wg/wg-down.sh    # 断开
```

### 常见问题

| 现象 | 原因 / 解决 |
| --- | --- |
| `wireguard-go` 启动失败 | 必须 `sudo` 执行；系统首次会弹窗，需允许 VPN 类网络扩展 |
| `wg show` 一直没有 handshake | 服务端安全组是否放行 `20000-60000/UDP`；`Endpoint` 的 IP 和随机端口是否与服务器一致（`sudo wg-list` 查看） |
| 能握手但打不开网页 | 检查 DNS：`networksetup -getdnsservers "Wi-Fi"`；检查默认路由 `netstat -rn` |
| 断开后网络不通 | 执行 `sudo networksetup -setdnsservers "Wi-Fi" Empty` 清空手动 DNS，再断开隧道 |

> 💡 只想图形界面使用：安装官方 [WireGuard macOS 客户端](https://apps.apple.com/app/wireguard/id1441685205)，扫码导入 `wg-add` 终端里的二维码即可，配置与本节完全通用。

---

## 常见问题与排查

> 💡 **网络不通时，第一步先运行 `sudo wg-doctor`**，它会把下面排查所需的信息一次性打印并保存到 `/tmp/wg-doctor-*.log`，结尾还会给出问题清单。

### 1. 客户端已导入，但完全无法访问网络

**先确认隧道是否握手成功**：

```bash
sudo wg show          # 服务器端
```

客户端 `latest handshake` 是否刷新、`transfer` 是否有收发。若没有握手，问题在连接层：

- **云安全组 / 防火墙未放行 UDP 端口**（最常见原因）。本方案客户端使用 `20000-60000` 内的随机端口，需放行 **整个 UDP 范围**（只开 `51820/UDP` 不够）。
- 服务器公网 IP 或端口填写错误，检查客户端配置里的 `Endpoint`（执行 `sudo wg-list` 可看到每个设备的 Endpoint）。
- 服务器启用了 `ufw`：脚本会自动 `ufw allow 20000:60000/udp`，可手动复核 `sudo ufw status`。

### 2. 能握手、能 ping 通 `10.0.0.1`，但打不开网页（回程被丢）

说明去程正常、**回程被 FORWARD 丢弃**，常见于安装 Docker 或启用 ufw 的机器。检查并补齐双方向规则：

```bash
# 把 eth0 换成默认网卡（ip route show default 查看）
sudo iptables -C FORWARD -i wg0 -j ACCEPT 2>/dev/null || sudo iptables -I FORWARD 1 -i wg0 -j ACCEPT
sudo iptables -C FORWARD -o wg0 -j ACCEPT 2>/dev/null || sudo iptables -I FORWARD 1 -o wg0 -j ACCEPT

确认 NAT 规则存在（服务器端监听 `51820`，客户端随机端口靠 DNAT 转发）：

```bash
sudo iptables -t nat -S POSTROUTING | grep MASQUERADE
sudo iptables -t nat -S PREROUTING  | grep '20000:60000'

# 规则缺失时直接用 install.sh 生成的脚本重建（会自动探测默认网卡）
sudo /etc/wireguard/nat.sh up wg0
```

确认内核转发已开启：

```bash
sysctl net.ipv4.ip_forward     # 应为 1
```

### 3. 只能打开部分网站 / 大文件卡住（MTU 问题）

WireGuard 默认 MTU 为 `1420`，在 PPPoE 等环境下可能过大。可在客户端 `[Interface]` 中显式设置：

```ini
[Interface]
MTU = 1380
```

逐个尝试 `1380` / `1360` / `1280` 直到稳定。

### 4. 隧道正常但无法解析域名

默认 DNS 已选用国内地址（`223.5.5.5, 119.29.29.29`）。如仍解析失败，可自定义后重新生成配置：

```bash
WG_DNS="223.5.5.5, 119.29.29.29" sudo wg-add iphone
```

### 5. 新增/删除设备后不生效

脚本依赖 `wg-quick@wg0` 处于运行状态。若重载失败，请检查：

```bash
sudo systemctl status wg-quick@wg0
sudo wg-quick strip wg0     # 校验 wg0.conf 是否合法
```

### 6. 服务重启后客户端全部掉线

若曾用旧版本脚本删除过设备，可能残留了非法的空 `[Peer]`。清理方法（下面的脚本按段落扫描，不依赖空行）：

```bash
sudo cp /etc/wireguard/wg0.conf /etc/wireguard/wg0.conf.bak
sudo awk '
  function flush(){ if (inpeer && haspub) printf "%s", buf; buf=""; inpeer=0; haspub=0 }
  { sub(/\r$/, "") }
  /^[ \t]*\[/ { flush(); if ($0 ~ /^[ \t]*\[Peer\]/) { inpeer=1; haspub=0; buf=$0 ORS; next } next }
  { if (inpeer) { buf = buf $0 ORS; if ($0 ~ /^[ \t]*PublicKey[ \t]*=/) haspub=1 } }
  END { flush() }
' /etc/wireguard/wg0.conf > /tmp/wg0.fixed
sudo wg-quick strip /tmp/wg0.fixed >/dev/null && sudo mv /tmp/wg0.fixed /etc/wireguard/wg0.conf
sudo chmod 600 /etc/wireguard/wg0.conf
sudo systemctl restart wg-quick@wg0
```

---

## 文件与目录结构

| 路径 | 说明 |
| --- | --- |
| `install.sh` | 服务端一键安装脚本（可重复执行，保留已有客户端） |
| `wg-add.sh` | 添加客户端 → 安装为 `wg-add` |
| `wg-list.sh` | 列出客户端 → 安装为 `wg-list` |
| `wg-remove.sh` | 删除客户端 → 安装为 `wg-remove` |
| `wg-doctor.sh` | 只读诊断/打印日志 → 安装为 `wg-doctor` |
| `wg-uninstall.sh` | 卸载脚本 → 安装为 `wg-uninstall` |
| `/etc/wireguard/wg0.conf` | 服务端配置（`600`） |
| `/etc/wireguard/server_private.key` / `server_public.key` | 服务端密钥对 |
| `/etc/wireguard/clients/<名称>.conf` | 各客户端配置（`600`） |
| `/etc/wireguard/nat.sh` | install.sh 生成的 FORWARD/NAT 规则管理脚本（`nat.sh up` / `nat.sh down`），开机动态探测默认网卡 |
| `/etc/wireguard/.port_range` | 端口规划（`PORT_MIN/PORT_MAX/LISTEN_PORT`），所有脚本统一读取 |
| `/etc/wireguard/.default_if` | 安装时记录的服务端默认出口网卡，供诊断/卸载时正确清理规则 |
| `/etc/wireguard/wg0.conf.bak.<时间戳>` | `wg-remove` / 重装时自动生成的配置备份 |
| `/usr/local/bin/wg-add` `wg-list` `wg-remove` `wg-doctor` `wg-uninstall` | 全局管理/诊断/卸载命令 |
| `/etc/sysctl.d/99-wg.conf` | 内核 IP 转发持久化配置 |

---

## 卸载

推荐直接用卸载脚本（会自动备份配置）：

```bash
sudo wg-uninstall
```

如需连软件包一起卸载：

```bash
sudo wg-uninstall --purge-packages
```

<details>
<summary>或手动卸载</summary>

```bash
# 停止并禁用服务
sudo systemctl stop wg-quick@wg0
sudo systemctl disable wg-quick@wg0

# 移除全局命令
sudo rm -f /usr/local/bin/wg-add /usr/local/bin/wg-list /usr/local/bin/wg-remove \
           /usr/local/bin/wg-doctor /usr/local/bin/wg-uninstall

# 移除配置（含所有客户端，谨慎操作，建议先备份）
sudo rm -rf /etc/wireguard /etc/sysctl.d/99-wg.conf

# 可选：清理 iptables 规则（推荐直接复用 nat.sh，端口/网卡都自动对齐）
sudo /etc/wireguard/nat.sh down wg0

# 或手工清理（端口以 .port_range 为准）
sudo iptables -D FORWARD -i wg0 -j ACCEPT
sudo iptables -D FORWARD -o wg0 -j ACCEPT
sudo iptables -t nat -D POSTROUTING -o "$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')" -j MASQUERADE
sudo iptables -t nat -D PREROUTING -p udp --dport 20000:60000 -j DNAT --to-destination :51820

# 可选：卸载软件包
sudo apt-get remove --purge -y wireguard
```

</details>

---

## 安全建议

- `wg0.conf` 与客户端 `.conf` 含私钥，脚本已设置 `600` 权限，请勿泄露。
- 本方案客户端使用随机端口，需放行 `20000-60000/UDP`（会略增攻击面，但能有效隐藏 WireGuard 特征；如不在意可改为统一 `51820/UDP`）。
- 不要额外暴露 SSH / 管理端口，限制来源 IP 更安全。
- 定期用 `wg-list` / `wg show` 审计设备，及时 `wg-remove` 吊销闲置或丢失的设备；`wg-remove` 会先备份 `wg0.conf.bak.<时间戳>`，出错可回滚。

---

## License

本项目未声明许可证，使用前请遵循仓库所有者（[@messi1991](https://github.com/messi1991)）的意愿。
