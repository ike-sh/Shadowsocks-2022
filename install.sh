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
RAW_SCRIPT_URL="https://raw.githubusercontent.com/ike-sh/Shadowsocks-2022/refs/heads/main/install.sh"
XRAY_RELEASE_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"

SS_TAG="ss2022-in"
VLESS_TAG="vless-enc-in"
SOCKS_TAG="socks-in"
VLESS_FLOW="xtls-rprx-vision"

IPV6_PREFERRED="false"
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
    ensure_config_security
}

init_state() {
    mkdir -p "$CONFIG_DIR"
    [[ -f "$STATE_FILE" ]] || echo '{}' > "$STATE_FILE"
    if ! jq empty "$STATE_FILE" >/dev/null 2>&1; then
        mv "$STATE_FILE" "${STATE_FILE}.broken.$(date +%Y%m%d%H%M%S)"
        echo '{}' > "$STATE_FILE"
    fi
    ensure_config_security
}

backup_config() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    cp -a "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
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
    ensure_config_security
    validate_config_file || return 1
    restart_service
}

install_or_update_xray() {
    local force="${1:-false}"
    local release_json latest_url version tmpdir zip_path xray_bin replacing_existing

    install_dependencies || return 1
    init_config
    init_state

    if [[ -x "$BIN_PATH" && "$force" != "true" ]]; then
        create_service
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

    ask_port "SS2022 端口" "9000" SS_PORT
    SS_PASSWORD="$(generate_ss2022_password "$SS_METHOD")"
    SS_LISTEN="0.0.0.0"
    [[ "$IPV6_PREFERRED" == "true" ]] && SS_LISTEN="::"
}

install_ss2022() {
    install_or_update_xray || return 1
    backup_config

    local tmp
    tmp="$(mktemp)"
    jq --arg tag "$SS_TAG" \
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
       ' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
    rm -f "$tmp"

    apply_config || return 1
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
       --arg flow "$VLESS_FLOW" \
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
          "flow": $flow,
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
       --arg flow "$VLESS_FLOW" \
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
                "flow": $flow,
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
    ok "[完成] SOCKS5 已写入 Xray 配置。"
    view_config
}

get_public_addresses() {
    PUBLIC_IPV4="$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null || true)"
    PUBLIC_IPV6="$(curl -s6 --max-time 5 ifconfig.me 2>/dev/null || true)"

    if [[ -z "$PUBLIC_IPV6" ]]; then
        PUBLIC_IPV6="$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}' | head -n 1 | cut -d'/' -f1)"
    fi
    if [[ -z "$PUBLIC_IPV4" ]]; then
        PUBLIC_IPV4="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi
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

view_config() {
    local mode="${1:-$LINK_VIEW_MODE}"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        err "错误：未找到配置文件，请先安装协议。"
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        err "错误：缺少 jq，无法读取配置。"
        return 1
    fi

    init_state
    get_public_addresses
    host_candidates "$mode"

    echo -e "\n${GREEN}========= 当前 Xray 配置信息 =========${PLAIN}"
    echo -e "链接显示模式: ${YELLOW}${mode}${PLAIN}"
    [[ -n "$PUBLIC_IPV4" ]] && echo -e "IPv4: ${PUBLIC_IPV4}"
    [[ -n "$PUBLIC_IPV6" ]] && echo -e "IPv6: ${PUBLIC_IPV6}"

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

    local vless_in vp vu vf venc vmode vmethod vrtt vticket venc_uri vf_uri
    vless_in="$(jq -c --arg tag "$VLESS_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" 2>/dev/null)"
    if [[ -n "$vless_in" ]]; then
        vp="$(echo "$vless_in" | jq -r '.port')"
        vu="$(echo "$vless_in" | jq -r '.settings.clients[0].id')"
        vf="$(echo "$vless_in" | jq -r '.settings.clients[0].flow // empty')"
        venc="$(jq -r '.vless_encryption.encryption // empty' "$STATE_FILE" 2>/dev/null)"
        vmode="$(jq -r '.vless_encryption.mode // "basic"' "$STATE_FILE" 2>/dev/null)"
        vmethod="$(jq -r '.vless_encryption.enc_method // "native"' "$STATE_FILE" 2>/dev/null)"
        vrtt="$(jq -r '.vless_encryption.client_rtt // "0rtt"' "$STATE_FILE" 2>/dev/null)"
        vticket="$(jq -r '.vless_encryption.server_ticket // "600s"' "$STATE_FILE" 2>/dev/null)"

        echo -e "\n${YELLOW}--- VLESS Encryption ---${PLAIN}"
        echo -e "端口: ${vp}"
        echo -e "UUID: ${vu}"
        echo -e "Flow: ${vf:-无}"
        echo -e "模式: ${vmode}"
        echo -e "外观混淆: ${vmethod}"
        echo -e "客户端握手: ${vrtt}"
        echo -e "服务端 ticket: ${vticket}"
        if [[ -z "$venc" ]]; then
            err "[提示] 缺少客户端 encryption，无法生成完整 VLESS 链接。请重新安装或重置 VLESS Encryption。"
        else
            echo -e "客户端 encryption: ${venc}"
            venc_uri="$(url_encode "$venc")"
            vf_uri="$(url_encode "$vf")"
            [[ -n "$IPV4_HOST" ]] && echo -e "IPv4链接: vless://${vu}@${IPV4_HOST}:${vp}?type=tcp&security=none&encryption=${venc_uri}&flow=${vf_uri}#VLESS-ENC-IPv4"
            [[ -n "$IPV6_HOST" ]] && echo -e "IPv6链接: vless://${vu}@${IPV6_HOST}:${vp}?type=tcp&security=none&encryption=${venc_uri}&flow=${vf_uri}#VLESS-ENC-IPv6"
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
                (.inbounds[] | select(.tag == $tag).settings.decryption) = $decryption
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
        view_config
    else
        info "[提示] 没有可更新的配置。"
    fi
}

remove_inbound() {
    local tag="$1"
    local tmp
    init_config
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
    echo -e "${GREEN}10.${PLAIN} 退出"
    echo -e "----------------------------------------------"
}

show_menu() {
    install_shortcut

    while true; do
        render_menu
        read -r -p "请输入选项 [1-10]: " MENU_CHOICE || exit 0

        case "$MENU_CHOICE" in
            1) update_xray_core ;;
            2) prepare_system; configure_ss2022; install_ss2022 ;;
            3)
                prepare_system
                if check_ipv6_status; then
                    IPV6_PREFERRED="true"
                    configure_ss2022
                    install_ss2022
                else
                    info "[IPv6] 请先在服务器开通 IPv6 后重试。"
                fi
                ;;
            4) prepare_system; configure_vless_encryption; install_vless_encryption ;;
            5) prepare_system; install_socks5 ;;
            6) view_config ;;
            7) set_link_view_mode ;;
            8) prepare_system; reset_secrets ;;
            9) uninstall ;;
            10) exit 0 ;;
            *) err "错误选项。" ;;
        esac

        pause_return_menu
    done
}

main() {
    ensure_root
    check_os
    detect_arch

    case "${1:-}" in
        view)
            view_config "${2:-$LINK_VIEW_MODE}"
            ;;
        update)
            update_xray_core
            ;;
        *)
            show_menu
            ;;
    esac
}

main "$@"
