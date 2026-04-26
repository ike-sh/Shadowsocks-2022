# Xray 多协议一键安装脚本

> 基于 **Xray-core** 的菜单式个人服务器安装脚本，支持 **Shadowsocks 2022**、**VLESS Encryption** 和可选 **SOCKS5**。

![Core](https://img.shields.io/badge/Core-Xray-blue)
![License](https://img.shields.io/badge/License-GPLv3-orange)

## 适合谁使用

本项目适合个人 Linux VPS 快速部署、测试和维护 Xray 多协议节点，尤其适合需要菜单式操作、轻量 systemd 管理和少量节点配置的场景。

它不适合复杂中转、面板化运维、多节点编排、细粒度用户管理等重场景；这类需求建议使用专门的面板或自行维护 Xray 配置。

## 功能概览

- **默认核心为 Xray**：通过 GitHub Releases API 获取 `XTLS/Xray-core` 最新版本，并按服务器架构下载 Linux zip 包。
- **Shadowsocks 2022**：支持 `2022-blake3-aes-128-gcm`、`2022-blake3-aes-256-gcm`、`2022-blake3-chacha20-poly1305`。
- **VLESS Encryption**：调用 `xray vlessenc` 生成服务端 `decryption` 和客户端 `encryption`，支持基础模式和高级模式。
- **可选 SOCKS5**：适合临时代理或内网测试。
- **菜单式维护**：支持安装/更新核心、安装协议、查看链接、切换链接显示模式、重置密钥、卸载和清理。
- **默认安全屏蔽**：默认阻断 BT/PT、私网地址、SMTP、SMB/NetBIOS 等高风险目标。
- **可选中国大陆直连屏蔽**：可在服务端通过 Xray routing 阻断发往 `geoip:cn` / `geosite:cn` 的流量。
- **systemd 管理**：生成 `/etc/systemd/system/xray.service`，配置校验通过后重启服务。

## 快速开始

Alpine 系统可先安装基础依赖：

```bash
apk update && apk add bash curl
```

### 一键安装

推荐使用线上安装命令：

```bash
curl -fsSL https://raw.githubusercontent.com/ike-sh/Shadowsocks-2022/main/install.sh -o install.sh && bash install.sh
```

## 快捷命令

安装完成后使用 `ike` 进入菜单：

```bash
ike
```

常用直接命令：

```bash
ike view
ike view ipv4
ike view ipv6
ike view doctor
ike update
ike backup
ike cnblock
ike cnblock basic
ike cnblock enhanced
ike cnblock off
ike safety enhanced on
ike safety enhanced off
```

`ike view` 是快速模式，主要用于查看节点链接、安全屏蔽状态和最近变更；`ike view doctor` 会额外执行公网 IP 探测、Xray 配置校验和服务状态检查。直接命令执行完会返回 shell，不进入菜单。

命令用途区分：

- `ike`：安装器和菜单命令，用于安装、查看、重置、卸载和维护配置。
- `xray`：Xray-core 二进制本体，用于 `xray version`、`xray vlessenc`、`xray run -test` 等核心命令。
- `sb`：旧版兼容入口，只提示命令已更名为 `ike` 并转发，不推荐继续使用。

## 菜单功能

1. 安装/更新 Xray 核心
2. 安装 Shadowsocks 2022
3. 安装 IPv6 + Shadowsocks 2022
4. 安装 VLESS Encryption
5. 安装 SOCKS5 代理
6. 查看当前配置链接
7. 设置链接显示模式
8. 重置密钥/密码
9. 卸载/清理
10. 开启/关闭中国大陆直连屏蔽
11. 开启/关闭增强安全屏蔽
12. 导出当前配置备份
13. 退出

## 支持协议

### Shadowsocks 2022

脚本会生成 Xray `shadowsocks` 入站。默认监听 IPv4；选择 IPv6 + SS2022 时会先检测系统 IPv6 状态，再生成 IPv6 监听配置。

支持方法：

- `2022-blake3-aes-128-gcm`
- `2022-blake3-aes-256-gcm`
- `2022-blake3-chacha20-poly1305`

### VLESS Encryption

脚本会生成 Xray `vless` 入站，并通过 `xray vlessenc` 生成匹配的服务端 `decryption` 和客户端 `encryption`。

当前脚本面向专线落地场景，VLESS Encryption 默认使用 `tcp` + `security=none`，不写入 `flow`，也不使用 `xtls-rprx-vision`。生成的分享链接只包含 `type=tcp`、`security=none` 和 `encryption` 等必要参数。

基础模式适合大多数用户，保留最少交互：

- 认证方式：`X25519` 或 `ML-KEM-768`
- 外观混淆：`native`
- 客户端握手：`0rtt`
- 服务端 ticket 有效期：`600s`

高级模式会开放当前脚本已经实现的 VLESS Encryption 字符串选项：

- 外观混淆：`native` / `xorpub` / `random`
- 客户端握手：`0rtt` / `1rtt`
- 服务端 ticket 有效期：`600s` / `300s` / 自定义，如 `100-500s` 或 `900s`
- 认证方式：`X25519` / `ML-KEM-768`

注意事项：

- 当前 `xray vlessenc` 命令本身不提供可直接指定这些选项的命令行参数；脚本会先生成匹配参数，再按 VLESS Encryption 字符串结构同步重写服务端和客户端字段。
- 高级模式下，尤其选择 `ML-KEM-768` 时，生成的 `encryption` 和 `vless://` 分享链接可能非常长。部分客户端兼容性可能较差，必要时需要手动填写参数。
- reverse、relay、多级 relay 等协议层能力当前脚本暂未开放，避免误导用户以为已经完整支持；需要这些能力时请手动维护 Xray 配置。

### SOCKS5

SOCKS5 为可选入站，适合临时代理、内网访问或简单连通性测试。是否允许认证、监听地址和端口以脚本交互为准。

## 默认安全屏蔽

脚本会默认写入一组服务端防滥用基线规则，适合大多数个人 VPS 场景。该规则不需要手动开启，新安装协议、更新核心、重置配置或应用 routing 设置时都会自动补齐。

默认会补齐 `BLOCK` 出站：

```json
{ "tag": "BLOCK", "protocol": "blackhole" }
```

并在 `routing.rules` 前部加入：

```json
{ "type": "field", "protocol": ["bittorrent"], "outboundTag": "BLOCK" }
{ "type": "field", "ip": ["geoip:private"], "outboundTag": "BLOCK" }
{ "type": "field", "port": "25,135,137,138,139,445,465,587", "outboundTag": "BLOCK" }
```

这些规则用于阻断 BT/PT 流量、访问私网地址、SMTP 发信滥用，以及 Windows / NetBIOS / SMB 相关高风险端口。默认规则只移除和重建脚本自己生成的精确规则，不会删除用户已有自定义 routing。

如果 `/usr/local/share/xray/geoip.dat` 存在，私网阻断使用 `geoip:private`；如果该资源不存在，脚本会自动退化为 CIDR fallback，不会因此中断协议安装或配置应用。fallback 会阻断：

```text
127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16,
169.254.0.0/16, 100.64.0.0/10, ::1/128, fc00::/7, fe80::/10
```

菜单中的 `11) 开启/关闭增强安全屏蔽` 可额外阻断：

```text
69,161,162,389,636,1900,5353,5355,11211
```

增强模式默认关闭，因为这些端口可能影响少量 DNS-SD/mDNS、LDAP、SNMP、TFTP、Memcached 或内网发现类场景。需要更严格出口限制时再开启。

`ike view` 会显示“默认安全屏蔽”“默认私网规则”和“增强安全屏蔽”的当前状态。也可以直接使用 `ike safety enhanced on` 或 `ike safety enhanced off` 开启/关闭增强安全屏蔽。

## 可选路由：屏蔽中国大陆直连

菜单中的 `10) 开启/关闭中国大陆直连屏蔽` 用于控制服务端是否阻断发往中国大陆的直连流量。该功能适合专线落地、出口限制、避免节点访问中国大陆站点或 IP 的场景。

开启后，脚本会补齐 `BLOCK` 出站：

```json
{ "tag": "BLOCK", "protocol": "blackhole" }
```

该功能分为两档：

- 基础模式：只阻断 `geoip:cn` IP，依赖 `geoip.dat`。
- 增强模式：在基础模式之外额外阻断 `geosite:cn` 域名，依赖 `geoip.dat` 和 `geosite.dat`。

对应规则为：

```json
{ "type": "field", "ip": ["geoip:cn"], "outboundTag": "BLOCK" }
{ "type": "field", "domain": ["geosite:cn"], "outboundTag": "BLOCK" }
```

关闭时只移除上述中国大陆屏蔽规则，不删除已有的 private、BT、端口屏蔽等其它 routing 规则。开启后，使用这些入站协议的客户端将无法访问匹配规则的站点或 IP。缺少 `geosite.dat` 时不能启用增强模式，但仍可使用基础模式；缺少 `geoip.dat` 时请先执行 `ike update` 或菜单中的 `1) 安装/更新 Xray 核心`。

`ike view` 会显示中国大陆直连屏蔽状态：`未启用`、`基础模式` 或 `增强模式`。也可以直接使用 `ike cnblock basic`、`ike cnblock enhanced`、`ike cnblock off` 设置，或用 `ike cnblock` 查看当前状态。

## 诊断与备份

`ike view` 默认使用快速模式，显示节点链接、默认安全屏蔽、增强安全屏蔽、中国大陆直连屏蔽、默认私网规则模式，以及 `installer-state.json` 中记录的最近变更和最近更新时间。快速模式不会主动执行 `xray run -test -c`、服务状态检查或公网 IP 探测。

需要排障时使用：

```bash
ike view doctor
```

诊断模式会额外输出：

- `geoip.dat`: 存在 / 不存在
- `geosite.dat`: 存在 / 不存在
- `Xray 配置校验`: 通过 / 失败 / 未检测到 xray
- `Xray 服务状态`: 运行中 / 未运行 / 未检测到 systemd/openrc
- 公网 IPv4 / IPv6

菜单中的 `12) 导出当前配置备份` 或直接命令 `ike backup` 会把当前配置导出到：

```text
/root/xray-config-backup-YYYYmmddHHMMSS.json
/root/xray-state-backup-YYYYmmddHHMMSS.json
```

状态文件不存在时会跳过状态备份，不影响配置备份导出。脚本内部应用配置前仍会保留 `config.json.bak.*` 备份；如果配置校验或服务重启失败，`apply_config()` 会尝试恢复最近一次内部备份并重新校验。

## 常用验证

检查 Xray 配置是否可被核心加载：

```bash
xray run -test -c /etc/xray/config.json
```

查看服务状态：

```bash
systemctl status xray --no-pager
```

查看监听端口：

```bash
ss -tulpn | grep xray
```

查看脚本生成的节点信息：

```bash
ike view
```

## systemd 常用命令

```bash
systemctl status xray --no-pager
systemctl restart xray
systemctl stop xray
journalctl -u xray -e --no-pager
```

## 文件路径

| 用途 | 路径 |
| --- | --- |
| 配置目录 | `/etc/xray` |
| 配置文件 | `/etc/xray/config.json` |
| 安装器状态 | `/etc/xray/installer-state.json` |
| Xray 二进制 | `/usr/local/bin/xray` |
| Xray 资源目录 | `/usr/local/share/xray` |
| 安装器副本 | `/usr/local/share/ike/install.sh` |
| systemd 服务 | `/etc/systemd/system/xray.service` |
| 主快捷命令 | `/usr/local/bin/ike` |
| 兼容快捷命令 | `/usr/local/bin/sb` |

`installer-state.json` 用于保存 VLESS Encryption 的客户端 `encryption` 字段，以及 `meta.last_action`、`meta.last_updated_at` 等最近变更信息。Xray 服务端配置只需要 `decryption`，但生成分享链接时需要客户端字段，所以该状态文件应像配置文件一样保护。

## 卸载与清理

执行 `ike` 后进入 `9) 卸载/清理` 子菜单，可删除单项协议配置、卸载全部 Xray 实现，或清理旧版 sing-box 残留。

旧 sing-box 清理只面向迁移前遗留内容，包括：

- `/etc/sing-box`
- `/usr/local/bin/sing-box`
- `sing-box.service` 或 OpenRC 服务

清理前脚本会再次询问确认。

## 免责声明

本脚本仅供学习交流与网络技术研究使用。请勿用于任何违反当地法律法规的用途。使用本脚本产生的任何后果由使用者自行承担。
