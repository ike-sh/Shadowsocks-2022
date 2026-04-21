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
- **systemd 管理**：生成 `/etc/systemd/system/xray.service`，配置校验通过后重启服务。

## 快速开始

### 本地未提交版本测试

如果当前代码还只是本地修改，尚未确认提交并推送到 GitHub `main` 分支，请不要使用 `raw.githubusercontent.com` 测试，否则可能拉到线上旧版本脚本。

先从本机上传当前工作区里的 `install.sh`：

```bash
scp ./install.sh root@YOUR_SERVER_IP:/root/install.sh
```

然后在 Linux VPS 上执行：

```bash
ssh root@YOUR_SERVER_IP
chmod +x /root/install.sh
bash /root/install.sh
```

Alpine 系统可先安装基础依赖：

```bash
apk update && apk add bash curl
bash /root/install.sh
```

### 已提交到 GitHub 后一键安装

只有确认当前代码已经提交并推送到 GitHub `main` 分支后，才推荐使用线上安装命令：

```bash
curl -fsSL https://raw.githubusercontent.com/ike-sh/Shadowsocks-2022/refs/heads/main/install.sh -o install.sh && bash install.sh
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
ike update
```

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
10. 退出

## 支持协议

### Shadowsocks 2022

脚本会生成 Xray `shadowsocks` 入站。默认监听 IPv4；选择 IPv6 + SS2022 时会先检测系统 IPv6 状态，再生成 IPv6 监听配置。

支持方法：

- `2022-blake3-aes-128-gcm`
- `2022-blake3-aes-256-gcm`
- `2022-blake3-chacha20-poly1305`

### VLESS Encryption

脚本会生成 Xray `vless` 入站，并通过 `xray vlessenc` 生成匹配的服务端 `decryption` 和客户端 `encryption`。

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

`installer-state.json` 用于保存 VLESS Encryption 的客户端 `encryption` 字段。Xray 服务端配置只需要 `decryption`，但生成分享链接时需要客户端字段，所以该状态文件应像配置文件一样保护。

## 卸载与清理

执行 `ike` 后进入 `9) 卸载/清理` 子菜单，可删除单项协议配置、卸载全部 Xray 实现，或清理旧版 sing-box 残留。

旧 sing-box 清理只面向迁移前遗留内容，包括：

- `/etc/sing-box`
- `/usr/local/bin/sing-box`
- `sing-box.service` 或 OpenRC 服务

清理前脚本会再次询问确认。

## 免责声明

本脚本仅供学习交流与网络技术研究使用。请勿用于任何违反当地法律法规的用途。使用本脚本产生的任何后果由使用者自行承担。
