#!/bin/bash

set -o pipefail

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

SERVICE_NAME="xray"
CONFIG_DIR="/etc/xray"
CONFIG_FILE="${CONFIG_DIR}/config.json"
STATE_FILE="${CONFIG_DIR}/installer-state.json"
ASSET_DIR="/usr/local/share/xray"
BIN_PATH="/usr/local/bin/xray"
SHORTCUT_PATH="/usr/local/bin/ike"
LEGACY_SHORTCUT_PATH="/usr/local/bin/sb"
INSTALLER_DIR="/usr/local/share/ike"
INSTALLER_PATH="${INSTALLER_DIR}/install.sh"
RAW_SCRIPT_URL="https://raw.githubusercontent.com/ike-sh/Shadowsocks-2022/main/install.sh"
XRAY_RELEASE_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"

SS_TAG="ss2022-in"
VLESS_TAG="vless-enc-in"
SOCKS_TAG="socks-in"
BLOCK_OUTBOUND_TAG="BLOCK"
DEFAULT_SAFETY_BLOCK_PORTS="25,135,137,138,139,445,465,587"
ENHANCED_SAFETY_BLOCK_PORTS="69,161,162,389,636,1900,5353,5355,11211"

LINK_VIEW_MODE="dual"
OS_TYPE=""
INIT_SYSTEM=""
ARCH=""
XRAY_ASSET=""

info() { echo -e "${YELLOW}$*${PLAIN}"; }
ok() { echo -e "${GREEN}$*${PLAIN}"; }
err() { echo -e "${RED}$*${PLAIN}"; }

die() {
    err "$*"
    exit 1
}

ensure_root() {
    [[ $EUID -eq 0 ]] || die "错误：必须使用 root 用户运行。"
}

check_os() {
    if [[ -f /etc/alpine-release ]]; then
        OS_TYPE="alpine"
        INIT_SYSTEM="openrc"
    elif [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_TYPE="${ID:-linux}"
        if command -v systemctl >/dev/null 2>&1; then
            INIT_SYSTEM="systemd"
        else
            INIT_SYSTEM="unknown"
        fi
    else
        die "无法识别系统类型。"
    fi
}

detect_arch() {
    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64|amd64) XRAY_ASSET="Xray-linux-64.zip" ;;
        i386|i686) XRAY_ASSET="Xray-linux-32.zip" ;;
        aarch64|arm64) XRAY_ASSET="Xray-linux-arm64-v8a.zip" ;;
        armv7l|armv7*) XRAY_ASSET="Xray-linux-arm32-v7a.zip" ;;
        armv6l|armv6*) XRAY_ASSET="Xray-linux-arm32-v6.zip" ;;
        armv5l|armv5*) XRAY_ASSET="Xray-linux-arm32-v5.zip" ;;
        riscv64) XRAY_ASSET="Xray-linux-riscv64.zip" ;;
        s390x) XRAY_ASSET="Xray-linux-s390x.zip" ;;
        ppc64le) XRAY_ASSET="Xray-linux-ppc64le.zip" ;;
        ppc64) XRAY_ASSET="Xray-linux-ppc64.zip" ;;
        loongarch64|loong64) XRAY_ASSET="Xray-linux-loong64.zip" ;;
        *) die "不支持的架构: $ARCH" ;;
    esac
}

install_shortcut() {
    local script_source
    script_source="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"

    mkdir -p "$(dirname "$SHORTCUT_PATH")" "$INSTALLER_DIR"

    if [[ -f "$script_source" && -r "$script_source" ]]; then
        if [[ "$script_source" != "$INSTALLER_PATH" ]]; then
            cp "$script_source" "$INSTALLER_PATH"
        fi
        chmod +x "$INSTALLER_PATH"
    elif [[ ! -f "$INSTALLER_PATH" ]]; then
        cat > "$INSTALLER_PATH" <<EOF
#!/bin/bash
SCRIPT_URL="${RAW_SCRIPT_URL}"
TMP_SCRIPT="\$(mktemp)"
trap 'rm -f "\$TMP_SCRIPT"' EXIT
curl -fsSL "\$SCRIPT_URL" -o "\$TMP_SCRIPT" || exit 1
bash "\$TMP_SCRIPT" "\$@"
EOF
        chmod +x "$INSTALLER_PATH"
    fi

    cat > "$SHORTCUT_PATH" <<EOF
#!/bin/bash
if [[ ! -f "$INSTALLER_PATH" ]]; then
    echo "未找到安装器脚本 $INSTALLER_PATH，请重新上传 install.sh 并执行安装。" >&2
    exit 1
fi
exec bash "$INSTALLER_PATH" "\$@"
EOF
    chmod +x "$SHORTCUT_PATH"

    cat > "$LEGACY_SHORTCUT_PATH" <<EOF
#!/bin/bash
echo "提示：快捷命令已更名为 ike，sb 仅作为兼容入口，将转发到 ike。" >&2
if [[ ! -x "$SHORTCUT_PATH" ]]; then
    echo "未找到主快捷命令 $SHORTCUT_PATH，请重新上传 install.sh 并执行安装。" >&2
    exit 1
fi
exec "$SHORTCUT_PATH" "\$@"
EOF
    chmod +x "$LEGACY_SHORTCUT_PATH"
}

install_dependencies() {
    local missing=()
    local tool

    for tool in bash curl wget jq unzip openssl; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done

    [[ ${#missing[@]} -eq 0 ]] && return 0

    info "[系统] 补全依赖: ${missing[*]}"

    case "$OS_TYPE" in
        alpine)
            apk update
            apk add bash curl wget unzip openssl ca-certificates jq coreutils iproute2 procps net-tools
            ;;
        ubuntu|debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y bash curl wget unzip openssl ca-certificates jq coreutils iproute2 procps
            ;;
        centos|rhel|rocky|almalinux|fedora)
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y bash curl wget unzip openssl ca-certificates jq coreutils iproute procps-ng
            else
                yum install -y epel-release >/dev/null 2>&1 || true
                yum install -y bash curl wget unzip openssl ca-certificates jq coreutils iproute procps-ng
            fi
            ;;
        *)
            err "[系统] 未识别的发行版: $OS_TYPE"
            err "请先手动安装: bash curl wget jq unzip openssl ca-certificates"
            return 1
            ;;
    esac
}

enable_bbr() {
    [[ "$OS_TYPE" == "alpine" ]] && return 0
    command -v sysctl >/dev/null 2>&1 || return 0

    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]; then
        return 0
    fi

    info "[系统] 尝试启用 BBR..."
    cat > /etc/sysctl.d/99-xray-installer-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-xray-installer-bbr.conf >/dev/null 2>&1 || true
}

prepare_system() {
    info "[系统] 环境: $OS_TYPE ($INIT_SYSTEM) / 架构: $ARCH / 核心: Xray"
    install_dependencies || return 1
    install_shortcut
    enable_bbr
}

ensure_config_security() {
    mkdir -p "$CONFIG_DIR" "$ASSET_DIR"
    chmod 700 "$CONFIG_DIR"
    [[ -f "$CONFIG_FILE" ]] && chmod 600 "$CONFIG_FILE"
    [[ -f "$STATE_FILE" ]] && chmod 600 "$STATE_FILE"
    chown root:root "$CONFIG_DIR" "$CONFIG_FILE" "$STATE_FILE" 2>/dev/null || true
}

init_config() {
    mkdir -p "$CONFIG_DIR"

    if [[ -f "$CONFIG_FILE" ]] && ! jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
        local broken
        broken="${CONFIG_FILE}.broken.$(date +%Y%m%d%H%M%S)"
        mv "$CONFIG_FILE" "$broken"
        err "[配置] 发现无效 JSON，已备份到: $broken"
    fi

    if [[ ! -f "$CONFIG_FILE" ]]; then
        cat > "$CONFIG_FILE" <<'JSON'
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    }
  ]
}
JSON
    fi

    local tmp
    tmp="$(mktemp)"
    jq '
      .log //= {"loglevel":"warning"} |
      .inbounds //= [] |
      .outbounds //= [{"tag":"direct","protocol":"freedom"}]
    ' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
    rm -f "$tmp"
    ensure_default_safety_blocks || return 1
    ensure_config_security
}

init_state() {
    mkdir -p "$CONFIG_DIR"
    [[ -f "$STATE_FILE" ]] || echo '{}' > "$STATE_FILE"
    if ! jq empty "$STATE_FILE" >/dev/null 2>&1; then
        mv "$STATE_FILE" "${STATE_FILE}.broken.$(date +%Y%m%d%H%M%S)"
        echo '{}' > "$STATE_FILE"
    fi

    local tmp
    tmp="$(mktemp)"
    jq '
      (if (.vless_encryption? | type) == "object" then
        .vless_encryption |= del(.flow)
      else
        .
      end) |
      .meta = (.meta // {})
    ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
    rm -f "$tmp"

    ensure_config_security
}

state_set_meta_action() {
    local action="$1"
    local timestamp tmp

    [[ -n "$action" ]] || return 0
    command -v jq >/dev/null 2>&1 || {
        err "[失败] [状态] 缺少 jq，无法更新最近变更。"
        return 1
    }
    init_state
    timestamp="$(date '+%Y-%m-%d %H:%M:%S %z')"
    tmp="$(mktemp)" || {
        err "[失败] [状态] 创建临时文件失败。"
        return 1
    }

    if ! jq --arg action "$action" --arg updated_at "$timestamp" '
      .meta = ((.meta // {}) + {
        "last_action": $action,
        "last_updated_at": $updated_at
      })
    ' "$STATE_FILE" > "$tmp"; then
        rm -f "$tmp"
        err "[失败] [状态] 更新 installer-state.json 失败。"
        return 1
    fi

    if ! mv "$tmp" "$STATE_FILE"; then
        rm -f "$tmp"
        err "[失败] [状态] 写入 installer-state.json 失败。"
        return 1
    fi
    ensure_config_security
}

state_meta_value() {
    local key="$1"
    local fallback="${2:-无}"

    [[ -f "$STATE_FILE" ]] || {
        printf '%s' "$fallback"
        return 0
    }
    jq -r --arg key "$key" --arg fallback "$fallback" '.meta[$key] // $fallback' "$STATE_FILE" 2>/dev/null
}

backup_config() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    cp -a "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
}

restore_latest_config_backup() {
    local latest_backup

    latest_backup="$(ls -t "${CONFIG_FILE}.bak."* 2>/dev/null | head -n 1 || true)"
    if [[ -z "$latest_backup" || ! -f "$latest_backup" ]]; then
        err "[回滚] 未找到可恢复的配置备份: ${CONFIG_FILE}.bak.*"
        return 1
    fi

    info "[回滚] 正在恢复最近备份: $latest_backup"
    if ! cp -a "$latest_backup" "$CONFIG_FILE"; then
        err "[回滚] 恢复配置文件失败。"
        return 1
    fi
    ensure_config_security

    if ! validate_config_file; then
        err "[回滚] 恢复失败：备份配置校验未通过。"
        return 1
    fi

    ok "[回滚] 恢复成功，备份配置校验通过。"
}

export_current_config_backup() {
    local timestamp config_backup state_backup

    [[ -f "$CONFIG_FILE" ]] || {
        err "[失败] 未找到配置文件: $CONFIG_FILE"
        return 1
    }

    timestamp="$(date +%Y%m%d%H%M%S)"
    config_backup="/root/xray-config-backup-${timestamp}.json"
    state_backup="/root/xray-state-backup-${timestamp}.json"

    if ! cp -a "$CONFIG_FILE" "$config_backup"; then
        err "[失败] 导出配置备份失败: $config_backup"
        return 1
    fi
    chmod 600 "$config_backup" 2>/dev/null || true

    ok "[备份] config.json: $config_backup"

    if [[ -f "$STATE_FILE" ]]; then
        state_set_meta_action "导出配置备份" || err "[状态] 记录备份动作失败，配置备份已继续导出。"
        if ! cp -a "$STATE_FILE" "$state_backup"; then
            err "[失败] 导出状态备份失败: $state_backup"
            return 1
        fi
        chmod 600 "$state_backup" 2>/dev/null || true
        ok "[备份] installer-state.json: $state_backup"
    else
        info "[备份] 未找到状态文件，已跳过: $STATE_FILE"
    fi
}

validate_config_file() {
    local log_file

    if ! jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
        err "[错误] 配置文件 JSON 无效: $CONFIG_FILE"
        return 1
    fi

    if [[ -x "$BIN_PATH" ]]; then
        log_file="$(mktemp)"
        if ! "$BIN_PATH" run -test -c "$CONFIG_FILE" >"$log_file" 2>&1; then
            err "[错误] Xray 校验配置失败:"
            cat "$log_file"
            rm -f "$log_file"
            return 1
        fi
        rm -f "$log_file"
    fi

    return 0
}

create_service() {
    mkdir -p "$ASSET_DIR" /var/log/xray

    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$ASSET_DIR
ExecStart=$BIN_PATH run -c $CONFIG_FILE
Restart=on-failure
RestartSec=10
LimitNOFILE=1048576
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=$CONFIG_DIR /var/log/xray

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        cat > "/etc/init.d/${SERVICE_NAME}" <<EOF
#!/sbin/openrc-run
name="xray"
command="$BIN_PATH"
command_args="run -c $CONFIG_FILE"
command_background=true
pidfile="/run/xray.pid"
depend() { need net; }
EOF
        chmod +x "/etc/init.d/${SERVICE_NAME}"
        rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 || true
    else
        err "[服务] 未检测到 systemd/openrc，已跳过服务文件写入。"
        return 1
    fi
}

restart_service() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl restart "$SERVICE_NAME"
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service "$SERVICE_NAME" restart
    else
        err "[服务] 无法自动重启，请手动运行: $BIN_PATH run -c $CONFIG_FILE"
        return 1
    fi
}

stop_service() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
    fi
}

stop_service_for_update() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        info "[服务] 停止 ${SERVICE_NAME}.service 以替换 Xray 核心..."
        if ! systemctl stop "$SERVICE_NAME"; then
            err "[服务] 停止 ${SERVICE_NAME}.service 失败，已中止更新。"
            return 1
        fi
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        info "[服务] 停止 ${SERVICE_NAME} 以替换 Xray 核心..."
        if ! rc-service "$SERVICE_NAME" stop; then
            err "[服务] 停止 ${SERVICE_NAME} 失败，已中止更新。"
            return 1
        fi
    else
        err "[服务] 未检测到 systemd/openrc，无法安全停止服务，已中止更新。"
        return 1
    fi
}

replace_xray_binary() {
    local new_binary="$1"
    local backup_path=""
    local staging_path

    staging_path="${BIN_PATH}.new.$$"

    if ! install -m 755 "$new_binary" "$staging_path"; then
        rm -f "$staging_path"
        err "[核心] 写入临时二进制失败: $staging_path"
        return 1
    fi

    if [[ -e "$BIN_PATH" ]]; then
        backup_path="${BIN_PATH}.bak.$(date +%Y%m%d%H%M%S)"
        if ! mv "$BIN_PATH" "$backup_path"; then
            rm -f "$staging_path"
            err "[核心] 备份旧 Xray 二进制失败，已中止更新。"
            return 1
        fi
    fi

    if ! mv "$staging_path" "$BIN_PATH"; then
        rm -f "$staging_path"
        if [[ -n "$backup_path" && -e "$backup_path" ]]; then
            mv "$backup_path" "$BIN_PATH" >/dev/null 2>&1 || true
        fi
        err "[核心] 替换 $BIN_PATH 失败，已中止更新。"
        return 1
    fi

    chmod +x "$BIN_PATH" || {
        err "[核心] 设置 $BIN_PATH 可执行权限失败。"
        return 1
    }
}

apply_config() {
    local context="${1:-}"

    ensure_default_safety_blocks || return 1
    ensure_config_security
    [[ -n "$context" ]] && info "[${context}] 正在校验 Xray 配置..."
    if ! validate_config_file; then
        [[ -n "$context" ]] && err "[失败] [${context}] Xray 配置校验失败。"
        err "[回滚] 已检测到配置应用失败，正在恢复最近备份。"
        if restore_latest_config_backup; then
            info "[回滚] 正在重启服务以加载恢复后的配置..."
            if restart_service; then
                ok "[回滚] 恢复成功，服务已重新加载最近备份。"
            else
                err "[回滚] 恢复后的配置校验通过，但服务重启失败。"
            fi
        else
            err "[回滚] 恢复失败，请手动检查 $CONFIG_FILE 和 ${CONFIG_FILE}.bak.*。"
        fi
        return 1
    fi

    [[ -n "$context" ]] && info "[${context}] 正在重启服务..."
    if ! restart_service; then
        [[ -n "$context" ]] && err "[失败] [${context}] 服务重启失败。"
        err "[回滚] 已检测到配置应用失败，正在恢复最近备份。"
        if restore_latest_config_backup; then
            info "[回滚] 正在重启服务以加载恢复后的配置..."
            if restart_service; then
                ok "[回滚] 恢复成功，服务已重新加载最近备份。"
            else
                err "[回滚] 恢复后的配置校验通过，但服务重启仍失败。"
            fi
        else
            err "[回滚] 恢复失败，请手动检查 $CONFIG_FILE 和 ${CONFIG_FILE}.bak.*。"
        fi
        return 1
    fi
}

install_or_update_xray() {
    local force="${1:-false}"
    local release_json latest_url version tmpdir zip_path xray_bin replacing_existing

    install_dependencies || return 1
    init_config || return 1
    init_state || return 1

    if [[ -x "$BIN_PATH" && "$force" != "true" ]]; then
        create_service || return 1
        return 0
    fi

    info "[核心] 获取 Xray 最新版本..."
    release_json="$(curl -fsSL --retry 3 -H "User-Agent: xray-installer" "$XRAY_RELEASE_API")" || {
        err "[核心] 无法访问 Xray GitHub Releases。"
        return 1
    }
    latest_url="$(echo "$release_json" | jq -r --arg asset "$XRAY_ASSET" '.assets[] | select(.name == $asset) | .browser_download_url' | head -n 1)"
    version="$(echo "$release_json" | jq -r '.tag_name // empty')"

    if [[ -z "$latest_url" || "$latest_url" == "null" ]]; then
        err "[核心] 未找到适配当前架构的 Xray 包: $XRAY_ASSET"
        return 1
    fi

    tmpdir="$(mktemp -d)"
    zip_path="${tmpdir}/${XRAY_ASSET}"

    info "[核心] 下载 Xray ${version:-latest} (${XRAY_ASSET})..."
    if ! curl -fL --retry 3 -H "User-Agent: xray-installer" -o "$zip_path" "$latest_url"; then
        rm -rf "$tmpdir"
        err "[核心] 下载失败。"
        return 1
    fi

    if ! unzip -qo "$zip_path" -d "$tmpdir"; then
        rm -rf "$tmpdir"
        err "[核心] 解压失败。"
        return 1
    fi

    xray_bin="${tmpdir}/xray"
    [[ -f "$xray_bin" ]] || xray_bin="$(find "$tmpdir" -type f -name xray | head -n 1)"
    if [[ -z "$xray_bin" || ! -f "$xray_bin" ]]; then
        rm -rf "$tmpdir"
        err "[核心] 压缩包中未找到 xray 二进制。"
        return 1
    fi

    mkdir -p "$(dirname "$BIN_PATH")" "$ASSET_DIR" || {
        rm -rf "$tmpdir"
        err "[核心] 创建安装目录失败。"
        return 1
    }

    replacing_existing="false"
    [[ -e "$BIN_PATH" ]] && replacing_existing="true"

    if [[ "$replacing_existing" == "true" ]]; then
        if ! create_service; then
            rm -rf "$tmpdir"
            err "[服务] 创建或刷新服务文件失败，已中止更新。"
            return 1
        fi
        if ! stop_service_for_update; then
            rm -rf "$tmpdir"
            return 1
        fi
    fi

    if ! replace_xray_binary "$xray_bin"; then
        rm -rf "$tmpdir"
        return 1
    fi

    if [[ -f "${tmpdir}/geoip.dat" ]] && ! cp "${tmpdir}/geoip.dat" "$ASSET_DIR/"; then
        rm -rf "$tmpdir"
        err "[核心] 更新 geoip.dat 失败。"
        return 1
    fi
    if [[ -f "${tmpdir}/geosite.dat" ]] && ! cp "${tmpdir}/geosite.dat" "$ASSET_DIR/"; then
        rm -rf "$tmpdir"
        err "[核心] 更新 geosite.dat 失败。"
        return 1
    fi

    rm -rf "$tmpdir"

    ensure_default_safety_blocks || return 1

    if ! create_service; then
        err "[服务] 创建或刷新服务文件失败。"
        return 1
    fi

    ok "[核心] Xray ${version:-latest} 安装/更新完成。"
}

update_xray_core() {
    prepare_system || return 1
    install_or_update_xray true || return 1
    validate_config_file || return 1
    restart_service || return 1
    ok "[核心] Xray 已更新并重启。"
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    ((port >= 1 && port <= 65535)) || return 1
    return 0
}

check_port() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tulpn 2>/dev/null | grep -qE "[:.]${port}[[:space:]]" && return 1
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -tulpn 2>/dev/null | grep -qE "[:.]${port}[[:space:]]" && return 1
    fi
    return 0
}

warn_reserved_port() {
    local port="$1"
    if ((port < 1024)); then
        info "[提示] ${port} 属于系统保留端口，请确认是否有冲突。"
    fi
    case "$port" in
        22|53|80|123|443|3306|5432|6379|8080)
            info "[提示] ${port} 是常见服务端口，请确认不会影响现有业务。" ;;
    esac
}

ask_port() {
    local prompt="$1"
    local default_port="$2"
    local __resultvar="$3"
    local input use_anyway

    while true; do
        read -r -p "${prompt} (默认: ${default_port}): " input
        input="${input:-$default_port}"

        if ! validate_port "$input"; then
            err "端口无效，请输入 1-65535 之间的数字。"
            continue
        fi

        if ! check_port "$input"; then
            info "[提示] 端口 ${input} 当前可能已被占用。"
            read -r -p "仍然写入配置? [y/N]: " use_anyway
            [[ "$use_anyway" =~ ^[yY]$ ]] || continue
        fi

        warn_reserved_port "$input"
        printf -v "$__resultvar" '%s' "$input"
        return 0
    done
}

check_ipv6_status() {
    local ipv6_disabled ipv6_global_addr
    ipv6_disabled="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 1)"
    ipv6_global_addr="$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}' | head -n 1 | cut -d'/' -f1)"

    if [[ "$ipv6_disabled" != "0" ]]; then
        err "[IPv6] 系统未开启 IPv6 (net.ipv6.conf.all.disable_ipv6=${ipv6_disabled})"
        return 1
    fi

    if [[ -z "$ipv6_global_addr" ]]; then
        err "[IPv6] 未检测到全局 IPv6 地址，无法生成可用节点。"
        return 1
    fi

    ok "[IPv6] 可用，检测到地址: ${ipv6_global_addr}"
    return 0
}

b64_no_wrap() {
    if base64 --help 2>&1 | grep -q -- '-w'; then
        base64 -w 0
    else
        base64 | tr -d '\n'
    fi
}

b64_url_no_pad() {
    b64_no_wrap | tr '+/' '-_' | sed 's/=*$//'
}

url_encode() {
    jq -rn --arg v "$1" '$v|@uri'
}

generate_ss2022_password() {
    local method="$1"
    local bytes="32"
    [[ "$method" == "2022-blake3-aes-128-gcm" ]] && bytes="16"
    openssl rand -base64 "$bytes"
}

configure_ss2022() {
    local listen_mode="${1:-ipv4}"

    echo -e "\n${YELLOW}[配置] Shadowsocks 2022 加密协议:${PLAIN}"
    echo -e "  1) 2022-blake3-aes-128-gcm ${GREEN}(推荐，兼容性好)${PLAIN}"
    echo "  2) 2022-blake3-aes-256-gcm"
    echo "  3) 2022-blake3-chacha20-poly1305"
    read -r -p "选项 (默认: 1): " M_OPT

    case "${M_OPT:-1}" in
        1) SS_METHOD="2022-blake3-aes-128-gcm" ;;
        2) SS_METHOD="2022-blake3-aes-256-gcm" ;;
        3) SS_METHOD="2022-blake3-chacha20-poly1305" ;;
        *) SS_METHOD="2022-blake3-aes-128-gcm" ;;
    esac

    ask_port "SS2022 端口" "9000" SS_PORT || {
        err "[失败] [SS2022] 端口配置失败。"
        return 1
    }
    SS_PASSWORD="$(generate_ss2022_password "$SS_METHOD")"
    if [[ -z "$SS_PASSWORD" ]]; then
        err "[失败] [SS2022] 密码生成失败。"
        return 1
    fi

    case "$listen_mode" in
        ipv4) SS_LISTEN="0.0.0.0" ;;
        ipv6) SS_LISTEN="::" ;;
        *)
            err "[失败] [SS2022] 未知监听模式: $listen_mode"
            return 1
            ;;
    esac

    info "[SS2022] 监听模式: ${listen_mode} (${SS_LISTEN})"
    return 0
}

install_ss2022() {
    info "[SS2022] 正在生成配置..."
    if ! install_or_update_xray; then
        err "[失败] [SS2022] Xray 安装/更新失败。"
        return 1
    fi

    if ! backup_config; then
        err "[失败] [SS2022] 配置备份失败。"
        return 1
    fi

    local tmp
    tmp="$(mktemp)" || {
        err "[失败] [SS2022] 创建临时文件失败。"
        return 1
    }

    info "[SS2022] 正在写入 config.json..."
    if ! jq --arg tag "$SS_TAG" \
        --arg listen "$SS_LISTEN" \
        --arg port "$SS_PORT" \
        --arg method "$SS_METHOD" \
        --arg pass "$SS_PASSWORD" '
        .inbounds = ((.inbounds // []) | map(select(.tag != $tag))) |
        .inbounds += [{
          "tag": $tag,
          "listen": $listen,
          "port": ($port|tonumber),
          "protocol": "shadowsocks",
          "settings": {
            "network": "tcp,udp",
            "method": $method,
            "password": $pass,
            "level": 0
          }
        }]
       ' "$CONFIG_FILE" > "$tmp"; then
        rm -f "$tmp"
        err "[失败] [SS2022] jq 生成配置失败。"
        return 1
    fi

    if ! mv "$tmp" "$CONFIG_FILE"; then
        rm -f "$tmp"
        err "[失败] [SS2022] 写入 $CONFIG_FILE 失败。"
        return 1
    fi

    if ! apply_config "SS2022"; then
        err "[失败] [SS2022] 应用配置失败。"
        return 1
    fi
    state_set_meta_action "安装 SS2022" || err "[状态] 最近变更记录失败。"
    ok "[完成] SS2022 已写入 Xray 配置。"
    view_config
}

generate_vless_encryption_pair() {
    local auth="$1"
    local output dec_line enc_line

    output="$("$BIN_PATH" vlessenc 2>/dev/null)" || {
        err "[VLESS] xray vlessenc 执行失败，请确认 Xray 版本支持 VLESS Encryption。"
        return 1
    }

    if [[ "$auth" == "mlkem768" ]]; then
        dec_line="$(echo "$output" | grep '"decryption"' | tail -n 1)"
        enc_line="$(echo "$output" | grep '"encryption"' | tail -n 1)"
    else
        dec_line="$(echo "$output" | grep '"decryption"' | head -n 1)"
        enc_line="$(echo "$output" | grep '"encryption"' | head -n 1)"
    fi

    VLESS_DECRYPTION="$(echo "$dec_line" | sed -n 's/.*"decryption": "\([^"]*\)".*/\1/p')"
    VLESS_ENCRYPTION="$(echo "$enc_line" | sed -n 's/.*"encryption": "\([^"]*\)".*/\1/p')"

    if [[ -z "$VLESS_DECRYPTION" || -z "$VLESS_ENCRYPTION" ]]; then
        err "[VLESS] 无法解析 xray vlessenc 输出。"
        return 1
    fi

    VLESS_ENC_METHOD="${VLESS_ENC_METHOD:-native}"
    VLESS_CLIENT_RTT="${VLESS_CLIENT_RTT:-0rtt}"
    VLESS_SERVER_TICKET="${VLESS_SERVER_TICKET:-600s}"

    VLESS_DECRYPTION="$(rewrite_vlessenc_blocks "server" "$VLESS_DECRYPTION" "$VLESS_ENC_METHOD" "$VLESS_SERVER_TICKET")" || return 1
    VLESS_ENCRYPTION="$(rewrite_vlessenc_blocks "client" "$VLESS_ENCRYPTION" "$VLESS_ENC_METHOD" "$VLESS_CLIENT_RTT")" || return 1
}

rewrite_vlessenc_blocks() {
    local side="$1"
    local value="$2"
    local method="$3"
    local third_block="$4"
    local old_ifs auth_block result i
    local -a VLESS_BLOCKS

    case "$method" in
        native|xorpub|random) ;;
        *)
            err "[VLESS] 不支持的外观混淆方法: $method"
            return 1
            ;;
    esac

    case "$side" in
        server)
            if [[ ! "$third_block" =~ ^[0-9]+s$ && ! "$third_block" =~ ^[0-9]+-[0-9]+s$ ]]; then
                err "[VLESS] 服务端 ticket 有效期格式无效: $third_block"
                return 1
            fi
            ;;
        client)
            if [[ "$third_block" != "0rtt" && "$third_block" != "1rtt" ]]; then
                err "[VLESS] 客户端握手模式无效: $third_block"
                return 1
            fi
            ;;
        *)
            err "[VLESS] 内部错误：未知 VLESS Encryption 侧别: $side"
            return 1
            ;;
    esac

    if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
        err "[VLESS] vlessenc 字符串包含非法换行。"
        return 1
    fi

    old_ifs="$IFS"
    IFS='.'
    read -r -a VLESS_BLOCKS <<< "$value"
    IFS="$old_ifs"

    if (( ${#VLESS_BLOCKS[@]} < 4 )); then
        err "[VLESS] vlessenc 字符串 block 数不足，无法安全改写。"
        return 1
    fi

    if [[ "${VLESS_BLOCKS[0]}" != "mlkem768x25519plus" ]]; then
        err "[VLESS] 未识别的握手方法: ${VLESS_BLOCKS[0]}"
        return 1
    fi

    case "${VLESS_BLOCKS[1]}" in
        native|xorpub|random) ;;
        *)
            err "[VLESS] 未识别的原始外观混淆方法: ${VLESS_BLOCKS[1]}"
            return 1
            ;;
    esac

    auth_block="${VLESS_BLOCKS[$((${#VLESS_BLOCKS[@]} - 1))]}"
    if [[ -z "$auth_block" || ! "$auth_block" =~ ^[A-Za-z0-9_-]+$ ]]; then
        err "[VLESS] 认证参数 block 无效，已中止改写。"
        return 1
    fi

    VLESS_BLOCKS[1]="$method"
    VLESS_BLOCKS[2]="$third_block"

    result="${VLESS_BLOCKS[0]}"
    for ((i = 1; i < ${#VLESS_BLOCKS[@]}; i++)); do
        result="${result}.${VLESS_BLOCKS[$i]}"
    done

    printf '%s' "$result"
}

ask_vless_auth() {
    echo -e "\n${YELLOW}[配置] VLESS Encryption 认证方式:${PLAIN}"
    echo -e "  1) X25519 ${GREEN}(推荐，链接更短)${PLAIN}"
    echo "  2) ML-KEM-768 (后量子认证，链接很长)"
    read -r -p "选项 (默认: 1): " V_AUTH_OPT
    case "${V_AUTH_OPT:-1}" in
        2) VLESS_AUTH="mlkem768" ;;
        *) VLESS_AUTH="x25519" ;;
    esac
}

configure_vless_advanced_options() {
    local enc_opt rtt_opt ticket_opt custom_ticket

    VLESS_MODE="advanced"

    # VLESS reverse/relay needs coordinated routing on both ends; do not fake one-click support here.
    echo -e "\n${YELLOW}[高级] VLESS Encryption 外观混淆方法:${PLAIN}"
    echo -e "  1) native ${GREEN}(默认，原始格式)${PLAIN}"
    echo "  2) xorpub (混淆公钥部分)"
    echo "  3) random (完整随机外观)"
    read -r -p "选项 (默认: 1): " enc_opt
    case "${enc_opt:-1}" in
        2) VLESS_ENC_METHOD="xorpub" ;;
        3) VLESS_ENC_METHOD="random" ;;
        *) VLESS_ENC_METHOD="native" ;;
    esac

    echo -e "\n${YELLOW}[高级] 客户端会话恢复:${PLAIN}"
    echo -e "  1) 0rtt ${GREEN}(默认，尝试快速恢复)${PLAIN}"
    echo "  2) 1rtt (强制完整握手)"
    read -r -p "选项 (默认: 1): " rtt_opt
    case "${rtt_opt:-1}" in
        2) VLESS_CLIENT_RTT="1rtt" ;;
        *) VLESS_CLIENT_RTT="0rtt" ;;
    esac

    echo -e "\n${YELLOW}[高级] 服务端 ticket 有效期:${PLAIN}"
    echo -e "  1) 600s ${GREEN}(默认)${PLAIN}"
    echo "  2) 300s"
    echo "  3) 自定义，例如 100-500s 或 900s"
    read -r -p "选项 (默认: 1): " ticket_opt
    case "${ticket_opt:-1}" in
        2) VLESS_SERVER_TICKET="300s" ;;
        3)
            read -r -p "请输入 ticket 有效期: " custom_ticket
            if [[ "$custom_ticket" =~ ^[0-9]+s$ || "$custom_ticket" =~ ^[0-9]+-[0-9]+s$ ]]; then
                VLESS_SERVER_TICKET="$custom_ticket"
            else
                info "[提示] 格式无效，使用默认 600s。"
                VLESS_SERVER_TICKET="600s"
            fi
            ;;
        *) VLESS_SERVER_TICKET="600s" ;;
    esac

    info "[提示] VLESS reverse/relay 等协议层能力当前脚本暂未暴露，请手动编辑 Xray 配置实现。"
}

configure_vless_encryption() {
    install_or_update_xray || return 1

    VLESS_MODE="basic"
    VLESS_ENC_METHOD="native"
    VLESS_CLIENT_RTT="0rtt"
    VLESS_SERVER_TICKET="600s"

    echo -e "\n${YELLOW}[配置] VLESS Encryption 配置模式:${PLAIN}"
    echo -e "  1) 基础模式 ${GREEN}(推荐，保持当前简单体验)${PLAIN}"
    echo "  2) 高级模式 (外观混淆、0-RTT/1-RTT、ticket 有效期)"
    read -r -p "选项 (默认: 1): " V_MODE_OPT
    [[ "${V_MODE_OPT:-1}" == "2" ]] && configure_vless_advanced_options

    ask_vless_auth

    ask_port "VLESS Encryption 端口" "8443" VLESS_PORT
    VLESS_LISTEN="0.0.0.0"
    VLESS_UUID="$("$BIN_PATH" uuid 2>/dev/null | tr -d '\r\n')"
    [[ -n "$VLESS_UUID" ]] || VLESS_UUID="$(cat /proc/sys/kernel/random/uuid)"

    generate_vless_encryption_pair "$VLESS_AUTH" || return 1
}

state_set_vless() {
    init_state
    local tmp
    tmp="$(mktemp)"
    jq --arg tag "$VLESS_TAG" \
       --arg uuid "$VLESS_UUID" \
       --arg encryption "$VLESS_ENCRYPTION" \
       --arg auth "$VLESS_AUTH" \
       --arg mode "$VLESS_MODE" \
       --arg enc_method "$VLESS_ENC_METHOD" \
       --arg client_rtt "$VLESS_CLIENT_RTT" \
       --arg server_ticket "$VLESS_SERVER_TICKET" \
       --arg port "$VLESS_PORT" '
        .vless_encryption = {
          "tag": $tag,
          "uuid": $uuid,
          "encryption": $encryption,
          "auth": $auth,
          "mode": $mode,
          "enc_method": $enc_method,
          "client_rtt": $client_rtt,
          "server_ticket": $server_ticket,
          "port": ($port|tonumber)
        }
       ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
    rm -f "$tmp"
    ensure_config_security
}

install_vless_encryption() {
    backup_config

    local tmp
    tmp="$(mktemp)"
    jq --arg tag "$VLESS_TAG" \
       --arg listen "$VLESS_LISTEN" \
       --arg port "$VLESS_PORT" \
       --arg uuid "$VLESS_UUID" \
       --arg decryption "$VLESS_DECRYPTION" '
        .inbounds = ((.inbounds // []) | map(select(.tag != $tag))) |
        .inbounds += [{
          "tag": $tag,
          "listen": $listen,
          "port": ($port|tonumber),
          "protocol": "vless",
          "settings": {
            "clients": [
              {
                "id": $uuid,
                "email": "vless@xray"
              }
            ],
            "decryption": $decryption
          },
          "streamSettings": {
            "network": "tcp",
            "security": "none"
          },
          "sniffing": {
            "enabled": true,
            "destOverride": ["http", "tls"]
          }
        }]
       ' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
    rm -f "$tmp"

    state_set_vless
    apply_config || return 1
    state_set_meta_action "安装 VLESS Encryption" || err "[状态] 最近变更记录失败。"
    ok "[完成] VLESS Encryption 已写入 Xray 配置。"
    view_config
}

install_socks5() {
    echo -e "\n${YELLOW}[配置] SOCKS5 参数:${PLAIN}"
    ask_port "SOCKS5 端口" "1080" S_PORT
    read -r -p "用户 (默认: admin): " S_USER
    S_USER="${S_USER:-admin}"
    read -r -p "密码 (默认: 随机): " S_PASS
    S_PASS="${S_PASS:-$(openssl rand -hex 8)}"

    install_or_update_xray || return 1
    backup_config

    local tmp
    tmp="$(mktemp)"
    jq --arg tag "$SOCKS_TAG" \
       --arg port "$S_PORT" \
       --arg user "$S_USER" \
       --arg pass "$S_PASS" '
        .inbounds = ((.inbounds // []) | map(select(.tag != $tag))) |
        .inbounds += [{
          "tag": $tag,
          "listen": "0.0.0.0",
          "port": ($port|tonumber),
          "protocol": "socks",
          "settings": {
            "auth": "password",
            "accounts": [{"user": $user, "pass": $pass}],
            "udp": true
          }
        }]
       ' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
    rm -f "$tmp"

    apply_config || return 1
    state_set_meta_action "安装 SOCKS5" || err "[状态] 最近变更记录失败。"
    ok "[完成] SOCKS5 已写入 Xray 配置。"
    view_config
}

get_public_addresses() {
    PUBLIC_IPV4="$(curl -s4 --max-time 5 https://ifconfig.me 2>/dev/null || true)"
    PUBLIC_IPV6="$(curl -s6 --max-time 5 https://ifconfig.me 2>/dev/null || true)"

    if [[ -z "$PUBLIC_IPV6" ]]; then
        PUBLIC_IPV6="$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}' | head -n 1 | cut -d'/' -f1)"
    fi
    if [[ -z "$PUBLIC_IPV4" ]]; then
        PUBLIC_IPV4="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi
}

get_local_addresses() {
    PUBLIC_IPV4="$(hostname -I 2>/dev/null | tr ' ' '\n' | awk '/^[0-9]+\./{print; exit}')"
    PUBLIC_IPV6="$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}' | head -n 1 | cut -d'/' -f1)"
}

host_candidates() {
    local mode="${1:-dual}"
    IPV4_HOST=""
    IPV6_HOST=""

    case "$mode" in
        ipv4)
            [[ -n "$PUBLIC_IPV4" ]] && IPV4_HOST="$PUBLIC_IPV4"
            ;;
        ipv6)
            [[ -n "$PUBLIC_IPV6" ]] && IPV6_HOST="[${PUBLIC_IPV6}]"
            ;;
        *)
            [[ -n "$PUBLIC_IPV4" ]] && IPV4_HOST="$PUBLIC_IPV4"
            [[ -n "$PUBLIC_IPV6" ]] && IPV6_HOST="[${PUBLIC_IPV6}]"
            ;;
    esac
}

default_private_block_mode() {
    if [[ -f "$ASSET_DIR/geoip.dat" ]]; then
        printf '%s' "geoip:private"
    else
        printf '%s' "CIDR fallback"
    fi
}

default_private_block_mode_arg() {
    if [[ -f "$ASSET_DIR/geoip.dat" ]]; then
        printf '%s' "geoip"
    else
        printf '%s' "cidr"
    fi
}

ensure_default_safety_blocks() {
    local tmp
    local private_mode

    [[ -f "$CONFIG_FILE" ]] || return 0
    command -v jq >/dev/null 2>&1 || {
        err "[错误] 缺少 jq，无法写入默认安全屏蔽规则。"
        return 1
    }

    private_mode="$(default_private_block_mode_arg)"
    info "[安全] 默认私网屏蔽模式: $(default_private_block_mode)"

    tmp="$(mktemp)" || {
        err "[失败] [安全] 创建临时文件失败。"
        return 1
    }

    if ! jq --arg block "$BLOCK_OUTBOUND_TAG" \
        --arg ports "$DEFAULT_SAFETY_BLOCK_PORTS" \
        --arg private_mode "$private_mode" '
        def private_fallback_ips:
          ["127.0.0.0/8","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","169.254.0.0/16","100.64.0.0/10","::1/128","fc00::/7","fe80::/10"];
        def private_ips:
          if $private_mode == "geoip" then ["geoip:private"] else private_fallback_ips end;
        def private_rule:
          {"type": "field", "ip": private_ips, "outboundTag": $block};
        def default_safety_rule:
          . == {"type": "field", "protocol": ["bittorrent"], "outboundTag": $block} or
          . == {"type": "field", "ip": ["geoip:private"], "outboundTag": $block} or
          . == {"type": "field", "ip": private_fallback_ips, "outboundTag": $block} or
          . == {"type": "field", "port": $ports, "outboundTag": $block};

        .outbounds = (.outbounds // []) |
        if ((.outbounds | map(select(.tag == $block)) | length) > 0) then
          .
        else
          .outbounds += [{"tag": $block, "protocol": "blackhole"}]
        end |
        .routing = (.routing // {}) |
        .routing.rules = ([
          {"type": "field", "protocol": ["bittorrent"], "outboundTag": $block},
          private_rule,
          {"type": "field", "port": $ports, "outboundTag": $block}
        ] + ((.routing.rules // []) | map(select((default_safety_rule) | not))))
      ' "$CONFIG_FILE" > "$tmp"; then
        rm -f "$tmp"
        err "[失败] [安全] 写入默认安全屏蔽规则失败。"
        return 1
    fi

    if ! mv "$tmp" "$CONFIG_FILE"; then
        rm -f "$tmp"
        err "[失败] [安全] 更新 $CONFIG_FILE 失败。"
        return 1
    fi
}

default_safety_block_enabled() {
    [[ -f "$CONFIG_FILE" ]] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    jq -e --arg block "$BLOCK_OUTBOUND_TAG" \
       --arg ports "$DEFAULT_SAFETY_BLOCK_PORTS" \
       --arg private_mode "$(default_private_block_mode_arg)" '
      def private_fallback_ips:
        ["127.0.0.0/8","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","169.254.0.0/16","100.64.0.0/10","::1/128","fc00::/7","fe80::/10"];
      def private_ips:
        if $private_mode == "geoip" then ["geoip:private"] else private_fallback_ips end;
      any(.routing.rules[]?; . == {"type": "field", "protocol": ["bittorrent"], "outboundTag": $block}) and
      any(.routing.rules[]?; . == {"type": "field", "ip": private_ips, "outboundTag": $block}) and
      any(.routing.rules[]?; . == {"type": "field", "port": $ports, "outboundTag": $block})
    ' "$CONFIG_FILE" >/dev/null 2>&1
}

default_safety_block_status() {
    if default_safety_block_enabled; then
        printf '%s' "已启用"
    else
        printf '%s' "未启用"
    fi
}

enhanced_safety_block_enabled() {
    [[ -f "$CONFIG_FILE" ]] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    jq -e --arg block "$BLOCK_OUTBOUND_TAG" \
       --arg ports "$ENHANCED_SAFETY_BLOCK_PORTS" '
      .routing.rules[]? |
      select(. == {"type": "field", "port": $ports, "outboundTag": $block})
    ' "$CONFIG_FILE" >/dev/null 2>&1
}

enhanced_safety_block_status() {
    if enhanced_safety_block_enabled; then
        printf '%s' "已启用"
    else
        printf '%s' "未启用"
    fi
}

set_enhanced_safety_block() {
    local enable="$1"
    local tmp action

    init_config || return 1
    backup_config || {
        err "[失败] [安全] 配置备份失败。"
        return 1
    }

    tmp="$(mktemp)" || {
        err "[失败] [安全] 创建临时文件失败。"
        return 1
    }

    if [[ "$enable" == "true" ]]; then
        info "[安全] 正在开启增强安全屏蔽..."
        if ! jq --arg block "$BLOCK_OUTBOUND_TAG" \
            --arg ports "$ENHANCED_SAFETY_BLOCK_PORTS" '
          def enhanced_safety_rule:
            . == {"type": "field", "port": $ports, "outboundTag": $block};

          .outbounds = (.outbounds // []) |
          if ((.outbounds | map(select(.tag == $block)) | length) > 0) then
            .
          else
            .outbounds += [{"tag": $block, "protocol": "blackhole"}]
          end |
          .routing = (.routing // {}) |
          .routing.rules = ([
            {"type": "field", "port": $ports, "outboundTag": $block}
          ] + ((.routing.rules // []) | map(select((enhanced_safety_rule) | not))))
        ' "$CONFIG_FILE" > "$tmp"; then
            rm -f "$tmp"
            err "[失败] [安全] 生成增强安全屏蔽规则失败。"
            return 1
        fi
    else
        info "[安全] 正在关闭增强安全屏蔽..."
        if ! jq --arg block "$BLOCK_OUTBOUND_TAG" \
            --arg ports "$ENHANCED_SAFETY_BLOCK_PORTS" '
          def enhanced_safety_rule:
            . == {"type": "field", "port": $ports, "outboundTag": $block};

          .routing = (.routing // {}) |
          .routing.rules = ((.routing.rules // []) | map(select((enhanced_safety_rule) | not)))
        ' "$CONFIG_FILE" > "$tmp"; then
            rm -f "$tmp"
            err "[失败] [安全] 移除增强安全屏蔽规则失败。"
            return 1
        fi
    fi

    if ! mv "$tmp" "$CONFIG_FILE"; then
        rm -f "$tmp"
        err "[失败] [安全] 写入 $CONFIG_FILE 失败。"
        return 1
    fi

    if ! apply_config "安全"; then
        err "[失败] [安全] 应用增强安全屏蔽设置失败。"
        return 1
    fi

    action="关闭"
    [[ "$enable" == "true" ]] && action="启用"
    state_set_meta_action "增强安全屏蔽: ${action}" || err "[状态] 最近变更记录失败。"
    ok "[完成] 增强安全屏蔽已${action}。"
}

configure_enhanced_safety_block() {
    local current choice

    install_or_update_xray || {
        err "[失败] [安全] Xray 安装/更新失败，无法修改增强安全屏蔽。"
        return 1
    }

    current="$(enhanced_safety_block_status)"
    echo -e "\n${YELLOW}[安全] 增强安全屏蔽:${PLAIN} ${current}"

    if enhanced_safety_block_enabled; then
        echo " 1) 关闭增强安全屏蔽"
        echo " 2) 保持开启"
        read -r -p "选项 (默认: 2): " choice
        case "${choice:-2}" in
            1) set_enhanced_safety_block "false" ;;
            2) info "[安全] 保持开启。" ;;
            *) err "无效选项。"; return 1 ;;
        esac
    else
        echo " 1) 开启增强安全屏蔽"
        echo " 2) 保持关闭"
        read -r -p "选项 (默认: 2): " choice
        case "${choice:-2}" in
            1) set_enhanced_safety_block "true" ;;
            2) info "[安全] 保持关闭。" ;;
            *) err "无效选项。"; return 1 ;;
        esac
    fi
}

china_direct_block_enabled() {
    [[ "$(china_direct_block_status)" != "未启用" ]]
}

china_direct_block_status() {
    local has_ip="false"
    local has_domain="false"

    [[ -f "$CONFIG_FILE" ]] || {
        printf '%s' "未启用"
        return 0
    }
    command -v jq >/dev/null 2>&1 || {
        printf '%s' "未启用"
        return 0
    }

    if jq -e --arg block "$BLOCK_OUTBOUND_TAG" '
      any(.routing.rules[]?; . == {"type": "field", "ip": ["geoip:cn"], "outboundTag": $block})
    ' "$CONFIG_FILE" >/dev/null 2>&1; then
        has_ip="true"
    fi

    if jq -e --arg block "$BLOCK_OUTBOUND_TAG" '
      any(.routing.rules[]?; . == {"type": "field", "domain": ["geosite:cn"], "outboundTag": $block})
    ' "$CONFIG_FILE" >/dev/null 2>&1; then
        has_domain="true"
    fi

    if [[ "$has_ip" == "true" && "$has_domain" == "true" ]]; then
        printf '%s' "增强模式"
    elif [[ "$has_ip" == "true" ]]; then
        printf '%s' "基础模式"
    else
        printf '%s' "未启用"
    fi
}

check_china_direct_block_assets() {
    local mode="${1:-basic}"
    local missing=()

    [[ -f "$ASSET_DIR/geoip.dat" ]] || missing+=("$ASSET_DIR/geoip.dat")
    if [[ "$mode" == "enhanced" ]]; then
        [[ -f "$ASSET_DIR/geosite.dat" ]] || missing+=("$ASSET_DIR/geosite.dat")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        err "[错误] 缺少 Xray 路由资源: ${missing[*]}"
        if [[ "$mode" == "enhanced" ]]; then
            err "[提示] 增强模式需要 geoip.dat 和 geosite.dat；基础模式只需要 geoip.dat。"
        else
            err "[提示] 中国大陆直连屏蔽基础模式需要 geoip.dat。"
        fi
        err "[提示] 请先执行 1) 安装/更新 Xray 核心 或 ike update，确保路由资源存在。"
        return 1
    fi

    return 0
}

set_china_direct_block() {
    local mode="$1"
    local tmp action

    init_config || return 1

    case "$mode" in
        off|basic|enhanced) ;;
        *)
            err "[失败] [路由] 未知中国大陆直连屏蔽模式: $mode"
            return 1
            ;;
    esac

    if [[ "$mode" != "off" ]]; then
        check_china_direct_block_assets "$mode" || return 1
    fi

    backup_config || {
        err "[失败] [路由] 配置备份失败。"
        return 1
    }

    tmp="$(mktemp)" || {
        err "[失败] [路由] 创建临时文件失败。"
        return 1
    }

    if [[ "$mode" == "basic" ]]; then
        info "[路由] 正在开启中国大陆直连屏蔽基础模式..."
        if ! jq --arg block "$BLOCK_OUTBOUND_TAG" '
          def cn_block_rule:
            . == {"type": "field", "ip": ["geoip:cn"], "outboundTag": $block} or
            . == {"type": "field", "domain": ["geosite:cn"], "outboundTag": $block};

          .outbounds = (.outbounds // []) |
          if ((.outbounds | map(select(.tag == $block)) | length) > 0) then
            .
          else
            .outbounds += [{"tag": $block, "protocol": "blackhole"}]
          end |
          .routing = (.routing // {}) |
          .routing.rules = ([
            {"type": "field", "ip": ["geoip:cn"], "outboundTag": $block}
          ] + ((.routing.rules // []) | map(select((cn_block_rule) | not))))
        ' "$CONFIG_FILE" > "$tmp"; then
            rm -f "$tmp"
            err "[失败] [路由] 生成中国大陆直连屏蔽规则失败。"
            return 1
        fi
    elif [[ "$mode" == "enhanced" ]]; then
        info "[路由] 正在开启中国大陆直连屏蔽增强模式..."
        if ! jq --arg block "$BLOCK_OUTBOUND_TAG" '
          def cn_block_rule:
            . == {"type": "field", "ip": ["geoip:cn"], "outboundTag": $block} or
            . == {"type": "field", "domain": ["geosite:cn"], "outboundTag": $block};

          .outbounds = (.outbounds // []) |
          if ((.outbounds | map(select(.tag == $block)) | length) > 0) then
            .
          else
            .outbounds += [{"tag": $block, "protocol": "blackhole"}]
          end |
          .routing = (.routing // {}) |
          .routing.rules = ([
            {"type": "field", "ip": ["geoip:cn"], "outboundTag": $block},
            {"type": "field", "domain": ["geosite:cn"], "outboundTag": $block}
          ] + ((.routing.rules // []) | map(select((cn_block_rule) | not))))
        ' "$CONFIG_FILE" > "$tmp"; then
            rm -f "$tmp"
            err "[失败] [路由] 生成中国大陆直连屏蔽规则失败。"
            return 1
        fi
    else
        info "[路由] 正在关闭中国大陆直连屏蔽..."
        if ! jq --arg block "$BLOCK_OUTBOUND_TAG" '
          def cn_block_rule:
            . == {"type": "field", "ip": ["geoip:cn"], "outboundTag": $block} or
            . == {"type": "field", "domain": ["geosite:cn"], "outboundTag": $block};

          .routing = (.routing // {}) |
          .routing.rules = ((.routing.rules // []) | map(select((cn_block_rule) | not)))
        ' "$CONFIG_FILE" > "$tmp"; then
            rm -f "$tmp"
            err "[失败] [路由] 移除中国大陆直连屏蔽规则失败。"
            return 1
        fi
    fi

    if ! mv "$tmp" "$CONFIG_FILE"; then
        rm -f "$tmp"
        err "[失败] [路由] 写入 $CONFIG_FILE 失败。"
        return 1
    fi

    if ! apply_config "路由"; then
        err "[失败] [路由] 应用中国大陆直连屏蔽设置失败。"
        return 1
    fi

    case "$mode" in
        basic) action="基础模式" ;;
        enhanced) action="增强模式" ;;
        *) action="关闭" ;;
    esac
    state_set_meta_action "中国大陆直连屏蔽: ${action}" || err "[状态] 最近变更记录失败。"
    ok "[完成] 中国大陆直连屏蔽已设置为${action}。"
}

configure_china_direct_block() {
    local current choice

    install_or_update_xray || {
        err "[失败] [路由] Xray 安装/更新失败，无法修改路由设置。"
        return 1
    }

    current="$(china_direct_block_status)"
    echo -e "\n${YELLOW}[路由] 中国大陆直连屏蔽:${PLAIN} ${current}"

    echo " 1) 开启基础模式 (仅 geoip:cn IP)"
    echo " 2) 开启增强模式 (geoip:cn IP + geosite:cn 域名)"
    echo " 3) 关闭中国大陆直连屏蔽"
    echo " 4) 保持当前状态"
    read -r -p "选项 (默认: 4): " choice
    case "${choice:-4}" in
        1) set_china_direct_block "basic" ;;
        2) set_china_direct_block "enhanced" ;;
        3) set_china_direct_block "off" ;;
        4) info "[路由] 保持当前状态。" ;;
        *) err "无效选项。"; return 1 ;;
    esac
}

resource_file_status() {
    if [[ -f "$1" ]]; then
        printf '%s' "存在"
    else
        printf '%s' "不存在"
    fi
}

xray_config_test_status() {
    local log_file

    [[ -x "$BIN_PATH" ]] || {
        printf '%s' "未检测到 xray"
        return 0
    }
    [[ -f "$CONFIG_FILE" ]] || {
        printf '%s' "失败"
        return 0
    }

    log_file="$(mktemp)" || {
        printf '%s' "失败"
        return 0
    }
    if "$BIN_PATH" run -test -c "$CONFIG_FILE" >"$log_file" 2>&1; then
        rm -f "$log_file"
        printf '%s' "通过"
    else
        rm -f "$log_file"
        printf '%s' "失败"
    fi
}

xray_service_status() {
    if [[ "$INIT_SYSTEM" == "systemd" ]] && command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
            printf '%s' "运行中"
        else
            printf '%s' "未运行"
        fi
    elif [[ "$INIT_SYSTEM" == "openrc" ]] && command -v rc-service >/dev/null 2>&1; then
        if rc-service "$SERVICE_NAME" status 2>/dev/null | grep -qiE 'started|running'; then
            printf '%s' "运行中"
        else
            printf '%s' "未运行"
        fi
    else
        printf '%s' "未检测到 systemd/openrc"
    fi
}

view_config() {
    local mode="${1:-$LINK_VIEW_MODE}"
    local detail="${2:-quick}"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        err "错误：未找到配置文件，请先安装协议。"
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        err "错误：缺少 jq，无法读取配置。"
        return 1
    fi

    init_state
    if [[ "$detail" == "doctor" ]]; then
        get_public_addresses
    else
        get_local_addresses
    fi
    host_candidates "$mode"

    echo -e "\n${GREEN}========= 当前 Xray 配置信息 =========${PLAIN}"
    if [[ "$detail" == "doctor" ]]; then
        echo -e "查看模式: ${YELLOW}完整诊断${PLAIN}"
    else
        echo -e "查看模式: ${YELLOW}快速${PLAIN} (${GREEN}完整诊断: ike view doctor${PLAIN})"
    fi
    echo -e "链接显示模式: ${YELLOW}${mode}${PLAIN}"
    echo -e "最近变更: ${YELLOW}$(state_meta_value last_action)${PLAIN}"
    echo -e "最近更新时间: ${YELLOW}$(state_meta_value last_updated_at)${PLAIN}"
    echo -e "默认安全屏蔽: ${YELLOW}$(default_safety_block_status)${PLAIN}"
    echo -e "默认私网规则: ${YELLOW}$(default_private_block_mode)${PLAIN}"
    echo -e "增强安全屏蔽: ${YELLOW}$(enhanced_safety_block_status)${PLAIN}"
    echo -e "中国大陆直连屏蔽: ${YELLOW}$(china_direct_block_status)${PLAIN}"
    if [[ "$detail" == "doctor" ]]; then
        echo -e "geoip.dat: ${YELLOW}$(resource_file_status "$ASSET_DIR/geoip.dat")${PLAIN}"
        echo -e "geosite.dat: ${YELLOW}$(resource_file_status "$ASSET_DIR/geosite.dat")${PLAIN}"
        echo -e "Xray 配置校验: ${YELLOW}$(xray_config_test_status)${PLAIN}"
        echo -e "Xray 服务状态: ${YELLOW}$(xray_service_status)${PLAIN}"
        [[ -n "$PUBLIC_IPV4" ]] && echo -e "公网 IPv4: ${PUBLIC_IPV4}"
        [[ -n "$PUBLIC_IPV6" ]] && echo -e "公网 IPv6: ${PUBLIC_IPV6}"
    elif [[ -z "$IPV4_HOST" && -z "$IPV6_HOST" ]]; then
        info "[提示] 快速模式未检测到本机地址，可使用 ike view doctor 探测公网 IP。"
    fi

    local ss_in ssp ssw ssm user_info
    ss_in="$(jq -c --arg tag "$SS_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" 2>/dev/null)"
    if [[ -n "$ss_in" ]]; then
        ssp="$(echo "$ss_in" | jq -r '.port')"
        ssw="$(echo "$ss_in" | jq -r '.settings.password')"
        ssm="$(echo "$ss_in" | jq -r '.settings.method')"
        user_info="$(printf '%s' "${ssm}:${ssw}" | b64_url_no_pad)"

        echo -e "\n${YELLOW}--- Shadowsocks 2022 ---${PLAIN}"
        echo -e "端口: ${ssp}"
        echo -e "加密: ${ssm}"
        echo -e "密码: ${ssw}"
        [[ -n "$IPV4_HOST" ]] && echo -e "IPv4链接: ss://${user_info}@${IPV4_HOST}:${ssp}#SS2022-IPv4"
        [[ -n "$IPV6_HOST" ]] && echo -e "IPv6链接: ss://${user_info}@${IPV6_HOST}:${ssp}#SS2022-IPv6"
    fi

    local vless_in vp vu venc vmode vmethod vrtt vticket venc_uri
    vless_in="$(jq -c --arg tag "$VLESS_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" 2>/dev/null)"
    if [[ -n "$vless_in" ]]; then
        vp="$(echo "$vless_in" | jq -r '.port')"
        vu="$(echo "$vless_in" | jq -r '.settings.clients[0].id')"
        venc="$(jq -r '.vless_encryption.encryption // empty' "$STATE_FILE" 2>/dev/null)"
        vmode="$(jq -r '.vless_encryption.mode // "basic"' "$STATE_FILE" 2>/dev/null)"
        vmethod="$(jq -r '.vless_encryption.enc_method // "native"' "$STATE_FILE" 2>/dev/null)"
        vrtt="$(jq -r '.vless_encryption.client_rtt // "0rtt"' "$STATE_FILE" 2>/dev/null)"
        vticket="$(jq -r '.vless_encryption.server_ticket // "600s"' "$STATE_FILE" 2>/dev/null)"

        echo -e "\n${YELLOW}--- VLESS Encryption ---${PLAIN}"
        echo -e "端口: ${vp}"
        echo -e "UUID: ${vu}"
        echo -e "模式: ${vmode}"
        echo -e "外观混淆: ${vmethod}"
        echo -e "客户端握手: ${vrtt}"
        echo -e "服务端 ticket: ${vticket}"
        if [[ -z "$venc" ]]; then
            err "[提示] 缺少客户端 encryption，无法生成完整 VLESS 链接。请重新安装或重置 VLESS Encryption。"
        else
            echo -e "客户端 encryption: ${venc}"
            venc_uri="$(url_encode "$venc")"
            [[ -n "$IPV4_HOST" ]] && echo -e "IPv4链接: vless://${vu}@${IPV4_HOST}:${vp}?type=tcp&security=none&encryption=${venc_uri}#VLESS-ENC-IPv4"
            [[ -n "$IPV6_HOST" ]] && echo -e "IPv6链接: vless://${vu}@${IPV6_HOST}:${vp}?type=tcp&security=none&encryption=${venc_uri}#VLESS-ENC-IPv6"
        fi
    fi

    local socks_in sp su sw
    socks_in="$(jq -c --arg tag "$SOCKS_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" 2>/dev/null)"
    if [[ -n "$socks_in" ]]; then
        sp="$(echo "$socks_in" | jq -r '.port')"
        su="$(echo "$socks_in" | jq -r '.settings.accounts[0].user')"
        sw="$(echo "$socks_in" | jq -r '.settings.accounts[0].pass')"

        echo -e "\n${YELLOW}--- SOCKS5 ---${PLAIN}"
        echo -e "端口: ${sp}"
        echo -e "用户: ${su}"
        echo -e "密码: ${sw}"
        [[ -n "$IPV4_HOST" ]] && echo -e "IPv4链接: socks5://${su}:${sw}@${IPV4_HOST}:${sp}"
        [[ -n "$IPV6_HOST" ]] && echo -e "IPv6链接: socks5://${su}:${sw}@${IPV6_HOST}:${sp}"
    fi

    show_footer
}

set_link_view_mode() {
    echo -e "\n${YELLOW}[设置] 链接显示模式${PLAIN}"
    echo " 1) 双栈 (IPv4 + IPv6)"
    echo " 2) 仅 IPv4"
    echo " 3) 仅 IPv6"
    read -r -p "选项 (默认: 1): " MODE_OPT

    case "${MODE_OPT:-1}" in
        1) LINK_VIEW_MODE="dual" ;;
        2) LINK_VIEW_MODE="ipv4" ;;
        3) LINK_VIEW_MODE="ipv6" ;;
        *) LINK_VIEW_MODE="dual" ;;
    esac

    ok "[完成] 当前链接显示模式: ${LINK_VIEW_MODE}"
}

reset_secrets() {
    install_or_update_xray || return 1
    [[ -f "$CONFIG_FILE" ]] || {
        err "[错误] 未找到配置文件。"
        return 1
    }

    echo -e "\n${YELLOW}[维护] 重置密钥/密码（端口不变）${PLAIN}"
    echo " 1) 重置 SS2022 密码"
    echo " 2) 重置 VLESS UUID + Encryption"
    echo " 3) 重置 SOCKS5 密码"
    echo " 4) 一键重置全部"
    read -r -p "选项: " R_OPT

    backup_config
    local tmp changed current_method current_port current_auth
    changed="false"

    if [[ "$R_OPT" == "1" || "$R_OPT" == "4" ]]; then
        if jq -e --arg tag "$SS_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1; then
            current_method="$(jq -r --arg tag "$SS_TAG" '.inbounds[] | select(.tag == $tag).settings.method' "$CONFIG_FILE")"
            SS_PASSWORD="$(generate_ss2022_password "$current_method")"
            tmp="$(mktemp)"
            jq --arg tag "$SS_TAG" --arg pass "$SS_PASSWORD" '(.inbounds[] | select(.tag == $tag).settings.password) = $pass' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
            rm -f "$tmp"
            ok "[完成] SS2022 密码已重置。"
            changed="true"
        else
            info "[跳过] 未找到 SS2022 入站。"
        fi
    fi

    if [[ "$R_OPT" == "2" || "$R_OPT" == "4" ]]; then
        if jq -e --arg tag "$VLESS_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1; then
            current_port="$(jq -r --arg tag "$VLESS_TAG" '.inbounds[] | select(.tag == $tag).port' "$CONFIG_FILE")"
            current_auth="$(jq -r '.vless_encryption.auth // "x25519"' "$STATE_FILE" 2>/dev/null)"
            VLESS_AUTH="$current_auth"
            VLESS_PORT="$current_port"
            VLESS_MODE="$(jq -r '.vless_encryption.mode // "basic"' "$STATE_FILE" 2>/dev/null)"
            VLESS_ENC_METHOD="$(jq -r '.vless_encryption.enc_method // "native"' "$STATE_FILE" 2>/dev/null)"
            VLESS_CLIENT_RTT="$(jq -r '.vless_encryption.client_rtt // "0rtt"' "$STATE_FILE" 2>/dev/null)"
            VLESS_SERVER_TICKET="$(jq -r '.vless_encryption.server_ticket // "600s"' "$STATE_FILE" 2>/dev/null)"
            VLESS_UUID="$("$BIN_PATH" uuid 2>/dev/null | tr -d '\r\n')"
            generate_vless_encryption_pair "$VLESS_AUTH" || return 1
            tmp="$(mktemp)"
            jq --arg tag "$VLESS_TAG" \
               --arg uuid "$VLESS_UUID" \
               --arg decryption "$VLESS_DECRYPTION" '
                (.inbounds[] | select(.tag == $tag).settings.clients[0].id) = $uuid |
                (.inbounds[] | select(.tag == $tag).settings.decryption) = $decryption |
                del(.inbounds[] | select(.tag == $tag).settings.clients[0].flow)
               ' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
            rm -f "$tmp"
            state_set_vless
            ok "[完成] VLESS UUID 与 Encryption 已重置。"
            changed="true"
        else
            info "[跳过] 未找到 VLESS Encryption 入站。"
        fi
    fi

    if [[ "$R_OPT" == "3" || "$R_OPT" == "4" ]]; then
        if jq -e --arg tag "$SOCKS_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1; then
            S_PASS="$(openssl rand -hex 8)"
            tmp="$(mktemp)"
            jq --arg tag "$SOCKS_TAG" --arg pass "$S_PASS" '(.inbounds[] | select(.tag == $tag).settings.accounts[0].pass) = $pass' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
            rm -f "$tmp"
            ok "[完成] SOCKS5 密码已重置。"
            changed="true"
        else
            info "[跳过] 未找到 SOCKS5 入站。"
        fi
    fi

    if [[ "$changed" == "true" ]]; then
        apply_config || return 1
        state_set_meta_action "重置密钥/密码" || err "[状态] 最近变更记录失败。"
        view_config
    else
        info "[提示] 没有可更新的配置。"
    fi
}

remove_inbound() {
    local tag="$1"
    local tmp
    init_config || return 1
    tmp="$(mktemp)"
    jq --arg tag "$tag" '.inbounds = ((.inbounds // []) | map(select(.tag != $tag)))' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
    rm -f "$tmp"
}

state_delete_key() {
    local key="$1"
    local tmp
    init_state
    tmp="$(mktemp)"
    jq "del(.${key})" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
    rm -f "$tmp"
    ensure_config_security
}

cleanup_legacy_singbox() {
    read -r -p "确认删除旧 sing-box 服务与 /etc/sing-box、/usr/local/bin/sing-box? [y/N]: " CONFIRM
    [[ "$CONFIRM" =~ ^[yY]$ ]] || return 0

    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop sing-box >/dev/null 2>&1 || true
        systemctl disable sing-box >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    if command -v rc-service >/dev/null 2>&1; then
        rc-service sing-box stop >/dev/null 2>&1 || true
        rc-update del sing-box >/dev/null 2>&1 || true
        rm -f /etc/init.d/sing-box
    fi
    rm -rf /etc/sing-box /usr/local/bin/sing-box
    ok "[完成] 旧 sing-box 残留已清理。"
}

installed_protocols_summary() {
    local protocols=()
    local summary i

    if [[ -f "$CONFIG_FILE" ]] && command -v jq >/dev/null 2>&1 && jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
        jq -e --arg tag "$SS_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1 && protocols+=("SS2022")
        jq -e --arg tag "$VLESS_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1 && protocols+=("VLESS Encryption")
        jq -e --arg tag "$SOCKS_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1 && protocols+=("SOCKS5")
    fi

    if [[ ${#protocols[@]} -eq 0 ]]; then
        printf '%s' "未配置入站协议"
        return 0
    fi

    summary="${protocols[0]}"
    for ((i = 1; i < ${#protocols[@]}; i++)); do
        summary="${summary} + ${protocols[$i]}"
    done
    printf '%s' "$summary"
}

uninstall() {
    echo -e "\n${YELLOW}[卸载] 选择:${PLAIN}"
    echo " 1) 删除 SS2022 配置"
    echo " 2) 删除 VLESS Encryption 配置"
    echo " 3) 删除 SOCKS5 配置"
    echo " 4) 卸载全部 Xray"
    echo " 5) 清理旧 sing-box 残留"
    read -r -p "选项: " OPT

    case "$OPT" in
        1)
            remove_inbound "$SS_TAG"
            apply_config
            ok "[完成] SS2022 已删除。"
            ;;
        2)
            remove_inbound "$VLESS_TAG"
            state_delete_key "vless_encryption"
            apply_config
            ok "[完成] VLESS Encryption 已删除。"
            ;;
        3)
            remove_inbound "$SOCKS_TAG"
            apply_config
            ok "[完成] SOCKS5 已删除。"
            ;;
        4)
            read -r -p "确认卸载 Xray、配置和快捷命令? [y/N]: " CONFIRM
            [[ "$CONFIRM" =~ ^[yY]$ ]] || return 0
            stop_service
            if [[ "$INIT_SYSTEM" == "systemd" ]]; then
                systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
                rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
                systemctl daemon-reload >/dev/null 2>&1 || true
            elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
                rc-update del "$SERVICE_NAME" >/dev/null 2>&1 || true
                rm -f "/etc/init.d/${SERVICE_NAME}"
            fi
            rm -rf "$CONFIG_DIR" "$ASSET_DIR" "$INSTALLER_DIR" "$BIN_PATH" "$SHORTCUT_PATH" "$LEGACY_SHORTCUT_PATH"
            ok "[完成] Xray 已彻底卸载。"
            exit 0
            ;;
        5)
            cleanup_legacy_singbox
            ;;
        *)
            err "无效选项。"
            ;;
    esac
}

show_footer() {
    local protocol_summary
    protocol_summary="$(installed_protocols_summary)"

    echo -e "\n${GREEN}==============================================${PLAIN}"
    echo -e "${YELLOW}   核心: Xray / 协议: ${protocol_summary}${PLAIN}"
    echo -e "${YELLOW}   快捷命令: ${SHORTCUT_PATH} / ike view [ipv4|ipv6]${PLAIN}"
    echo -e "${GREEN}==============================================${PLAIN}\n"
}

pause_return_menu() {
    echo
    read -r -p "按回车返回主菜单..." || exit 0
}

render_menu() {
    clear 2>/dev/null || true
    echo -e "${GREEN}==============================================${PLAIN}"
    echo -e "${GREEN}   Xray 多协议一键安装脚本 (ike)             ${PLAIN}"
    echo -e "${GREEN}==============================================${PLAIN}"
    echo -e "系统: ${YELLOW}$OS_TYPE${PLAIN} | 初始化: ${YELLOW}$INIT_SYSTEM${PLAIN} | 架构: ${YELLOW}$ARCH${PLAIN}"
    echo -e "----------------------------------------------"
    echo -e "${GREEN}1.${PLAIN} 安装/更新 Xray 核心"
    echo -e "${GREEN}2.${PLAIN} 安装 Shadowsocks 2022"
    echo -e "${GREEN}3.${PLAIN} 安装 IPv6 + Shadowsocks 2022"
    echo -e "${GREEN}4.${PLAIN} 安装 VLESS Encryption"
    echo -e "${GREEN}5.${PLAIN} 安装 SOCKS5 代理"
    echo -e "${GREEN}6.${PLAIN} 查看当前配置链接"
    echo -e "${GREEN}7.${PLAIN} 设置链接显示模式 (IPv4/IPv6/双栈)"
    echo -e "${GREEN}8.${PLAIN} 重置密钥/密码（端口不变）"
    echo -e "${RED}9.${PLAIN} 卸载/清理"
    echo -e "${GREEN}10.${PLAIN} 开启/关闭中国大陆直连屏蔽"
    echo -e "${GREEN}11.${PLAIN} 开启/关闭增强安全屏蔽"
    echo -e "${GREEN}12.${PLAIN} 导出当前配置备份"
    echo -e "${GREEN}13.${PLAIN} 退出"
    echo -e "----------------------------------------------"
}

show_menu() {
    install_shortcut

    while true; do
        render_menu
        read -r -p "请输入选项 [1-13]: " MENU_CHOICE || exit 0

        case "$MENU_CHOICE" in
            1)
                update_xray_core || err "[失败] Xray 核心安装/更新未完成，请查看上方错误信息。"
                ;;
            2)
                if ! { prepare_system && configure_ss2022 "ipv4" && install_ss2022; }; then
                    err "[失败] Shadowsocks 2022 安装未完成，请查看上方错误信息。"
                fi
                ;;
            3)
                if ! prepare_system; then
                    err "[失败] IPv6 + Shadowsocks 2022 安装未完成，请查看上方错误信息。"
                else
                    if check_ipv6_status; then
                        if ! { configure_ss2022 "ipv6" && install_ss2022; }; then
                            err "[失败] IPv6 + Shadowsocks 2022 安装未完成，请查看上方错误信息。"
                        fi
                    else
                        info "[IPv6] 请先在服务器开通 IPv6 后重试。"
                        err "[失败] IPv6 + Shadowsocks 2022 安装未完成。"
                    fi
                fi
                ;;
            4)
                if ! { prepare_system && configure_vless_encryption && install_vless_encryption; }; then
                    err "[失败] VLESS Encryption 安装未完成，请查看上方错误信息。"
                fi
                ;;
            5)
                if ! { prepare_system && install_socks5; }; then
                    err "[失败] SOCKS5 安装未完成，请查看上方错误信息。"
                fi
                ;;
            6)
                view_config || err "[失败] 查看当前配置链接失败，请查看上方错误信息。"
                ;;
            7)
                set_link_view_mode || err "[失败] 设置链接显示模式失败，请查看上方错误信息。"
                ;;
            8)
                if ! { prepare_system && reset_secrets; }; then
                    err "[失败] 重置密钥/密码未完成，请查看上方错误信息。"
                fi
                ;;
            9)
                uninstall || err "[失败] 卸载/清理未完成，请查看上方错误信息。"
                ;;
            10)
                configure_china_direct_block || err "[失败] 中国大陆直连屏蔽设置未完成，请查看上方错误信息。"
                ;;
            11)
                configure_enhanced_safety_block || err "[失败] 增强安全屏蔽设置未完成，请查看上方错误信息。"
                ;;
            12)
                export_current_config_backup || err "[失败] 导出当前配置备份未完成，请查看上方错误信息。"
                ;;
            13) exit 0 ;;
            *) err "错误选项。" ;;
        esac

        pause_return_menu
    done
}

run_view_command() {
    local mode="$LINK_VIEW_MODE"
    local detail="quick"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            doctor)
                detail="doctor"
                ;;
            ipv4|ipv6|dual)
                mode="$1"
                ;;
            *)
                err "[失败] 未知 view 参数: $1"
                echo "用法: ike view [ipv4|ipv6|dual] [doctor]"
                return 1
                ;;
        esac
        shift
    done

    view_config "$mode" "$detail"
}

run_cnblock_command() {
    local mode="${1:-}"

    case "$mode" in
        ""|status)
            echo -e "中国大陆直连屏蔽: ${YELLOW}$(china_direct_block_status)${PLAIN}"
            echo "用法: ike cnblock basic|enhanced|off"
            ;;
        basic|enhanced|off)
            install_or_update_xray || {
                err "[失败] Xray 安装/更新失败，无法修改中国大陆直连屏蔽。"
                return 1
            }
            set_china_direct_block "$mode"
            ;;
        *)
            err "[失败] 未知 cnblock 参数: $mode"
            echo "用法: ike cnblock [basic|enhanced|off]"
            return 1
            ;;
    esac
}

run_safety_command() {
    local scope="${1:-}"
    local action="${2:-}"

    if [[ "$scope" != "enhanced" ]]; then
        err "[失败] 未知 safety 参数: ${scope:-空}"
        echo "用法: ike safety enhanced on|off"
        return 1
    fi

    case "$action" in
        on)
            install_or_update_xray || {
                err "[失败] Xray 安装/更新失败，无法开启增强安全屏蔽。"
                return 1
            }
            set_enhanced_safety_block "true"
            ;;
        off)
            install_or_update_xray || {
                err "[失败] Xray 安装/更新失败，无法关闭增强安全屏蔽。"
                return 1
            }
            set_enhanced_safety_block "false"
            ;;
        ""|status)
            echo -e "增强安全屏蔽: ${YELLOW}$(enhanced_safety_block_status)${PLAIN}"
            echo "用法: ike safety enhanced on|off"
            ;;
        *)
            err "[失败] 未知 safety enhanced 参数: $action"
            echo "用法: ike safety enhanced on|off"
            return 1
            ;;
    esac
}

main() {
    ensure_root
    check_os
    detect_arch

    case "${1:-}" in
        view)
            shift
            run_view_command "$@"
            ;;
        update)
            update_xray_core
            ;;
        backup)
            export_current_config_backup
            ;;
        cnblock)
            run_cnblock_command "${2:-}"
            ;;
        safety)
            run_safety_command "${2:-}" "${3:-}"
            ;;
        *)
            show_menu
            ;;
    esac
}

main "$@"
