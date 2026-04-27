#!/usr/bin/env bash
# shellcheck disable=SC2034
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../install.sh
# shellcheck disable=SC1091
source "${ROOT_DIR}/install.sh"

TEST_TMP=""

info() { :; }
ok() { :; }
err() { printf '%s\n' "$*" >&2; }

ensure_config_security() {
    mkdir -p "$CONFIG_DIR" "$ASSET_DIR"
}

install_dependencies() { :; }
create_service() { :; }
restart_service() { :; }
state_set_meta_action() { :; }

validate_config_file() {
    jq empty "$CONFIG_FILE" >/dev/null
}

backup_config() {
    [[ -f "$CONFIG_FILE" ]] && cp -a "$CONFIG_FILE" "${CONFIG_FILE}.bak.test"
}

apply_config() {
    if [[ "${FORCE_PORTMAP_APPLY_FAIL:-false}" == "true" ]] && jq -e 'any(.inbounds[]?; (.settings.portMap // null) != null)' "$CONFIG_FILE" >/dev/null 2>&1; then
        [[ -f "${CONFIG_FILE}.bak.test" ]] && cp -a "${CONFIG_FILE}.bak.test" "$CONFIG_FILE"
        FORCE_PORTMAP_APPLY_FAIL="false"
        return 1
    fi
    ensure_default_safety_blocks >/dev/null
    validate_config_file
}

install_or_update_xray() {
    init_config
    init_state
}

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    dump_forward_debug
    cleanup_fixture
    exit 1
}

dump_forward_debug() {
    [[ -n "$TEST_TMP" ]] || return 0
    if [[ -f "$CONFIG_FILE" ]]; then
        printf '%s\n' "--- debug: config.inbounds ---" >&2
        jq '.inbounds' "$CONFIG_FILE" >&2 || true
        printf '%s\n' "--- debug: config.routing.rules ---" >&2
        jq '.routing.rules' "$CONFIG_FILE" >&2 || true
    fi
    if [[ -f "$STATE_FILE" ]]; then
        printf '%s\n' "--- debug: state.tunnels ---" >&2
        jq '.tunnels' "$STATE_FILE" >&2 || true
        printf '%s\n' "--- debug: state.forwards ---" >&2
        jq '.forwards' "$STATE_FILE" >&2 || true
    fi
}

assert_jq() {
    local file="$1"
    local expr="$2"
    local message="$3"

    if ! jq -e "$expr" "$file" >/dev/null; then
        fail "$message"
    fi
}

assert_jq_arg() {
    local file="$1"
    local arg_name="$2"
    local arg_value="$3"
    local expr="$4"
    local message="$5"

    if ! jq -e --arg "$arg_name" "$arg_value" "$expr" "$file" >/dev/null; then
        fail "$message"
    fi
}

assert_output_contains() {
    local output="$1"
    local needle="$2"
    local message="$3"

    if [[ "$output" != *"$needle"* ]]; then
        fail "$message"
    fi
}

cleanup_fixture() {
    [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]] && rm -rf "$TEST_TMP"
    TEST_TMP=""
    FORCE_PORTMAP_APPLY_FAIL="false"
}

setup_fixture() {
    cleanup_fixture
    TEST_TMP="$(mktemp -d)"
    CONFIG_DIR="${TEST_TMP}/etc-xray"
    CONFIG_FILE="${CONFIG_DIR}/config.json"
    STATE_FILE="${CONFIG_DIR}/installer-state.json"
    ASSET_DIR="${TEST_TMP}/share"
    BIN_PATH="${TEST_TMP}/xray"
    FORWARD_EXPORT_DIR="$TEST_TMP"
    INIT_SYSTEM="test"
    OS_TYPE="test"
    ARCH="x86_64"
    mkdir -p "$CONFIG_DIR" "$ASSET_DIR"

    cat >"$CONFIG_FILE" <<'JSON'
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "ss2022-in",
      "protocol": "shadowsocks",
      "port": 10001,
      "settings": {}
    },
    {
      "tag": "vless-enc-in",
      "protocol": "vless",
      "port": 10002,
      "settings": {
        "clients": []
      }
    },
    {
      "tag": "socks-in",
      "protocol": "socks",
      "port": 10003,
      "settings": {}
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    }
  ],
  "routing": {
    "rules": []
  }
}
JSON
    printf '{}\n' >"$STATE_FILE"
    init_config >/dev/null
    init_state >/dev/null
}

set_forward_vars() {
    local args=("$@")
    FORWARD_TAG="$1"
    FORWARD_LISTEN="$2"
    FORWARD_LISTEN_PORT="$3"
    FORWARD_TARGET="$4"
    FORWARD_TARGET_PORT="$5"
    FORWARD_NETWORK="$6"
    FORWARD_MODE="$7"
    FORWARD_REMARK="${8:-}"
    FORWARD_ENABLED="${9:-true}"
    FORWARD_TYPE="${args[9]:-single}"
    FORWARD_GROUP="${args[10]:-}"
    FORWARD_PORT_MAP_JSON="${args[11]:-}"
    [[ -n "$FORWARD_PORT_MAP_JSON" ]] || FORWARD_PORT_MAP_JSON="{}"
}

relay_rule_count_expr() {
    local tag="$1"
    printf '[.routing.rules[]? | select((.outboundTag == "direct") and (((.inboundTag // []) | index("%s")) != null))] | length' "$tag"
}

test_safe_forward_writes_inbound_only() {
    setup_fixture
    set_forward_vars "tunnel-30000-443" "0.0.0.0" "30000" "1.2.3.4" "443" "tcp" "safe" "safe-test" "true" "single" "public"

    write_forward_config_from_vars || fail "safe write failed"
    state_sync_forward_rule || fail "safe state sync failed"

    assert_jq "$CONFIG_FILE" 'any(.inbounds[]?; .tag == "tunnel-30000-443" and .protocol == "dokodemo-door" and .settings.address == "1.2.3.4" and .settings.port == 443 and .settings.network == "tcp")' "safe inbound missing"
    assert_jq "$CONFIG_FILE" "$(relay_rule_count_expr "tunnel-30000-443") == 0" "safe mode wrote relay routing rule"
    assert_jq "$STATE_FILE" 'any(.tunnels[]?; .tag == "tunnel-30000-443" and .group == "public" and .type == "single")' "safe tunnel state missing group/type"
    cleanup_fixture
}

test_relay_forward_is_idempotent() {
    setup_fixture
    set_forward_vars "tunnel-30000-443" "0.0.0.0" "30000" "1.2.3.4" "443" "tcp,udp" "relay" "relay-test" "true" "single" "landing-us"

    write_forward_config_from_vars || fail "relay first write failed"
    write_forward_config_from_vars || fail "relay second write failed"

    assert_jq "$CONFIG_FILE" '[.inbounds[]? | select(.tag == "tunnel-30000-443" and .protocol == "dokodemo-door")] | length == 1' "relay inbound duplicated or missing"
    assert_jq "$CONFIG_FILE" "$(relay_rule_count_expr "tunnel-30000-443") == 1" "relay routing duplicated or missing"
    cleanup_fixture
}

test_delete_forward_preserves_protocol_inbounds() {
    setup_fixture
    set_forward_vars "forward-30000-443" "0.0.0.0" "30000" "1.2.3.4" "443" "tcp" "relay" "relay-test" "true"

    write_forward_config_from_vars || fail "relay write before delete failed"
    remove_forward_config_by_tag "forward-30000-443" || fail "forward removal failed"

    assert_jq "$CONFIG_FILE" '([.inbounds[]? | select(.tag == "forward-30000-443")] | length) == 0' "forward inbound still exists after delete"
    assert_jq "$CONFIG_FILE" "$(relay_rule_count_expr "forward-30000-443") == 0" "relay routing still exists after delete"
    assert_jq "$CONFIG_FILE" 'any(.inbounds[]?; .tag == "ss2022-in") and any(.inbounds[]?; .tag == "vless-enc-in") and any(.inbounds[]?; .tag == "socks-in")' "non-forward inbounds were removed"
    cleanup_fixture
}

test_enable_disable_roundtrip() {
    setup_fixture
    set_forward_vars "forward-30000-443" "0.0.0.0" "30000" "1.2.3.4" "443" "tcp" "relay" "relay-test" "true"

    write_forward_config_from_vars || fail "relay write before disable failed"
    state_sync_forward_rule || fail "state sync before disable failed"

    set_forward_enabled "false" "forward-30000-443" || fail "disable failed"
    assert_jq "$CONFIG_FILE" '([.inbounds[]? | select(.tag == "forward-30000-443")] | length) == 0' "disabled forward still has inbound"
    assert_jq "$STATE_FILE" 'any(.forwards[]?; .tag == "forward-30000-443" and .enabled == false)' "disabled forward state not preserved"

    set_forward_enabled "true" "forward-30000-443" || fail "enable failed"
    assert_jq "$CONFIG_FILE" 'any(.inbounds[]?; .tag == "forward-30000-443" and .protocol == "dokodemo-door")' "enabled forward inbound missing"
    assert_jq "$CONFIG_FILE" "$(relay_rule_count_expr "forward-30000-443") == 1" "enabled relay route missing"
    assert_jq "$STATE_FILE" 'any(.forwards[]?; .tag == "forward-30000-443" and .enabled == true)' "enabled forward state not updated"
    cleanup_fixture
}

test_export_and_import_conflict_rename() {
    local export_file import_file forward_count state_count candidate renamed_tag

    setup_fixture
    set_forward_vars "forward-30000-443" "0.0.0.0" "30000" "1.2.3.4" "443" "tcp" "safe" "original" "true"
    write_forward_config_from_vars || fail "forward write before export failed"
    state_sync_forward_rule || fail "state sync before export failed"
    assert_jq "$CONFIG_FILE" 'any(.inbounds[]?; .tag == "forward-30000-443" and .settings.address == "1.2.3.4")' "original forward missing before import"
    assert_jq "$STATE_FILE" 'any(.forwards[]?; .tag == "forward-30000-443" and .target == "1.2.3.4")' "original state missing before import"

    export_forward_rules >/dev/null || fail "export failed"
    export_file=""
    for candidate in "$TEST_TMP"/xray-tunnels-*.json; do
        [[ -f "$candidate" ]] || continue
        export_file="$candidate"
        break
    done
    [[ -f "$export_file" ]] || fail "export file not found"
    assert_jq "$export_file" '.version == 1 and .type == "xray-oneclick-tunnels" and (.tunnels | length) == 1 and .tunnels[0].tag == "forward-30000-443"' "export content invalid"

    import_file="${TEST_TMP}/import.json"
    cat >"$import_file" <<'JSON'
{
  "forwards": [
    {
      "tag": "forward-30000-443",
      "listen": "0.0.0.0",
      "listen_port": 30000,
      "target": "9.9.9.9",
      "target_port": 443,
      "network": "tcp",
      "mode": "safe",
      "enabled": true,
      "remark": "renamed"
    }
  ]
}
JSON

    printf '%s\n3\n' "$import_file" | import_forward_rules >/dev/null || fail "import auto rename failed"
    assert_jq "$CONFIG_FILE" 'any(.inbounds[]?; .tag == "ss2022-in") and any(.inbounds[]?; .tag == "vless-enc-in") and any(.inbounds[]?; .tag == "socks-in")' "import removed non-forward inbounds"
    forward_count="$(jq '[.inbounds[]? | select((.tag // "") | startswith("forward-"))] | length' "$CONFIG_FILE")"
    [[ "$forward_count" == "2" ]] || fail "import conflict rename did not keep original and renamed forward"
    state_count="$(jq '[.forwards[]? | select((.tag // "") | startswith("forward-"))] | length' "$STATE_FILE")"
    [[ "$state_count" == "2" ]] || fail "import conflict rename did not keep original and renamed state"
    state_count="$(jq '[.tunnels[]? | select((.tag // "") | startswith("forward-"))] | length' "$STATE_FILE")"
    [[ "$state_count" == "2" ]] || fail "import conflict rename did not keep original and renamed tunnel state"
    renamed_tag="$(jq -r '.inbounds[]? | select((.tag // "") | startswith("forward-30000-443-")) | .tag' "$CONFIG_FILE" | head -n 1)"
    [[ -n "$renamed_tag" ]] || fail "renamed forward tag missing"
    assert_jq "$CONFIG_FILE" 'any(.inbounds[]?; .tag == "forward-30000-443" and .settings.address == "1.2.3.4")' "original forward was overwritten"
    # shellcheck disable=SC2016
    assert_jq_arg "$CONFIG_FILE" tag "$renamed_tag" 'any(.inbounds[]?; .tag == $tag and .settings.address == "9.9.9.9")' "renamed forward content missing"
    assert_jq "$STATE_FILE" 'any(.forwards[]?; .tag == "forward-30000-443" and .target == "1.2.3.4")' "original state was overwritten"
    # shellcheck disable=SC2016
    assert_jq_arg "$STATE_FILE" tag "$renamed_tag" 'any(.forwards[]?; .tag == $tag and .target == "9.9.9.9")' "renamed state content missing"
    cleanup_fixture
}

test_list_enabled_disabled_and_state_loss() {
    local output

    setup_fixture
    set_forward_vars "forward-30000-443" "0.0.0.0" "30000" "1.2.3.4" "443" "tcp" "safe" "list-test" "true"
    write_forward_config_from_vars || fail "forward write before list failed"
    state_sync_forward_rule || fail "state sync before list failed"

    output="$(list_forward_rules)"
    assert_output_contains "$output" "启用" "list did not show enabled status"
    assert_output_contains "$output" "forward-30000-443" "list did not show enabled forward"

    remove_forward_config_by_tag "forward-30000-443" || fail "remove before disabled list failed"
    output="$(list_forward_rules)"
    assert_output_contains "$output" "停用" "list did not show disabled state-only rule"

    rm -f "$STATE_FILE"
    set_forward_vars "forward-30000-443" "0.0.0.0" "30000" "1.2.3.4" "443" "tcp" "safe" "" "true"
    write_forward_config_from_vars || fail "forward write after state loss failed"
    output="$(list_forward_rules)"
    assert_output_contains "$output" "启用" "list did not parse enabled rule from config without state"
    cleanup_fixture
}

test_forward_scenario_defaults() {
    forward_scenario_defaults "map" || fail "map scenario defaults failed"
    [[ "$FORWARD_SCENARIO_MODE" == "relay" && "$FORWARD_SCENARIO_NETWORK" == "tcp" && "$FORWARD_SCENARIO_LOCK_NETWORK" == "true" ]] || fail "map scenario did not map to relay/tcp"

    forward_scenario_defaults "public" || fail "public scenario defaults failed"
    [[ "$FORWARD_SCENARIO_MODE" == "safe" && "$FORWARD_SCENARIO_NETWORK" == "tcp" && "$FORWARD_SCENARIO_LOCK_NETWORK" == "true" ]] || fail "public scenario did not map to safe/tcp"

    forward_scenario_defaults "landing" || fail "landing scenario defaults failed"
    [[ "$FORWARD_SCENARIO_MODE" == "relay" && "$FORWARD_SCENARIO_NETWORK" == "tcp" && "$FORWARD_SCENARIO_LOCK_NETWORK" == "true" ]] || fail "landing scenario did not map to relay/tcp"

    forward_scenario_defaults "lan" || fail "lan scenario defaults failed"
    [[ "$FORWARD_SCENARIO_MODE" == "relay" && "$FORWARD_SCENARIO_NETWORK" == "tcp" && "$FORWARD_SCENARIO_LOCK_NETWORK" == "true" ]] || fail "lan scenario did not map to relay/tcp"

    forward_scenario_defaults "udp" || fail "udp scenario defaults failed"
    [[ "$FORWARD_SCENARIO_MODE" == "safe" && "$FORWARD_SCENARIO_NETWORK" == "udp" && "$FORWARD_SCENARIO_LOCK_NETWORK" == "false" ]] || fail "udp scenario defaults changed unexpectedly"
}

test_forward_doctor_statuses() {
    local output

    setup_fixture
    set_forward_vars "forward-30000-443" "0.0.0.0" "30000" "1.2.3.4" "443" "tcp" "relay" "doctor-test" "true"
    write_forward_config_from_vars || fail "doctor relay write failed"
    state_sync_forward_rule || fail "doctor relay state sync failed"

    output="$(doctor_forward_rules "forward-30000-443")"
    assert_output_contains "$output" "状态: 启用" "doctor did not show enabled rule"
    assert_output_contains "$output" "relay路由: 存在" "doctor did not show existing relay route"

    remove_forward_config_by_tag "forward-30000-443" || fail "remove before disabled doctor failed"
    output="$(doctor_forward_rules "forward-30000-443")"
    assert_output_contains "$output" "状态: state-only" "doctor did not show state-only rule"
    assert_output_contains "$output" "state 存在但 config inbound 不存在" "doctor did not explain disabled state-only rule"

    rm -f "$STATE_FILE"
    set_forward_vars "forward-30000-443" "0.0.0.0" "30000" "1.2.3.4" "443" "tcp" "safe" "" "true"
    write_forward_config_from_vars || fail "write config-only forward failed"
    output="$(doctor_forward_rules "forward-30000-443")"
    assert_output_contains "$output" "状态: config-only" "doctor did not show config-only rule"
    assert_output_contains "$output" "state 缺失，可从 config 解析" "doctor did not explain config-only rule"
    cleanup_fixture
}

test_forward_doctor_detects_missing_relay_route() {
    local output tmp

    setup_fixture
    set_forward_vars "forward-30000-443" "0.0.0.0" "30000" "1.2.3.4" "443" "tcp" "relay" "missing-route" "true"
    write_forward_config_from_vars || fail "relay write before route removal failed"
    state_sync_forward_rule || fail "relay state sync before route removal failed"
    tmp="$(mktemp)"
    jq '.routing.rules = []' "$CONFIG_FILE" >"$tmp" && mv "$tmp" "$CONFIG_FILE"

    output="$(doctor_forward_rules "forward-30000-443")"
    assert_output_contains "$output" "模式: relay" "doctor lost expected relay mode"
    assert_output_contains "$output" "relay路由: 缺失" "doctor did not detect missing relay route"
    cleanup_fixture
}

test_forward_template_imports() {
    local template_file

    setup_fixture
    generate_forward_template >/dev/null || fail "template generation failed"
    template_file="${FORWARD_EXPORT_DIR}/xray-tunnels-template.json"
    [[ -f "$template_file" ]] || fail "template file missing"
    assert_jq "$template_file" '.version == 1 and .type == "xray-oneclick-tunnels" and (.tunnels | length) == 1 and .tunnels[0].tag == "tunnel-30000-443" and .tunnels[0].mode == "relay" and .tunnels[0].enabled == true and .tunnels[0].group == "landing-us"' "template fields invalid"

    printf '%s\n' "$template_file" | import_forward_rules >/dev/null || fail "template import failed"
    assert_jq "$CONFIG_FILE" 'any(.inbounds[]?; .tag == "tunnel-30000-443" and .protocol == "dokodemo-door" and .settings.address == "1.2.3.4")' "template import inbound missing"
    assert_jq "$STATE_FILE" 'any(.tunnels[]?; .tag == "tunnel-30000-443" and .mode == "relay" and .enabled == true and .group == "landing-us")' "template import state missing"
    assert_jq "$CONFIG_FILE" "$(relay_rule_count_expr "tunnel-30000-443") == 1" "template import relay route missing"
    cleanup_fixture
}

test_forward_ports_lists_managed_inbounds() {
    local output

    setup_fixture
    set_forward_vars "forward-30000-443" "0.0.0.0" "30000" "1.2.3.4" "443" "tcp" "safe" "ports-test" "true"
    write_forward_config_from_vars || fail "forward write before ports failed"

    output="$(list_managed_ports)"
    assert_output_contains "$output" "10001" "ports did not include SS2022 port"
    assert_output_contains "$output" "SS2022" "ports did not include SS2022 type"
    assert_output_contains "$output" "10002" "ports did not include VLESS port"
    assert_output_contains "$output" "VLESS" "ports did not include VLESS type"
    assert_output_contains "$output" "10003" "ports did not include SOCKS5 port"
    assert_output_contains "$output" "SOCKS5" "ports did not include SOCKS5 type"
    assert_output_contains "$output" "30000" "ports did not include forward port"
    assert_output_contains "$output" "forward-30000-443" "ports did not include forward tag"
    cleanup_fixture
}

test_tunnel_group_list_and_export() {
    local output export_file candidate

    setup_fixture
    set_forward_vars "tunnel-30000-443" "0.0.0.0" "30000" "1.2.3.4" "443" "tcp" "relay" "group-test" "true" "single" "landing-us"
    write_forward_config_from_vars || fail "group tunnel write failed"
    state_sync_forward_rule || fail "group tunnel state sync failed"

    output="$(list_tunnel_groups)"
    assert_output_contains "$output" "landing-us" "group list did not show group"
    assert_output_contains "$output" "1" "group list did not show count"

    export_forward_rules >/dev/null || fail "tunnel export failed"
    export_file=""
    for candidate in "$TEST_TMP"/xray-tunnels-*.json; do
        [[ -f "$candidate" ]] || continue
        export_file="$candidate"
        break
    done
    [[ -f "$export_file" ]] || fail "tunnel export file not found"
    assert_jq "$export_file" '.version == 1 and .type == "xray-oneclick-tunnels" and any(.tunnels[]?; .tag == "tunnel-30000-443" and .group == "landing-us" and .type == "single")' "tunnel export did not preserve group/type"
    cleanup_fixture
}

test_old_forwards_import_compatibility() {
    local import_file

    setup_fixture
    import_file="${TEST_TMP}/legacy-forwards.json"
    cat >"$import_file" <<'JSON'
{
  "forwards": [
    {
      "tag": "forward-31000-8443",
      "listen": "0.0.0.0",
      "listen_port": 31000,
      "target": "example.com",
      "target_port": 8443,
      "network": "tcp",
      "mode": "safe",
      "enabled": true,
      "remark": "legacy"
    }
  ]
}
JSON

    printf '%s\n' "$import_file" | import_forward_rules >/dev/null || fail "legacy forwards import failed"
    assert_jq "$CONFIG_FILE" 'any(.inbounds[]?; .tag == "forward-31000-8443" and .protocol == "dokodemo-door")' "legacy forward inbound missing"
    assert_jq "$STATE_FILE" 'any(.tunnels[]?; .tag == "forward-31000-8443" and .remark == "legacy")' "legacy forward was not mapped into tunnels state"
    cleanup_fixture
}

test_portmap_fallback_to_single_tunnels() {
    setup_fixture
    FORCE_PORTMAP_APPLY_FAIL="true"
    FORWARD_TYPE="portMap"
    FORWARD_GROUP="landing-us"
    FORWARD_LISTEN="0.0.0.0"
    FORWARD_LISTEN_PORT="30000,30001"
    FORWARD_TARGET="1.1.1.1"
    FORWARD_TARGET_PORT="443"
    FORWARD_NETWORK="tcp"
    FORWARD_MODE="relay"
    FORWARD_REMARK="portmap-fallback"
    FORWARD_ENABLED="true"
    FORWARD_PORT_MAP_JSON='{"30000":"1.1.1.1:443","30001":"2.2.2.2:8443"}'

    install_tunnel_portmap_rule >/dev/null || fail "portMap fallback install failed"
    assert_jq "$CONFIG_FILE" '([.inbounds[]? | select(((.tag // "") | startswith("tunnel-")) and ((.settings.portMap // null) != null))] | length) == 0' "portMap inbound remained after forced fallback"
    assert_jq "$CONFIG_FILE" 'any(.inbounds[]?; .tag == "tunnel-30000-443" and .settings.address == "1.1.1.1")' "fallback first single missing"
    assert_jq "$CONFIG_FILE" 'any(.inbounds[]?; .tag == "tunnel-30001-8443" and .settings.address == "2.2.2.2")' "fallback second single missing"
    assert_jq "$CONFIG_FILE" "$(relay_rule_count_expr "tunnel-30000-443") == 1" "fallback first relay route missing"
    assert_jq "$STATE_FILE" '([.tunnels[]? | select(.group == "landing-us" and .type == "single")] | length) == 2' "fallback state did not record two single tunnels"
    cleanup_fixture
}

test_forward_alias_lists_tunnels() {
    local output

    setup_fixture
    set_forward_vars "tunnel-30000-443" "0.0.0.0" "30000" "1.2.3.4" "443" "tcp" "safe" "alias-test" "true" "single" "compat"
    write_forward_config_from_vars || fail "alias tunnel write failed"
    state_sync_forward_rule || fail "alias state sync failed"

    output="$(run_forward_command list)"
    assert_output_contains "$output" "tunnel-30000-443" "forward alias did not list tunnel rule"
    output="$(run_tunnel_command list)"
    assert_output_contains "$output" "compat" "tunnel list did not show group"
    cleanup_fixture
}

run_test() {
    local name="$1"
    printf 'test: %s\n' "$name"
    "$name"
}

trap cleanup_fixture EXIT

run_test test_safe_forward_writes_inbound_only
run_test test_relay_forward_is_idempotent
run_test test_delete_forward_preserves_protocol_inbounds
run_test test_enable_disable_roundtrip
run_test test_export_and_import_conflict_rename
run_test test_list_enabled_disabled_and_state_loss
run_test test_forward_scenario_defaults
run_test test_forward_doctor_statuses
run_test test_forward_doctor_detects_missing_relay_route
run_test test_forward_template_imports
run_test test_forward_ports_lists_managed_inbounds
run_test test_tunnel_group_list_and_export
run_test test_old_forwards_import_compatibility
run_test test_portmap_fallback_to_single_tunnels
run_test test_forward_alias_lists_tunnels

printf 'All forward tests passed.\n'
