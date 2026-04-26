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
SCRIPT_NAME="Xray-OneClick"
SCRIPT_VERSION="0.1.0"
REPO_URL="https://github.com/ike-sh/Xray-OneClick"
RAW_SCRIPT_URL="https://raw.githubusercontent.com/ike-sh/Xray-OneClick/main/install.sh"
XRAY_RELEASE_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"

SS_TAG="ss2022-in"
VLESS_TAG="vless-enc-in"
SOCKS_TAG="socks-in"
FORWARD_TAG_PREFIX="forward-"
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
        x86_64 | amd64) XRAY_ASSET="Xray-linux-64.zip" ;;
        i386 | i686) XRAY_ASSET="Xray-linux-32.zip" ;;
        aarch64 | arm64) XRAY_ASSET="Xray-linux-arm64-v8a.zip" ;;
        armv7l | armv7*) XRAY_ASSET="Xray-linux-arm32-v7a.zip" ;;
        armv6l | armv6*) XRAY_ASSET="Xray-linux-arm32-v6.zip" ;;
        armv5l | armv5*) XRAY_ASSET="Xray-linux-arm32-v5.zip" ;;
        riscv64) XRAY_ASSET="Xray-linux-riscv64.zip" ;;
        s390x) XRAY_ASSET="Xray-linux-s390x.zip" ;;
        ppc64le) XRAY_ASSET="Xray-linux-ppc64le.zip" ;;
        ppc64) XRAY_ASSET="Xray-linux-ppc64.zip" ;;
        loongarch64 | loong64) XRAY_ASSET="Xray-linux-loong64.zip" ;;
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
        cat >"$INSTALLER_PATH" <<EOF
#!/bin/bash
SCRIPT_URL="${RAW_SCRIPT_URL}"
TMP_SCRIPT="\$(mktemp)"
trap 'rm -f "\$TMP_SCRIPT"' EXIT
curl -fsSL "\$SCRIPT_URL" -o "\$TMP_SCRIPT" || exit 1
bash "\$TMP_SCRIPT" "\$@"
EOF
        chmod +x "$INSTALLER_PATH"
    fi

    cat >"$SHORTCUT_PATH" <<EOF
#!/bin/bash
if [[ ! -f "$INSTALLER_PATH" ]]; then
    echo "未找到安装器脚本 $INSTALLER_PATH，请重新上传 install.sh 并执行安装。" >&2
    exit 1
fi
exec bash "$INSTALLER_PATH" "\$@"
EOF
    chmod +x "$SHORTCUT_PATH"

    cat >"$LEGACY_SHORTCUT_PATH" <<EOF
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
        ubuntu | debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y bash curl wget unzip openssl ca-certificates jq coreutils iproute2 procps
            ;;
        centos | rhel | rocky | almalinux | fedora)
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
    cat >/etc/sysctl.d/99-xray-installer-bbr.conf <<EOF
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
        cat >"$CONFIG_FILE" <<'JSON'
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
    ' "$CONFIG_FILE" >"$tmp" && mv "$tmp" "$CONFIG_FILE"
    rm -f "$tmp"
    ensure_default_safety_blocks || return 1
    ensure_config_security
}

init_state() {
    mkdir -p "$CONFIG_DIR"
    [[ -f "$STATE_FILE" ]] || echo '{}' >"$STATE_FILE"
    if ! jq empty "$STATE_FILE" >/dev/null 2>&1; then
        mv "$STATE_FILE" "${STATE_FILE}.broken.$(date +%Y%m%d%H%M%S)"
        echo '{}' >"$STATE_FILE"
    fi

    local tmp
    tmp="$(mktemp)"
    jq '
      (if (.vless_encryption? | type) == "object" then
        .vless_encryption |= del(.flow)
      else
        .
      end) |
      .meta = (.meta // {}) |
      .forwards = (if (.forwards? | type) == "array" then .forwards else [] end)
    ' "$STATE_FILE" >"$tmp" && mv "$tmp" "$STATE_FILE"
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
    ' "$STATE_FILE" >"$tmp"; then
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
    local latest_backup candidate

    latest_backup=""
    for candidate in "${CONFIG_FILE}.bak."*; do
        [[ -f "$candidate" ]] || continue
        if [[ -z "$latest_backup" || "$candidate" -nt "$latest_backup" ]]; then
            latest_backup="$candidate"
        fi
    done
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
        cat >"/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
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
        cat >"/etc/init.d/${SERVICE_NAME}" <<EOF
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
        22 | 53 | 80 | 123 | 443 | 3306 | 5432 | 6379 | 8080)
            info "[提示] ${port} 是常见服务端口，请确认不会影响现有业务。"
            ;;
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
       ' "$CONFIG_FILE" >"$tmp"; then
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
        native | xorpub | random) ;;
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
    read -r -a VLESS_BLOCKS <<<"$value"
    IFS="$old_ifs"

    if ((${#VLESS_BLOCKS[@]} < 4)); then
        err "[VLESS] vlessenc 字符串 block 数不足，无法安全改写。"
        return 1
    fi

    if [[ "${VLESS_BLOCKS[0]}" != "mlkem768x25519plus" ]]; then
        err "[VLESS] 未识别的握手方法: ${VLESS_BLOCKS[0]}"
        return 1
    fi

    case "${VLESS_BLOCKS[1]}" in
        native | xorpub | random) ;;
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
       ' "$STATE_FILE" >"$tmp" && mv "$tmp" "$STATE_FILE"
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
       ' "$CONFIG_FILE" >"$tmp" && mv "$tmp" "$CONFIG_FILE"
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
       ' "$CONFIG_FILE" >"$tmp" && mv "$tmp" "$CONFIG_FILE"
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
        --arg forward_prefix "$FORWARD_TAG_PREFIX" \
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
        def forward_relay_rule:
          (.type == "field") and
          (.outboundTag == "direct") and
          (((.inboundTag // []) | if type == "array" then any(.[]; startswith($forward_prefix)) else false end));

        .outbounds = (.outbounds // []) |
        if ((.outbounds | map(select(.tag == $block)) | length) > 0) then
          .
        else
          .outbounds += [{"tag": $block, "protocol": "blackhole"}]
        end |
        .routing = (.routing // {}) |
        .routing.rules = (
        ((.routing.rules // []) | map(select(forward_relay_rule))) + [
          {"type": "field", "protocol": ["bittorrent"], "outboundTag": $block},
          private_rule,
          {"type": "field", "port": $ports, "outboundTag": $block}
        ] + ((.routing.rules // []) | map(select((default_safety_rule or forward_relay_rule) | not))))
      ' "$CONFIG_FILE" >"$tmp"; then
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
        ' "$CONFIG_FILE" >"$tmp"; then
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
        ' "$CONFIG_FILE" >"$tmp"; then
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
            *)
                err "无效选项。"
                return 1
                ;;
        esac
    else
        echo " 1) 开启增强安全屏蔽"
        echo " 2) 保持关闭"
        read -r -p "选项 (默认: 2): " choice
        case "${choice:-2}" in
            1) set_enhanced_safety_block "true" ;;
            2) info "[安全] 保持关闭。" ;;
            *)
                err "无效选项。"
                return 1
                ;;
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
        off | basic | enhanced) ;;
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
        ' "$CONFIG_FILE" >"$tmp"; then
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
        ' "$CONFIG_FILE" >"$tmp"; then
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
        ' "$CONFIG_FILE" >"$tmp"; then
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
        *)
            err "无效选项。"
            return 1
            ;;
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

random_short_suffix() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 2
    else
        printf '%04x' "$((RANDOM % 65536))"
    fi
}

port_in_csv() {
    local port="$1"
    local csv="$2"
    local item
    local -a _port_items

    IFS=',' read -ra _port_items <<<"$csv"
    for item in "${_port_items[@]}"; do
        [[ "$port" == "$item" ]] && return 0
    done
    return 1
}

is_private_target_address() {
    local target="${1,,}"
    local ip a b _unused_c _unused_d

    target="${target#[}"
    target="${target%]}"
    ip="${target%%/*}"

    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS='.' read -r a b _unused_c _unused_d <<<"$ip"
        a=$((10#$a))
        b=$((10#$b))
        if ((a == 10 || a == 127)); then
            return 0
        fi
        if ((a == 172 && b >= 16 && b <= 31)); then
            return 0
        fi
        if ((a == 192 && b == 168)); then
            return 0
        fi
        if ((a == 169 && b == 254)); then
            return 0
        fi
        if ((a == 100 && b >= 64 && b <= 127)); then
            return 0
        fi
        return 1
    fi

    case "$ip" in
        ::1 | 0:0:0:0:0:0:0:1 | fc*:* | fd*:* | fe80:*)
            return 0
            ;;
    esac

    return 1
}

confirm_forward_warning() {
    local message="$1"
    local confirm

    info "[提示] $message"
    read -r -p "是否继续? [y/N]: " confirm
    [[ "$confirm" =~ ^[yY]$ ]]
}

confirm_forward_safety_warnings() {
    if [[ "${FORWARD_MODE:-safe}" == "relay" ]]; then
        confirm_forward_relay_warnings
        return $?
    fi

    if port_in_csv "$FORWARD_TARGET_PORT" "$DEFAULT_SAFETY_BLOCK_PORTS"; then
        confirm_forward_warning "目标端口属于默认安全屏蔽范围，转发可能无法工作。" || return 1
    fi

    if port_in_csv "$FORWARD_TARGET_PORT" "$ENHANCED_SAFETY_BLOCK_PORTS"; then
        confirm_forward_warning "目标端口属于增强安全屏蔽范围，如果增强安全屏蔽已启用，转发可能无法工作。" || return 1
    fi

    if is_private_target_address "$FORWARD_TARGET"; then
        confirm_forward_warning "目标地址可能属于私网，当前默认安全屏蔽可能会阻断该转发。" || return 1
    fi

    return 0
}

confirm_forward_relay_warnings() {
    local confirm risky="false"

    info "[提示] 专用中转模式会为该转发规则添加 inboundTag -> direct 放行规则，可能绕过默认安全屏蔽，仅建议用于可信固定目标。"
    read -r -p "请输入 YES 继续: " confirm
    [[ "$confirm" == "YES" ]] || return 1

    if port_in_csv "$FORWARD_TARGET_PORT" "$DEFAULT_SAFETY_BLOCK_PORTS" ||
        port_in_csv "$FORWARD_TARGET_PORT" "$ENHANCED_SAFETY_BLOCK_PORTS" ||
        is_private_target_address "$FORWARD_TARGET"; then
        risky="true"
    fi

    if [[ "$risky" == "true" ]]; then
        info "[提示] 目标命中高风险端口或私网地址；relay 模式会为该 forward inbound 使用 direct 放行。"
        read -r -p "请再次输入 YES 继续: " confirm
        [[ "$confirm" == "YES" ]] || return 1
    fi

    return 0
}

validate_forward_network() {
    case "$1" in
        tcp | udp | tcp,udp) return 0 ;;
        *) return 1 ;;
    esac
}

validate_forward_mode() {
    case "$1" in
        safe | relay) return 0 ;;
        *) return 1 ;;
    esac
}

forward_tag_exists() {
    local tag="$1"

    if [[ -f "$CONFIG_FILE" ]] && jq -e --arg tag "$tag" 'any(.inbounds[]?; .tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1; then
        return 0
    fi
    if [[ -f "$STATE_FILE" ]] && jq -e --arg tag "$tag" 'any(.forwards[]?; .tag == $tag)' "$STATE_FILE" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

generate_forward_tag() {
    local base

    base="${FORWARD_TAG_PREFIX}${FORWARD_LISTEN_PORT}-${FORWARD_TARGET_PORT}"
    FORWARD_TAG="$(generate_unique_forward_tag_from_base "$base")"
}

generate_unique_forward_tag_from_base() {
    local base="$1"
    local suffix tag

    [[ -n "$base" ]] || {
        err "[失败] [端口转发] 生成 tag 失败：base 为空。"
        return 1
    }
    tag="$base"
    while forward_tag_exists "$tag"; do
        suffix="$(random_short_suffix)"
        tag="${base}-${suffix}"
    done
    printf '%s' "$tag"
}

forward_rule_lines() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0

    jq -r --arg prefix "$FORWARD_TAG_PREFIX" '
      .inbounds[]? |
      select((.tag // "") | startswith($prefix)) |
      select(.protocol == "dokodemo-door") |
      [
        .tag,
        (.listen // "0.0.0.0"),
        (.port | tostring),
        (.settings.address // ""),
        (.settings.port | tostring),
        (.settings.network // "tcp")
      ] | @tsv
    ' "$CONFIG_FILE" 2>/dev/null
}

forward_state_lines() {
    [[ -f "$STATE_FILE" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0

    jq -r '
      .forwards[]? |
      [
        (.tag // ""),
        (.listen // "0.0.0.0"),
        (.listen_port | tostring),
        (.target // ""),
        (.target_port | tostring),
        (.network // "tcp"),
        (.mode // "safe"),
        (.remark // ""),
        ((.enabled // true) | tostring)
      ] | @tsv
    ' "$STATE_FILE" 2>/dev/null
}

forward_config_has_tag() {
    local tag="$1"

    [[ -f "$CONFIG_FILE" ]] || return 1
    jq -e --arg tag "$tag" '
      any(.inbounds[]?; (.tag == $tag) and (.protocol == "dokodemo-door"))
    ' "$CONFIG_FILE" >/dev/null 2>&1
}

forward_tag_known() {
    local tag="$1"

    forward_config_has_tag "$tag" && return 0
    [[ -f "$STATE_FILE" ]] || return 1
    jq -e --arg tag "$tag" 'any(.forwards[]?; .tag == $tag)' "$STATE_FILE" >/dev/null 2>&1
}

forward_rule_count() {
    [[ -f "$CONFIG_FILE" ]] || {
        printf '%s' "0"
        return 0
    }
    command -v jq >/dev/null 2>&1 || {
        printf '%s' "0"
        return 0
    }

    jq -r --arg prefix "$FORWARD_TAG_PREFIX" '
      [ .inbounds[]? |
        select((.tag // "") | startswith($prefix)) |
        select(.protocol == "dokodemo-door")
      ] | length
    ' "$CONFIG_FILE" 2>/dev/null
}

forward_remark_for_tag() {
    local tag="$1"

    [[ -f "$STATE_FILE" ]] || return 0
    jq -r --arg tag "$tag" '.forwards[]? | select(.tag == $tag) | .remark // empty' "$STATE_FILE" 2>/dev/null | head -n 1
}

forward_mode_for_tag() {
    local tag="$1"

    if [[ -f "$CONFIG_FILE" ]] && jq -e --arg tag "$tag" '
      any(.routing.rules[]?;
        (.type == "field") and
        (.outboundTag == "direct") and
        (((.inboundTag // []) | if type == "array" then any(.[]; . == $tag) else false end))
      )
    ' "$CONFIG_FILE" >/dev/null 2>&1; then
        printf '%s' "relay"
    else
        printf '%s' "safe"
    fi
}

forward_all_lines() {
    local line tag listen listen_port target target_port network mode remark enabled seen_tags
    seen_tags="|"

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        IFS=$'\t' read -r tag listen listen_port target target_port network <<<"$line"
        [[ -n "$tag" ]] || continue
        mode="$(forward_mode_for_tag "$tag")"
        remark="$(forward_remark_for_tag "$tag")"
        printf '启用\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$mode" "$tag" "$listen" "$listen_port" "$target" "$target_port" "$network" "$remark"
        seen_tags="${seen_tags}${tag}|"
    done < <(forward_rule_lines)

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        IFS=$'\t' read -r tag listen listen_port target target_port network mode remark enabled <<<"$line"
        [[ -n "$tag" ]] || continue
        [[ "$seen_tags" == *"|${tag}|"* ]] && continue
        printf '停用\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${mode:-safe}" "$tag" "$listen" "$listen_port" "$target" "$target_port" "${network:-tcp}" "$remark"
    done < <(forward_state_lines)
}

load_forward_vars_from_tag() {
    local tag="$1"
    local line

    if forward_config_has_tag "$tag"; then
        line="$(jq -r --arg tag "$tag" '
          .inbounds[]? |
          select((.tag == $tag) and (.protocol == "dokodemo-door")) |
          [
            .tag,
            (.listen // "0.0.0.0"),
            (.port | tostring),
            (.settings.address // ""),
            (.settings.port | tostring),
            (.settings.network // "tcp")
          ] | @tsv
        ' "$CONFIG_FILE" 2>/dev/null | head -n 1)"
        [[ -n "$line" ]] || return 1
        IFS=$'\t' read -r FORWARD_TAG FORWARD_LISTEN FORWARD_LISTEN_PORT FORWARD_TARGET FORWARD_TARGET_PORT FORWARD_NETWORK <<<"$line"
        FORWARD_MODE="$(forward_mode_for_tag "$FORWARD_TAG")"
        FORWARD_REMARK="$(forward_remark_for_tag "$FORWARD_TAG")"
        FORWARD_ENABLED="true"
        return 0
    fi

    [[ -f "$STATE_FILE" ]] || return 1
    line="$(jq -r --arg tag "$tag" '
      .forwards[]? |
      select(.tag == $tag) |
      [
        .tag,
        (.listen // "0.0.0.0"),
        (.listen_port | tostring),
        (.target // ""),
        (.target_port | tostring),
        (.network // "tcp"),
        (.mode // "safe"),
        (.remark // ""),
        ((.enabled // false) | tostring)
      ] | @tsv
    ' "$STATE_FILE" 2>/dev/null | head -n 1)"
    [[ -n "$line" ]] || return 1
    IFS=$'\t' read -r FORWARD_TAG FORWARD_LISTEN FORWARD_LISTEN_PORT FORWARD_TARGET FORWARD_TARGET_PORT FORWARD_NETWORK FORWARD_MODE FORWARD_REMARK FORWARD_ENABLED <<<"$line"
}

select_forward_tag() {
    local filter="${1:-all}"
    local direct_tag="${2:-}"
    local line status mode tag listen listen_port target target_port network remark
    local records=()
    local tags=()
    local idx selected

    if [[ -n "$direct_tag" ]]; then
        if forward_tag_known "$direct_tag"; then
            SELECTED_FORWARD_TAG="$direct_tag"
            return 0
        fi
        err "[失败] 未找到转发规则: $direct_tag"
        return 1
    fi

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        IFS=$'\t' read -r status mode tag listen listen_port target target_port network remark <<<"$line"
        case "$filter" in
            enabled) [[ "$status" == "启用" ]] || continue ;;
            disabled) [[ "$status" == "停用" ]] || continue ;;
        esac
        records+=("$line")
        tags+=("$tag")
    done < <(forward_all_lines)

    if [[ ${#records[@]} -eq 0 ]]; then
        err "[失败] 没有可选择的转发规则。"
        return 1
    fi

    echo -e "\n${YELLOW}[端口转发] 选择规则${PLAIN}"
    idx=1
    for line in "${records[@]}"; do
        IFS=$'\t' read -r status mode tag listen listen_port target target_port network remark <<<"$line"
        if [[ -n "$remark" ]]; then
            echo " ${idx}) ${status} ${mode} ${tag}: ${listen}:${listen_port} -> ${target}:${target_port}/${network} ${remark}"
        else
            echo " ${idx}) ${status} ${mode} ${tag}: ${listen}:${listen_port} -> ${target}:${target_port}/${network}"
        fi
        ((idx++))
    done

    read -r -p "请选择规则编号: " selected
    if ! [[ "$selected" =~ ^[0-9]+$ ]] || ((selected < 1 || selected > ${#tags[@]})); then
        err "[失败] [端口转发] 无效编号。"
        return 1
    fi

    SELECTED_FORWARD_TAG="${tags[$((selected - 1))]}"
}

list_forward_rules() {
    local line status tag listen listen_port target target_port network mode remark
    local rules=()

    if ! command -v jq >/dev/null 2>&1; then
        err "[失败] [端口转发] 缺少 jq，无法读取配置。"
        return 1
    fi
    if [[ ! -f "$CONFIG_FILE" ]]; then
        info "[端口转发] 未找到配置文件，请先安装 Xray 或协议。"
        return 0
    fi

    mapfile -t rules < <(forward_all_lines)
    if [[ ${#rules[@]} -eq 0 ]]; then
        info "[端口转发] 当前未配置转发规则。"
        return 0
    fi

    echo -e "\n${YELLOW}--- 中转/端口转发 ---${PLAIN}"
    printf '%-6s %-6s %s\n' "状态" "模式" "规则"
    for line in "${rules[@]}"; do
        IFS=$'\t' read -r status mode tag listen listen_port target target_port network remark <<<"$line"
        if [[ -n "$remark" ]]; then
            printf '%-6s %-6s %s: %s:%s -> %s:%s/%s %s\n' "$status" "$mode" "$tag" "$listen" "$listen_port" "$target" "$target_port" "$network" "$remark"
        else
            printf '%-6s %-6s %s: %s:%s -> %s:%s/%s\n' "$status" "$mode" "$tag" "$listen" "$listen_port" "$target" "$target_port" "$network"
        fi
    done
}

state_sync_forward_rule() {
    local tmp

    init_state
    tmp="$(mktemp)" || {
        err "[失败] [端口转发] 创建状态临时文件失败。"
        return 1
    }

    if ! jq --arg tag "$FORWARD_TAG" \
        --arg listen "$FORWARD_LISTEN" \
        --arg listen_port "$FORWARD_LISTEN_PORT" \
        --arg target "$FORWARD_TARGET" \
        --arg target_port "$FORWARD_TARGET_PORT" \
        --arg network "$FORWARD_NETWORK" \
        --arg mode "$FORWARD_MODE" \
        --arg enabled "${FORWARD_ENABLED:-true}" \
        --arg remark "$FORWARD_REMARK" '
        .forwards = ((.forwards // []) | map(select(.tag != $tag))) |
        .forwards += [{
          "tag": $tag,
          "listen": $listen,
          "listen_port": ($listen_port | tonumber),
          "target": $target,
          "target_port": ($target_port | tonumber),
          "network": $network,
          "mode": $mode,
          "enabled": ($enabled == "true"),
          "remark": $remark
        }]
      ' "$STATE_FILE" >"$tmp"; then
        rm -f "$tmp"
        err "[失败] [端口转发] 写入状态文件失败。"
        return 1
    fi

    if ! mv "$tmp" "$STATE_FILE"; then
        rm -f "$tmp"
        err "[失败] [端口转发] 更新状态文件失败。"
        return 1
    fi
    ensure_config_security
}

state_delete_forward_rule() {
    local tag="$1"
    local tmp

    [[ -f "$STATE_FILE" ]] || return 0
    tmp="$(mktemp)" || {
        err "[失败] [端口转发] 创建状态临时文件失败。"
        return 1
    }

    if ! jq --arg tag "$tag" '.forwards = ((.forwards // []) | map(select(.tag != $tag)))' "$STATE_FILE" >"$tmp"; then
        rm -f "$tmp"
        err "[失败] [端口转发] 删除状态记录失败。"
        return 1
    fi

    if ! mv "$tmp" "$STATE_FILE"; then
        rm -f "$tmp"
        err "[失败] [端口转发] 更新状态文件失败。"
        return 1
    fi
    ensure_config_security
}

configure_forward_rule() {
    local input

    FORWARD_MODE="${1:-${FORWARD_MODE:-safe}}"
    validate_forward_mode "$FORWARD_MODE" || {
        err "[失败] [端口转发] 未知转发模式: $FORWARD_MODE"
        return 1
    }

    echo -e "\n${YELLOW}[中转/端口转发] 添加转发规则 (${FORWARD_MODE})${PLAIN}"
    read -r -p "本机监听地址 (默认: 0.0.0.0): " FORWARD_LISTEN
    FORWARD_LISTEN="${FORWARD_LISTEN:-0.0.0.0}"
    if [[ "$FORWARD_LISTEN" =~ [[:space:]] || -z "$FORWARD_LISTEN" ]]; then
        err "[失败] [端口转发] 本机监听地址无效。"
        return 1
    fi

    ask_port "本机监听端口" "30000" FORWARD_LISTEN_PORT || return 1

    read -r -p "目标地址，例如 1.2.3.4 或 example.com: " FORWARD_TARGET
    if [[ -z "$FORWARD_TARGET" || "$FORWARD_TARGET" =~ [[:space:]] ]]; then
        err "[失败] [端口转发] 目标地址无效。"
        return 1
    fi

    while true; do
        read -r -p "目标端口: " FORWARD_TARGET_PORT
        if validate_port "$FORWARD_TARGET_PORT"; then
            break
        fi
        err "端口无效，请输入 1-65535 之间的数字。"
    done

    read -r -p "网络类型 tcp / udp / tcp,udp (默认: tcp): " input
    FORWARD_NETWORK="${input:-tcp}"
    if ! validate_forward_network "$FORWARD_NETWORK"; then
        err "[失败] [端口转发] 网络类型无效，仅支持 tcp、udp、tcp,udp。"
        return 1
    fi

    read -r -p "备注名称，可选: " FORWARD_REMARK
    confirm_forward_safety_warnings || {
        err "[取消] 已取消添加端口转发。"
        return 1
    }
}

remove_forward_config_by_tag() {
    local tag="$1"
    local tmp

    [[ -f "$CONFIG_FILE" ]] || return 0

    tmp="$(mktemp)" || {
        err "[失败] [端口转发] 创建临时文件失败。"
        return 1
    }

    if ! jq --arg tag "$tag" --arg prefix "$FORWARD_TAG_PREFIX" '
        def selected_relay_rule:
          (.type == "field") and
          (.outboundTag == "direct") and
          (((.inboundTag // []) | if type == "array" then any(.[]; . == $tag) else false end));
        .inbounds = ((.inbounds // []) | map(select((.tag != $tag) or ((.tag // "") | startswith($prefix) | not)))) |
        .routing = (.routing // {}) |
        .routing.rules = ((.routing.rules // []) | map(select((selected_relay_rule) | not)))
      ' "$CONFIG_FILE" >"$tmp"; then
        rm -f "$tmp"
        err "[失败] [端口转发] 生成配置失败。"
        return 1
    fi

    if ! mv "$tmp" "$CONFIG_FILE"; then
        rm -f "$tmp"
        err "[失败] [端口转发] 写入 $CONFIG_FILE 失败。"
        return 1
    fi
}

write_forward_config_from_vars() {
    local tmp

    FORWARD_ENABLED="${FORWARD_ENABLED:-true}"
    tmp="$(mktemp)" || {
        err "[失败] [端口转发] 创建临时文件失败。"
        return 1
    }

    if ! jq --arg tag "$FORWARD_TAG" \
        --arg prefix "$FORWARD_TAG_PREFIX" \
        --arg listen "$FORWARD_LISTEN" \
        --arg listen_port "$FORWARD_LISTEN_PORT" \
        --arg target "$FORWARD_TARGET" \
        --arg target_port "$FORWARD_TARGET_PORT" \
        --arg network "$FORWARD_NETWORK" \
        --arg mode "$FORWARD_MODE" \
        --arg enabled "$FORWARD_ENABLED" '
        def relay_rule:
          {"type": "field", "inboundTag": [$tag], "outboundTag": "direct"};
        def selected_relay_rule:
          (.type == "field") and
          (.outboundTag == "direct") and
          (((.inboundTag // []) | if type == "array" then any(.[]; . == $tag) else false end));
        def forward_inbound:
          {
            "tag": $tag,
            "listen": $listen,
            "port": ($listen_port | tonumber),
            "protocol": "dokodemo-door",
            "settings": {
              "address": $target,
              "port": ($target_port | tonumber),
              "network": $network
            }
          };
        .inbounds = ((.inbounds // []) | map(select((.tag != $tag) or ((.tag // "") | startswith($prefix) | not)))) |
        .routing = (.routing // {}) |
        .routing.rules = ((.routing.rules // []) | map(select((selected_relay_rule) | not))) |
        if $enabled == "true" then
          .inbounds += [forward_inbound] |
          if $mode == "relay" then
            .routing.rules = ([relay_rule] + ((.routing.rules // []) | map(select(. != relay_rule))))
          else
            .
          end
        else
          .
        end
      ' "$CONFIG_FILE" >"$tmp"; then
        rm -f "$tmp"
        err "[失败] [端口转发] 生成配置失败。"
        return 1
    fi

    if ! mv "$tmp" "$CONFIG_FILE"; then
        rm -f "$tmp"
        err "[失败] [端口转发] 写入 $CONFIG_FILE 失败。"
        return 1
    fi
}

install_forward_rule() {
    FORWARD_MODE="${FORWARD_MODE:-safe}"
    FORWARD_ENABLED="true"
    validate_forward_mode "$FORWARD_MODE" || {
        err "[失败] [端口转发] 未知转发模式: $FORWARD_MODE"
        return 1
    }

    install_or_update_xray || {
        err "[失败] [端口转发] Xray 安装/更新失败。"
        return 1
    }
    generate_forward_tag
    backup_config || {
        err "[失败] [端口转发] 配置备份失败。"
        return 1
    }

    write_forward_config_from_vars || return 1

    if ! apply_config "端口转发"; then
        err "[失败] [端口转发] 应用配置失败。"
        return 1
    fi

    state_sync_forward_rule || err "[状态] 转发状态记录失败，但 config.json 已生效。"
    state_set_meta_action "添加端口转发" || err "[状态] 最近变更记录失败。"
    ok "[完成] 端口转发已添加: ${FORWARD_TAG}"
}

delete_forward_rule() {
    local selected_tag="${1:-}"

    select_forward_tag "all" "$selected_tag" || return 1
    selected_tag="$SELECTED_FORWARD_TAG"

    if ! forward_config_has_tag "$selected_tag"; then
        state_delete_forward_rule "$selected_tag" || err "[状态] 转发状态记录删除失败。"
        state_set_meta_action "删除端口转发" || err "[状态] 最近变更记录失败。"
        ok "[完成] 已删除停用转发规则: ${selected_tag}"
        return 0
    fi

    backup_config || {
        err "[失败] [端口转发] 配置备份失败。"
        return 1
    }

    remove_forward_config_by_tag "$selected_tag" || return 1

    if ! apply_config "端口转发"; then
        err "[失败] [端口转发] 应用删除失败。"
        return 1
    fi

    state_delete_forward_rule "$selected_tag" || err "[状态] 转发状态记录删除失败，但 config.json 已生效。"
    state_set_meta_action "删除端口转发" || err "[状态] 最近变更记录失败。"
    ok "[完成] 端口转发已删除: ${selected_tag}"
}

set_forward_enabled() {
    local enable="$1"
    local selected_tag="${2:-}"
    local filter action context

    if [[ "$enable" == "true" ]]; then
        filter="disabled"
        action="启用"
    else
        filter="enabled"
        action="停用"
    fi

    select_forward_tag "$filter" "$selected_tag" || return 1
    selected_tag="$SELECTED_FORWARD_TAG"
    load_forward_vars_from_tag "$selected_tag" || {
        err "[失败] [端口转发] 无法读取规则: $selected_tag"
        return 1
    }

    if [[ "$enable" == "true" && "$FORWARD_ENABLED" == "true" ]] && forward_config_has_tag "$FORWARD_TAG"; then
        info "[端口转发] 规则已启用: $FORWARD_TAG"
        return 0
    fi
    if [[ "$enable" == "false" ]] && ! forward_config_has_tag "$FORWARD_TAG"; then
        FORWARD_ENABLED="false"
        state_sync_forward_rule || err "[状态] 转发状态记录失败。"
        info "[端口转发] 规则已停用: $FORWARD_TAG"
        return 0
    fi

    if [[ "$enable" == "true" ]]; then
        install_or_update_xray || return 1
    fi

    backup_config || {
        err "[失败] [端口转发] 配置备份失败。"
        return 1
    }

    FORWARD_ENABLED="$enable"
    if [[ "$enable" == "true" ]]; then
        write_forward_config_from_vars || return 1
    else
        remove_forward_config_by_tag "$FORWARD_TAG" || return 1
    fi

    if ! apply_config "端口转发"; then
        err "[失败] [端口转发] ${action}失败。"
        return 1
    fi

    state_sync_forward_rule || err "[状态] 转发状态记录失败，但 config.json 已生效。"
    context="${action}端口转发"
    state_set_meta_action "$context" || err "[状态] 最近变更记录失败。"
    ok "[完成] ${context}: ${FORWARD_TAG}"
}

prompt_forward_port_value() {
    local label="$1"
    local current="$2"
    local __resultvar="$3"
    local input

    while true; do
        read -r -p "${label} (当前: ${current}): " input
        input="${input:-$current}"
        if validate_port "$input"; then
            printf -v "$__resultvar" '%s' "$input"
            return 0
        fi
        err "端口无效，请输入 1-65535 之间的数字。"
    done
}

edit_forward_rule() {
    local selected_tag="${1:-}"
    local old_tag old_listen_port old_target_port input regen_tag

    select_forward_tag "all" "$selected_tag" || return 1
    load_forward_vars_from_tag "$SELECTED_FORWARD_TAG" || {
        err "[失败] [端口转发] 无法读取规则: $SELECTED_FORWARD_TAG"
        return 1
    }

    old_tag="$FORWARD_TAG"
    old_listen_port="$FORWARD_LISTEN_PORT"
    old_target_port="$FORWARD_TARGET_PORT"

    echo -e "\n${YELLOW}[端口转发] 修改规则: ${old_tag}${PLAIN}"
    read -r -p "本机监听地址 (当前: ${FORWARD_LISTEN}): " input
    [[ -n "$input" ]] && FORWARD_LISTEN="$input"
    [[ -z "$FORWARD_LISTEN" || "$FORWARD_LISTEN" =~ [[:space:]] ]] && {
        err "[失败] [端口转发] 本机监听地址无效。"
        return 1
    }

    prompt_forward_port_value "本机监听端口" "$FORWARD_LISTEN_PORT" FORWARD_LISTEN_PORT || return 1

    read -r -p "目标地址 (当前: ${FORWARD_TARGET}): " input
    [[ -n "$input" ]] && FORWARD_TARGET="$input"
    [[ -z "$FORWARD_TARGET" || "$FORWARD_TARGET" =~ [[:space:]] ]] && {
        err "[失败] [端口转发] 目标地址无效。"
        return 1
    }

    prompt_forward_port_value "目标端口" "$FORWARD_TARGET_PORT" FORWARD_TARGET_PORT || return 1

    read -r -p "网络类型 tcp / udp / tcp,udp (当前: ${FORWARD_NETWORK}): " input
    [[ -n "$input" ]] && FORWARD_NETWORK="$input"
    validate_forward_network "$FORWARD_NETWORK" || {
        err "[失败] [端口转发] 网络类型无效。"
        return 1
    }

    read -r -p "模式 safe / relay (当前: ${FORWARD_MODE}): " input
    [[ -n "$input" ]] && FORWARD_MODE="$input"
    validate_forward_mode "$FORWARD_MODE" || {
        err "[失败] [端口转发] 模式无效。"
        return 1
    }

    read -r -p "备注名称 (当前: ${FORWARD_REMARK:-无}): " input
    [[ -n "$input" ]] && FORWARD_REMARK="$input"

    confirm_forward_safety_warnings || {
        err "[取消] 已取消修改端口转发。"
        return 1
    }

    if [[ "$FORWARD_LISTEN_PORT" != "$old_listen_port" || "$FORWARD_TARGET_PORT" != "$old_target_port" ]]; then
        read -r -p "监听端口或目标端口已改变，是否重新生成 tag? [y/N]: " regen_tag
        if [[ "$regen_tag" =~ ^[yY]$ ]]; then
            generate_forward_tag
        else
            FORWARD_TAG="$old_tag"
        fi
    fi

    FORWARD_ENABLED="true"
    install_or_update_xray || return 1
    backup_config || {
        err "[失败] [端口转发] 配置备份失败。"
        return 1
    }

    remove_forward_config_by_tag "$old_tag" || return 1
    write_forward_config_from_vars || return 1

    if ! apply_config "端口转发"; then
        err "[失败] [端口转发] 修改失败。"
        return 1
    fi

    if [[ "$FORWARD_TAG" != "$old_tag" ]]; then
        state_delete_forward_rule "$old_tag" || err "[状态] 旧转发状态删除失败，但 config.json 已生效。"
    fi
    state_sync_forward_rule || err "[状态] 转发状态记录失败，但 config.json 已生效。"
    state_set_meta_action "修改端口转发" || err "[状态] 最近变更记录失败。"
    ok "[完成] 端口转发已修改: ${FORWARD_TAG}"
}

forward_target_is_ip_literal() {
    local target="$1"

    [[ "$target" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$target" == *:* ]]
}

test_forward_rule() {
    local selected_tag="${1:-}"
    local status nc_bin

    select_forward_tag "all" "$selected_tag" || return 1
    load_forward_vars_from_tag "$SELECTED_FORWARD_TAG" || {
        err "[失败] [端口转发] 无法读取规则: $SELECTED_FORWARD_TAG"
        return 1
    }

    status="停用"
    forward_config_has_tag "$FORWARD_TAG" && status="启用"

    echo -e "\n${YELLOW}--- 转发目标测试 ---${PLAIN}"
    echo "规则: ${FORWARD_TAG} [${FORWARD_MODE}] (${status})"
    echo "链路: ${FORWARD_LISTEN}:${FORWARD_LISTEN_PORT} -> ${FORWARD_TARGET}:${FORWARD_TARGET_PORT}/${FORWARD_NETWORK}"
    [[ -n "$FORWARD_REMARK" ]] && echo "备注: ${FORWARD_REMARK}"

    if ! forward_target_is_ip_literal "$FORWARD_TARGET"; then
        if command -v getent >/dev/null 2>&1; then
            echo -e "\n[解析] getent ahosts ${FORWARD_TARGET}"
            getent ahosts "$FORWARD_TARGET" || info "[解析] 未获得解析结果。"
        else
            info "[解析] 缺少 getent，已跳过域名解析测试。"
        fi
    fi

    if [[ "$FORWARD_NETWORK" == *tcp* ]]; then
        nc_bin="$(command -v nc || true)"
        if [[ -n "$nc_bin" ]]; then
            if nc -z -w3 "$FORWARD_TARGET" "$FORWARD_TARGET_PORT" >/dev/null 2>&1; then
                ok "[TCP] 目标 ${FORWARD_TARGET}:${FORWARD_TARGET_PORT} 可连接。"
            else
                err "[TCP] 目标 ${FORWARD_TARGET}:${FORWARD_TARGET_PORT} 连接失败。"
            fi
        else
            info "[TCP] 未检测到 nc，请安装 netcat-openbsd 后重试，或跳过目标连通性测试。"
        fi
    fi

    if [[ "$FORWARD_NETWORK" == *udp* ]]; then
        info "[UDP] UDP 无法通过简单握手可靠判断，仅检查配置和本地监听。"
    fi

    if command -v ss >/dev/null 2>&1; then
        echo -e "\n[监听] ss -tulpn | grep ${FORWARD_LISTEN_PORT}"
        ss -tulpn 2>/dev/null | grep -E "[:.]${FORWARD_LISTEN_PORT}[[:space:]]" | grep xray || info "[监听] 未看到 xray 监听该端口。"
    else
        info "[监听] 缺少 ss，无法检查本机监听。"
    fi
}

export_forward_rules() {
    local timestamp outfile

    command -v jq >/dev/null 2>&1 || {
        err "[失败] [端口转发] 缺少 jq，无法导出。"
        return 1
    }

    timestamp="$(date +%Y%m%d%H%M%S)"
    outfile="${FORWARD_EXPORT_DIR:-/root}/xray-forwards-${timestamp}.json"

    if [[ -f "$STATE_FILE" ]] && jq -e '((.forwards // []) | length) > 0' "$STATE_FILE" >/dev/null 2>&1; then
        jq '{forwards: (.forwards // [])}' "$STATE_FILE" >"$outfile" || {
            err "[失败] [端口转发] 导出 state 失败。"
            return 1
        }
    elif [[ -f "$CONFIG_FILE" ]]; then
        jq --arg prefix "$FORWARD_TAG_PREFIX" '
          . as $root |
          {
            forwards: [
              $root.inbounds[]? |
              select((.tag // "") | startswith($prefix)) |
              select(.protocol == "dokodemo-door") |
              . as $in |
              {
                tag: $in.tag,
                listen: ($in.listen // "0.0.0.0"),
                listen_port: $in.port,
                target: ($in.settings.address // ""),
                target_port: $in.settings.port,
                network: ($in.settings.network // "tcp"),
                mode: (if any($root.routing.rules[]?; (.type == "field") and (.outboundTag == "direct") and (((.inboundTag // []) | if type == "array" then any(.[]; . == $in.tag) else false end))) then "relay" else "safe" end),
                remark: "",
                enabled: true
              }
            ]
          }
        ' "$CONFIG_FILE" >"$outfile" || {
            err "[失败] [端口转发] 从 config.json 导出失败。"
            return 1
        }
    else
        printf '{\n  "forwards": []\n}\n' >"$outfile"
    fi

    chmod 600 "$outfile" 2>/dev/null || true
    ok "[完成] 转发规则已导出: $outfile"
}

import_forward_rules() {
    local import_file tmp_records line tag listen listen_port target target_port network mode remark enabled choice imported new_tag
    local import_lines=()

    command -v jq >/dev/null 2>&1 || {
        err "[失败] [端口转发] 缺少 jq，无法导入。"
        return 1
    }

    read -r -p "导入文件路径: " import_file
    import_file="${import_file//$'\r'/}"
    [[ -f "$import_file" ]] || {
        err "[失败] [端口转发] 未找到导入文件: $import_file"
        return 1
    }

    jq empty "$import_file" >/dev/null 2>&1 || {
        err "[失败] [端口转发] JSON 格式无效。"
        return 1
    }

    jq -e '
      def src: if type == "array" then . else (.forwards // []) end;
      def valid_port(p): ((try (p | tonumber) catch 0) >= 1 and (try (p | tonumber) catch 0) <= 65535);
      (src | type) == "array" and
      all(src[]?;
        (.tag | type == "string") and (.tag | startswith("forward-")) and
        (.listen | type == "string") and
        valid_port(.listen_port) and
        (.target | type == "string") and
        valid_port(.target_port) and
        ((.network // "tcp") as $n | ["tcp","udp","tcp,udp"] | index($n)) and
        ((.mode // "safe") as $m | ["safe","relay"] | index($m))
      )
    ' "$import_file" >/dev/null || {
        err "[失败] [端口转发] 导入文件缺少必要字段或字段非法。"
        return 1
    }

    install_or_update_xray || return 1
    backup_config || {
        err "[失败] [端口转发] 配置备份失败。"
        return 1
    }

    tmp_records="$(mktemp)" || return 1
    imported=0

    mapfile -t import_lines < <(jq -r '
      def src: if type == "array" then . else (.forwards // []) end;
      src[]? |
      [
        .tag,
        .listen,
        (.listen_port | tostring),
        .target,
        (.target_port | tostring),
        (.network // "tcp"),
        (.mode // "safe"),
        (.remark // ""),
        ((.enabled // true) | tostring)
      ] | @tsv
    ' "$import_file")

    for line in "${import_lines[@]}"; do
        IFS=$'\t' read -r tag listen listen_port target target_port network mode remark enabled <<<"$line"
        tag="${tag//$'\r'/}"
        listen="${listen//$'\r'/}"
        listen_port="${listen_port//$'\r'/}"
        target="${target//$'\r'/}"
        target_port="${target_port//$'\r'/}"
        network="${network//$'\r'/}"
        mode="${mode//$'\r'/}"
        remark="${remark//$'\r'/}"
        enabled="${enabled//$'\r'/}"
        FORWARD_TAG="$tag"
        FORWARD_LISTEN="$listen"
        FORWARD_LISTEN_PORT="$listen_port"
        FORWARD_TARGET="$target"
        FORWARD_TARGET_PORT="$target_port"
        FORWARD_NETWORK="${network:-tcp}"
        FORWARD_MODE="${mode:-safe}"
        FORWARD_REMARK="$remark"
        FORWARD_ENABLED="${enabled:-true}"

        if forward_tag_known "$FORWARD_TAG"; then
            echo -e "\n[冲突] 已存在 tag: ${FORWARD_TAG}"
            echo " 1) 跳过"
            echo " 2) 覆盖"
            echo " 3) 自动改名"
            read -r -p "选项 (默认: 1): " choice
            case "${choice:-1}" in
                2)
                    remove_forward_config_by_tag "$FORWARD_TAG" || return 1
                    state_delete_forward_rule "$FORWARD_TAG" || err "[状态] 覆盖导入时删除旧状态记录失败，将继续写入新记录。"
                    ;;
                3)
                    new_tag="$(generate_unique_forward_tag_from_base "$FORWARD_TAG")" || return 1
                    info "[导入] ${FORWARD_TAG} 已自动改名为 ${new_tag}"
                    FORWARD_TAG="$new_tag"
                    ;;
                *)
                    info "[跳过] ${tag}"
                    continue
                    ;;
            esac
        fi

        write_forward_config_from_vars || return 1
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$FORWARD_TAG" "$FORWARD_LISTEN" "$FORWARD_LISTEN_PORT" "$FORWARD_TARGET" "$FORWARD_TARGET_PORT" "$FORWARD_NETWORK" "$FORWARD_MODE" "$FORWARD_REMARK" "$FORWARD_ENABLED" >>"$tmp_records"
        ((imported += 1))
    done

    if ((imported == 0)); then
        rm -f "$tmp_records"
        info "[端口转发] 没有导入任何规则。"
        return 0
    fi

    if ! apply_config "端口转发"; then
        rm -f "$tmp_records"
        err "[失败] [端口转发] 导入后应用配置失败。"
        return 1
    fi

    while IFS=$'\t' read -r FORWARD_TAG FORWARD_LISTEN FORWARD_LISTEN_PORT FORWARD_TARGET FORWARD_TARGET_PORT FORWARD_NETWORK FORWARD_MODE FORWARD_REMARK FORWARD_ENABLED; do
        state_sync_forward_rule || err "[状态] 转发状态记录失败，但 config.json 已生效。"
    done <"$tmp_records"
    rm -f "$tmp_records"

    state_set_meta_action "导入端口转发" || err "[状态] 最近变更记录失败。"
    ok "[完成] 已导入 ${imported} 条转发规则。"
}

configure_forward_menu() {
    local choice

    while true; do
        echo -e "\n${YELLOW}[中转/端口转发管理]${PLAIN}"
        echo " 1) 添加安全转发（默认，遵守安全规则）"
        echo " 2) 添加专用中转（适合代理落地/内网服务）"
        echo " 3) 查看转发规则"
        echo " 4) 修改转发规则"
        echo " 5) 启用/停用转发规则"
        echo " 6) 删除转发规则"
        echo " 7) 测试转发目标"
        echo " 8) 导出/导入转发规则"
        echo " 9) 返回主菜单"
        read -r -p "选项 (默认: 9): " choice

        case "${choice:-9}" in
            1)
                if ! { prepare_system && configure_forward_rule "safe" && install_forward_rule; }; then
                    err "[失败] 添加安全转发未完成，请查看上方错误信息。"
                fi
                ;;
            2)
                if ! { prepare_system && configure_forward_rule "relay" && install_forward_rule; }; then
                    err "[失败] 添加专用中转未完成，请查看上方错误信息。"
                fi
                ;;
            3)
                list_forward_rules
                ;;
            4)
                if ! { prepare_system && edit_forward_rule; }; then
                    err "[失败] 修改转发规则未完成，请查看上方错误信息。"
                fi
                ;;
            5)
                echo " 1) 启用转发规则"
                echo " 2) 停用转发规则"
                read -r -p "选项: " choice
                case "$choice" in
                    1) prepare_system && set_forward_enabled "true" ;;
                    2) prepare_system && set_forward_enabled "false" ;;
                    *) err "无效选项。" ;;
                esac
                ;;
            6)
                if ! { prepare_system && delete_forward_rule; }; then
                    err "[失败] 删除端口转发未完成，请查看上方错误信息。"
                fi
                ;;
            7)
                test_forward_rule || err "[失败] 测试转发目标未完成，请查看上方错误信息。"
                ;;
            8)
                echo " 1) 导出转发规则"
                echo " 2) 导入转发规则"
                read -r -p "选项: " choice
                case "$choice" in
                    1) export_forward_rules ;;
                    2) prepare_system && import_forward_rules ;;
                    *) err "无效选项。" ;;
                esac
                ;;
            9)
                return 0
                ;;
            *)
                err "无效选项。"
                ;;
        esac

        echo
        read -r -p "按回车返回端口转发菜单..." || return 0
    done
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
    echo -e "端口转发: ${YELLOW}$(forward_rule_count) 条${PLAIN}"
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

    if [[ "$detail" == "doctor" ]]; then
        list_forward_rules
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
            jq --arg tag "$SS_TAG" --arg pass "$SS_PASSWORD" '(.inbounds[] | select(.tag == $tag).settings.password) = $pass' "$CONFIG_FILE" >"$tmp" && mv "$tmp" "$CONFIG_FILE"
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
               ' "$CONFIG_FILE" >"$tmp" && mv "$tmp" "$CONFIG_FILE"
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
            jq --arg tag "$SOCKS_TAG" --arg pass "$S_PASS" '(.inbounds[] | select(.tag == $tag).settings.accounts[0].pass) = $pass' "$CONFIG_FILE" >"$tmp" && mv "$tmp" "$CONFIG_FILE"
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
    jq --arg tag "$tag" '.inbounds = ((.inbounds // []) | map(select(.tag != $tag)))' "$CONFIG_FILE" >"$tmp" && mv "$tmp" "$CONFIG_FILE"
    rm -f "$tmp"
}

state_delete_key() {
    local key="$1"
    local tmp
    init_state
    tmp="$(mktemp)"
    jq "del(.${key})" "$STATE_FILE" >"$tmp" && mv "$tmp" "$STATE_FILE"
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
    echo -e "${GREEN}13.${PLAIN} 中转/端口转发管理"
    echo -e "${GREEN}14.${PLAIN} 退出"
    echo -e "----------------------------------------------"
}

show_menu() {
    install_shortcut

    while true; do
        render_menu
        read -r -p "请输入选项 [1-14]: " MENU_CHOICE || exit 0

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
            13)
                configure_forward_menu || err "[失败] 中转/端口转发管理未完成，请查看上方错误信息。"
                ;;
            14) exit 0 ;;
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
            ipv4 | ipv6 | dual)
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
        "" | status)
            echo -e "中国大陆直连屏蔽: ${YELLOW}$(china_direct_block_status)${PLAIN}"
            echo "用法: ike cnblock basic|enhanced|off"
            ;;
        basic | enhanced | off)
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
        "" | status)
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

run_forward_command() {
    local action="${1:-}"
    local mode="${2:-safe}"
    local tag_arg="${2:-}"

    case "$action" in
        list | "")
            list_forward_rules
            ;;
        add)
            if ! validate_forward_mode "$mode"; then
                err "[失败] 未知 forward add 模式: $mode"
                echo "用法: ike forward add [safe|relay]"
                return 1
            fi
            prepare_system || {
                err "[失败] 系统准备失败，无法添加端口转发。"
                return 1
            }
            configure_forward_rule "$mode" && install_forward_rule
            ;;
        enable)
            prepare_system || {
                err "[失败] 系统准备失败，无法启用端口转发。"
                return 1
            }
            set_forward_enabled "true" "$tag_arg"
            ;;
        disable)
            prepare_system || {
                err "[失败] 系统准备失败，无法停用端口转发。"
                return 1
            }
            set_forward_enabled "false" "$tag_arg"
            ;;
        edit)
            prepare_system || {
                err "[失败] 系统准备失败，无法修改端口转发。"
                return 1
            }
            edit_forward_rule "$tag_arg"
            ;;
        test)
            test_forward_rule "$tag_arg"
            ;;
        export)
            export_forward_rules
            ;;
        import)
            prepare_system || {
                err "[失败] 系统准备失败，无法导入端口转发。"
                return 1
            }
            import_forward_rules
            ;;
        del | delete | remove)
            prepare_system || {
                err "[失败] 系统准备失败，无法删除端口转发。"
                return 1
            }
            delete_forward_rule "$tag_arg"
            ;;
        *)
            err "[失败] 未知 forward 参数: $action"
            echo "用法: ike forward list | ike forward add [safe|relay] | ike forward enable [tag] | ike forward disable [tag] | ike forward edit [tag] | ike forward test [tag] | ike forward export | ike forward import | ike forward del [tag]"
            return 1
            ;;
    esac
}

show_help() {
    cat <<'EOF'
Xray-OneClick 命令帮助

常用命令:
  ike
  ike view
  ike view doctor
  ike update
  ike backup
  ike cnblock
  ike cnblock basic
  ike cnblock enhanced
  ike cnblock off
  ike safety enhanced on
  ike safety enhanced off
  ike forward list
  ike forward add
  ike forward add safe
  ike forward add relay
  ike forward edit
  ike forward enable
  ike forward disable
  ike forward del
  ike forward test
  ike forward export
  ike forward import
  ike version
EOF
}

show_version() {
    echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"
    echo "Repository: ${REPO_URL}"
    if [[ -x "$BIN_PATH" ]]; then
        echo
        "$BIN_PATH" version 2>/dev/null | head -n 5 || echo "Xray: 版本信息读取失败"
    else
        echo "Xray: 未安装 (${BIN_PATH})"
    fi
}

main() {
    case "${1:-}" in
        help | -h | --help)
            show_help
            return 0
            ;;
        version | --version)
            show_version
            return 0
            ;;
        "" | view | update | backup | cnblock | safety | forward) ;;
        *)
            err "[失败] 未知命令: $1"
            echo "运行 ike help 查看可用命令。"
            return 1
            ;;
    esac

    ensure_root
    check_os
    detect_arch

    case "${1:-}" in
        "")
            show_menu
            ;;
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
        forward)
            run_forward_command "${2:-}" "${3:-}"
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
