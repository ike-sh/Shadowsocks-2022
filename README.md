# 🚀 Shadowsocks-2022 一键安装脚本

> 支持 **SS2022**、**SS2022 + ShadowTLS**、**IPv6 + SS2022**、**SOCKS5** 的交互式安装脚本（基于 sing-box）。

![Build Status](https://img.shields.io/badge/Build-Passing-brightgreen)
![Version](https://img.shields.io/badge/Version-v6.4-blue)
![License](https://img.shields.io/badge/License-GPLv3-orange)

## ✨ 核心特性

- **自动获取最新 sing-box**：安装时通过 GitHub Releases API 获取最新稳定版本并下载对应架构包（amd64/arm64）。
- **交互式菜单**：按需安装 SS2022 / ShadowTLS / IPv6+SS2022 / SOCKS5，并支持密码重置与链接显示模式切换。
- **IPv6 自动检查**：安装 IPv6+SS2022 前自动检测：
  - 系统是否开启 IPv6（`net.ipv6.conf.all.disable_ipv6=0`）
  - 是否存在全局 IPv6 地址
- **双栈链接展示**：查看配置时可输出双栈或仅 IPv4/仅 IPv6 链接，IPv6 自动加 `[]`。
- **SOCKS5 UDP 已启用**：生成的 socks 入站默认开启 `udp: true`。
- **兼容新版 sing-box 配置**：移除了 SS 入站 `multiplex` 字段，避免新版本中兼容性波动。
- **配置与服务安全增强**：
  - `/etc/sing-box` 权限 `700`，`config.json` 权限 `600`
  - 写入后自动 `jq` + `sing-box check`
  - systemd 启用 `NoNewPrivileges` / `PrivateTmp` / `ProtectSystem` / `ProtectHome`

## 📥 安装命令

请使用 root 用户执行：

```bash
bash <(curl -sL https://raw.githubusercontent.com/ike-sh/Shadowsocks-2022/refs/heads/main/install.sh)
```

Alpine 可先补齐基础依赖：

```bash
if [ -f /etc/alpine-release ]; then apk update && apk add bash curl; fi && bash <(curl -sL https://raw.githubusercontent.com/ike-sh/Shadowsocks-2022/refs/heads/main/install.sh)
```

## 🛠️ 功能菜单

1. 安装 Shadowsocks 2022
2. 安装 Shadowsocks 2022 + ShadowTLS
3. 安装 IPv6 + Shadowsocks 2022（自动检查 IPv6）
4. 安装 SOCKS5 代理（UDP 默认开启）
5. 查看当前配置链接
6. 设置链接显示模式（双栈 / 仅 IPv4 / 仅 IPv6）
7. 重置密码（端口不变）
8. 卸载服务
9. 退出

## ⚡ 快捷命令

```bash
sb
sb view
sb view ipv4
sb view ipv6
```

## 🔐 维护与兼容建议

- 端口输入会进行 `1-65535` 校验，并提示常见业务端口风险。
- 可通过菜单第 7 项快速重置 SS/ShadowTLS/SOCKS5 密码，不改端口。
- 若 GitHub API 在当前网络不可达，可稍后重试或自行下载 sing-box 后放置到 `/usr/local/bin/sing-box`。

## 📂 文件路径与管理

- 配置目录：`/etc/sing-box`
- 配置文件：`/etc/sing-box/config.json`
- 二进制：`/usr/local/bin/sing-box`
- 快捷命令：`/usr/local/bin/sb`

systemd 常用命令：

```bash
systemctl status sing-box
systemctl restart sing-box
systemctl stop sing-box
```

## ⚖️ 免责声明

本脚本仅供学习交流与网络技术研究使用。请勿用于任何违反当地法律法规的用途。使用本脚本产生的任何后果由使用者自行承担。
