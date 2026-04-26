# 发布前 Smoke Test

本文用于在真实 Linux VPS 上发布前验收 `Xray-OneClick`。建议使用一台可重装的测试 VPS 执行，避免影响生产配置。

## 基础安装

```bash
curl -fsSL https://raw.githubusercontent.com/ike-sh/Xray-OneClick/main/install.sh -o install.sh
chmod +x install.sh
bash install.sh
```

如果测试的是本地未提交版本，请先上传当前工作区的 `install.sh`，不要使用线上 raw 链接。

## 基础验证

```bash
ike version
ike help
ike view
ike view doctor
xray run -test -c /etc/xray/config.json
systemctl status xray --no-pager
```

预期结果：

- `ike version` 显示脚本名、脚本版本、仓库地址和当前 Xray 版本。
- `ike help` 显示菜单和直接命令入口。
- `ike view` 能快速输出当前链接和安全状态。
- `ike view doctor` 能显示资源文件、配置校验、服务状态和公网 IP。
- `xray run -test -c /etc/xray/config.json` 通过。
- `xray.service` 为运行中或能给出明确错误原因。

## 协议验证

通过 `ike` 菜单分别执行：

1. 安装 Shadowsocks 2022。
2. 安装 VLESS Encryption。
3. 安装 SOCKS5 代理。
4. 查看当前配置链接。

然后执行：

```bash
ike view
ike view doctor
xray run -test -c /etc/xray/config.json
grep -R "flow=" /etc/xray /usr/local/share/ike 2>/dev/null || true
grep -R "xtls-rprx-vision" /etc/xray /usr/local/share/ike 2>/dev/null || true
```

预期结果：

- SS2022 链接存在，端口和加密方式符合菜单输入。
- VLESS Encryption 链接存在，并包含 `type=tcp`、`security=none`、`encryption=...`。
- SOCKS5 配置存在。
- 配置校验通过。
- 不应出现 `flow=` 或 `xtls-rprx-vision`。

## 中转/端口转发验证

依次执行：

```bash
ike forward add safe
ike forward add relay
ike forward list
ike forward edit
ike forward disable
ike forward enable
ike forward test
ike forward export
ike forward import
ike forward del
xray run -test -c /etc/xray/config.json
```

建议准备两个简单目标：

- safe：公网 IP 或域名的 TCP 端口。
- relay：可信固定目标，确认理解该模式会为单条 forward inbound 添加 `inboundTag -> direct` 专用路由。

预期结果：

- `safe` 规则写入 `dokodemo-door` inbound，不新增 direct 放行规则。
- `relay` 规则写入 `dokodemo-door` inbound，并为该 tag 添加 direct 放行规则。
- `list` 能显示启用/停用状态、模式和备注。
- `edit` 修改后配置校验通过。
- `disable` 后对应 inbound 消失，但 state 保留。
- `enable` 后对应 inbound 恢复。
- `test` 能显示目标解析、TCP 连通性或明确跳过原因。
- `export` 生成 `/root/xray-forwards-YYYYmmddHHMMSS.json`。
- `import` 不覆盖非 forward 入站；tag 冲突时按选择处理。
- `del` 不误删 SS2022 / VLESS Encryption / SOCKS5。

## 安全规则验证

```bash
ike view doctor
ike safety enhanced on
ike view
ike safety enhanced off
ike cnblock basic
ike view
ike cnblock enhanced
ike view doctor
ike cnblock off
xray run -test -c /etc/xray/config.json
```

预期结果：

- 默认安全屏蔽始终显示已启用。
- 默认私网规则显示 `geoip:private` 或 `CIDR fallback`。
- 增强安全屏蔽可开启和关闭。
- 中国大陆直连屏蔽可在基础模式、增强模式、关闭之间切换。
- 缺少 `geosite.dat` 时，增强模式应给出明确错误，不影响基础模式。
- 配置校验通过。

## 卸载验证

通过 `ike` 菜单进入卸载/清理：

1. 删除单个协议入站。
2. 删除 forward 规则。
3. 完整卸载 Xray。

验证命令：

```bash
ike view || true
systemctl status xray --no-pager || true
ls -la /etc/xray /usr/local/share/ike /usr/local/bin/ike /usr/local/bin/sb 2>/dev/null || true
```

预期结果：

- 删除单协议不会误删其它协议。
- 删除 forward 不会误删 SS2022 / VLESS Encryption / SOCKS5。
- 完整卸载后，Xray 服务、配置目录、安装器脚本和快捷命令按菜单说明被清理。
