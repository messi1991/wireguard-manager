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
- **可定制 DNS**：默认 `1.1.1.1, 8.8.8.8`，可通过环境变量覆盖。
- **一键诊断**：`wg-doctor` 只读收集服务状态、握手、路由、iptables、端口、连通性等日志并落盘，网络不通时一键取证。
- **一键卸载**：`wg-uninstall` 自动备份配置后清理服务、规则、命令，可选卸载软件包。

---

## 系统要求

| 项目 | 要求 |
| --- | --- |
| 操作系统 | Ubuntu 20.04 / 22.04 / 24.04（其他 Debian 系亦可） |
| 权限 | `root`（脚本会强制校验 `$EUID`） |
| 内存 / 磁盘 | 无特殊要求，占用极小 |
| 网络 | 服务器需有公网 IP，且安全组/防火墙放行 **`51820/UDP`** |
| 内核 | 支持 WireGuard（Ubuntu 20.04+ 内置） |

> ⚠️ 云服务器请务必在**云厂商控制台的安全组**中放行 `51820/UDP`，脚本无法修改云安全组。

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
- 服务端开启 `net.ipv4.ip_forward=1`，并对默认网卡做 `MASQUERADE`，使客户端可访问外网。
- 每个客户端作为独立 `[Peer]` 写入 `wg0.conf`，并按名称在 `clients/` 下保存一份 `.conf`。

---

## 快速开始

在 Ubuntu 服务器上以 **root** 执行：

```bash
curl -fsSL https://raw.githubusercontent.com/messi1991/wireguard-manager/main/install.sh | bash
```

安装过程会：

1. 安装 `wireguard`、`iptables`、`qrencode`、`curl`、`git`；
2. 自动探测默认网卡与公网 IP（可手动确认/修改）；
3. 开启内核 IP 转发；
4. 生成服务端密钥并写入 `/etc/wireguard/wg0.conf`；
5. 启动并设置 `wg-quick@wg0` 开机自启；
6. 下载五个管理脚本到 `/usr/local/bin/`（`wg-add`、`wg-list`、`wg-remove`、`wg-doctor`、`wg-uninstall`）。

安装完成后即可使用全局命令 `wg-add` / `wg-list` / `wg-remove` / `wg-doctor` / `wg-uninstall`。

> 重复执行 `install.sh` 不会清空已有客户端：脚本会先备份 `wg0.conf`，保留其中的 `[Peer]` 并顺手清理非法的空 `[Peer]` 块。

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
- 客户端名: iphone | 内网IP: 10.0.0.2/32
- 客户端名: macbook | 内网IP: 10.0.0.3/32
==================================================
```

### wg-remove —— 删除设备

```bash
sudo wg-remove macbook      # 直接删除（推荐）
sudo wg-remove              # 交互式删除，需二次确认
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

执行流程：备份 `/etc/wireguard` → 停止并禁用 `wg-quick@wg0` → 清理 iptables 规则 → 删除配置与全局命令 → 可选卸载软件包。备份默认保留在 `/root/wireguard-backup-<时间戳>.tar.gz`。

---

## 客户端配置说明

生成的客户端配置模板如下：

```ini
[Interface]
PrivateKey = <客户端私钥>
Address    = 10.0.0.2/32
DNS        = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey           = <服务端公钥>
Endpoint            = <服务器公网IP>:51820
AllowedIPs          = 0.0.0.0/0
PersistentKeepalive = 25
```

| 字段 | 说明 |
| --- | --- |
| `Address` | 客户端内网地址，由脚本自动分配 |
| `DNS` | 默认 `1.1.1.1, 8.8.8.8`，可用 `WG_DNS` 覆盖 |
| `AllowedIPs = 0.0.0.0/0` | 全局代理，所有流量走 VPN |
| `PersistentKeepalive = 25` | 维持 NAT 映射，防止长时间空闲掉线 |

### 如何导入

- **手机 / 平板**：打开 WireGuard App → 新建隧道 → 扫描终端二维码。
- **电脑**：忽略二维码，从服务器拉取配置文件后在客户端导入：

```bash
scp root@<服务器IP>:/etc/wireguard/clients/<设备名>.conf ./
```

仅在需要访问内网、不需要全局代理时，可把 `AllowedIPs` 改为具体网段，例如 `AllowedIPs = 10.0.0.0/24`。

---

## 常见问题与排查

> 💡 **网络不通时，第一步先运行 `sudo wg-doctor`**，它会把下面排查所需的信息一次性打印并保存到 `/tmp/wg-doctor-*.log`，结尾还会给出问题清单。

### 1. 客户端已导入，但完全无法访问网络

**先确认隧道是否握手成功**：

```bash
sudo wg show          # 服务器端
```

客户端 `latest handshake` 是否刷新、`transfer` 是否有收发。若没有握手，问题在连接层：

- **云安全组 / 防火墙未放行 `51820/UDP`**（最常见原因）。
- 服务器公网 IP 填写错误，检查客户端配置里的 `Endpoint`。
- 服务器启用了 `ufw`：脚本会自动 `ufw allow 51820/udp`，可手动复核 `sudo ufw status`。

### 2. 能握手、能 ping 通 `10.0.0.1`，但打不开网页（回程被丢）

说明去程正常、**回程被 FORWARD 丢弃**，常见于安装 Docker 或启用 ufw 的机器。检查并补齐双方向规则：

```bash
# 把 eth0 换成默认网卡（ip route show default 查看）
sudo iptables -C FORWARD -i wg0 -j ACCEPT 2>/dev/null || sudo iptables -I FORWARD 1 -i wg0 -j ACCEPT
sudo iptables -C FORWARD -o wg0 -j ACCEPT 2>/dev/null || sudo iptables -I FORWARD 1 -o wg0 -j ACCEPT

# 确认 NAT 规则存在
sudo iptables -t nat -L POSTROUTING -n -v | grep MASQUERADE
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

默认 DNS 在某些网络不可达。用国内 DNS 重新生成配置：

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

若曾用旧版本脚本删除过设备，可能残留了非法的空 `[Peer]`。清理方法：

```bash
sudo cp /etc/wireguard/wg0.conf /etc/wireguard/wg0.conf.bak
sudo awk 'BEGIN{RS="";ORS="\n\n"} !(/\[Peer\]/ && !/PublicKey/)' \
     /etc/wireguard/wg0.conf > /tmp/wg0.fixed && sudo mv /tmp/wg0.fixed /etc/wireguard/wg0.conf
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

# 可选：清理 iptables 规则（把 eth0 换成默认网卡）
sudo iptables -D FORWARD -i wg0 -j ACCEPT
sudo iptables -D FORWARD -o wg0 -j ACCEPT
sudo iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

# 可选：卸载软件包
sudo apt-get remove --purge -y wireguard
```

</details>

---

## 安全建议

- `wg0.conf` 与客户端 `.conf` 含私钥，脚本已设置 `600` 权限，请勿泄露。
- 仅放行必要的 `51820/UDP`，不要额外暴露管理端口。
- 定期用 `wg-list` / `wg show` 审计设备，及时 `wg-remove` 吊销闲置或丢失的设备。

---

## License

本项目未声明许可证，使用前请遵循仓库所有者（[@messi1991](https://github.com/messi1991)）的意愿。
