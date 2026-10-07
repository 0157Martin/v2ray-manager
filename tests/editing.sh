#!/usr/bin/env bash
# Registry edits and sensitive-file regressions, with no real system/network operations.
# SPDX-License-Identifier: GPL-3.0-or-later
# Globals and dependency overrides are consumed by sourced production functions.
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail
repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

if [[ $# == 0 ]]; then
  sandbox=$(mktemp -d)
  trap 'rm -rf -- "$sandbox"' EXIT
  for scenario in empty-state revoked-user selected-node dotted-id enable-all-active disable-all-disabled batch-success batch-cancel \
    batch-input-failure batch-signal batch-restart-failure pending-failure pending-signal secure-state \
    state-parser desired-plan desired-apply xhttp-mode diagnostics; do
    mkdir "$sandbox/$scenario"
    status=0
    # A fresh Bash process keeps errexit enabled inside the production functions.
    bash "$0" --case "$scenario" "$sandbox/$scenario" > "$sandbox/$scenario/output" 2>&1 || status=$?
    case "$scenario" in
      *-failure|*-signal) (( status != 0 )) || fail "$scenario unexpectedly succeeded" ;;
      *) (( status == 0 )) || { cat "$sandbox/$scenario/output"; fail "$scenario"; } ;;
    esac
    bash "$0" --verify "$scenario" "$sandbox/$scenario" || { cat "$sandbox/$scenario/output"; fail "$scenario verification"; }
    printf 'PASS: %s\n' "$scenario"
  done
  printf '%s\n' 'Editing and sensitive-file tests passed.'
  exit
fi

scenario=$2
sandbox=$3
if [[ $1 == --verify ]]; then
  case "$scenario" in
    batch-input-failure|batch-signal|batch-restart-failure)
      cmp "$sandbox/original.json" "$sandbox/config/config.json"
      diff -r "$sandbox/original-nodes" "$sandbox/config/nodes"
      cmp "$sandbox/original-cert" "$sandbox/config/tls/example.com/cert.pem"
      [[ -s $sandbox/failure-injected ]] || fail 'failure was not injected'
      if [[ $scenario == batch-restart-failure ]]; then
        [[ $(wc -l < "$sandbox/restarts") == 2 ]] || fail 'restored service was not restarted'
      else
        [[ ! -e $sandbox/restarts ]] || fail 'preflight failure restarted service'
      fi
      ;;
    pending-failure|pending-signal)
      [[ -s $sandbox/failure-injected ]] || fail 'failure was not injected'
      cmp "$sandbox/original.json" "$sandbox/config/config.json"
      [[ -z $(find "$sandbox/config" -name '.config.*' -o -name 'config.pending.json') ]] || fail 'sensitive temporary config leaked'
      ;;
    *) [[ -f $sandbox/passed ]] || fail 'test did not reach its assertions' ;;
  esac
  exit
fi

sed -e "s|readonly BIN_DIR=.*|readonly BIN_DIR=\"$sandbox/bin\"|" \
  -e "s|readonly ASSET_DIR=.*|readonly ASSET_DIR=\"$sandbox/assets\"|" \
  -e "s|readonly CONFIG_DIR=.*|readonly CONFIG_DIR=\"$sandbox/config\"|" \
  -e "s|readonly BACKUP_DIR=.*|readonly BACKUP_DIR=\"$sandbox/backups\"|" \
  "$repo_dir/v2ray.sh" > "$sandbox/manager.sh"
# shellcheck disable=SC1091
source "$sandbox/manager.sh"
mkdir -p "$BIN_DIR" "$ASSET_DIR" "$NODES_DIR" "$BACKUP_DIR"
printf '#!/usr/bin/env bash\nexit 0\n' > "$XRAY_BIN"
chmod +x "$XRAY_BIN"
install() {
  local directory=0
  local -a args=()
  while (( $# )); do
    case "$1" in
      -o|-g) shift 2 ;;
      -m)
        if [[ ${OSTYPE:-} == msys* ]]; then shift 2; else args+=("$1" "$2"); shift 2; fi
        ;;
      -d) directory=1; args+=("$1"); shift ;;
      *) args+=("$1"); shift ;;
    esac
  done
  if [[ ${OSTYPE:-} == msys* ]]; then
    if (( directory )); then mkdir -p "${args[@]:1}"; else cp "${args[@]}"; fi
  else
    command install "${args[@]}"
  fi
}
# Mock only external dependencies, retaining real registry, rendering and backup logic.
chown() { :; }
ensure_service_user() { :; }
prepare_tls_material() { :; }
ensure_port_available() { :; }
open_enabled_inbound_ports() { :; }
reality_pair_valid() { return 0; }
restart_checked() { printf 'restart\n' >> "$sandbox/restarts"; }
generate_reality_credentials() { PRIVATE_KEY=new-private; PUBLIC_KEY=new-public; SHORT_ID=1111111111111111; }
assert_private() {
  # Git Bash/NTFS cannot establish Linux multi-user permission guarantees.
  if [[ ${OSTYPE:-} != msys* ]]; then
    [[ $(stat -c %a "$1") == "$2" ]] || fail "unsafe permissions on $1"
  fi
}
PORT=24443 UUID=11111111-1111-4111-8111-111111111111
EXTRA_UUIDS=22222222-2222-4222-8222-222222222222
ADDRESS=edge.example.com PROFILE=vless-reality-raw SERVER_NAME=dl.google.com
PRIVATE_KEY=old-private PUBLIC_KEY=old-public SHORT_ID=0123456789abcdef
REMARK=primary PATH_VALUE='' CERT_SOURCE='' KEY_SOURCE=''
save_current_node "$NODES_DIR/primary.env"
cp "$NODES_DIR/primary.env" "$STATE_FILE"
rebuild_config_from_nodes
cp "$CONFIG_FILE" "$sandbox/original.json"

case "$scenario" in
  state-parser)
    REMARK=$'spaces 中文 ; $(touch /tmp/never-run) "quotes" \\ slash\nnewline'
    printf 'REMARK=%q\nPORT=24443\n' "$REMARK" > "$sandbox/legacy.env"
    expected=$REMARK
    load_state_file "$sandbox/legacy.env"
    [[ $REMARK == "$expected" ]]
    # This fixture must contain literal command substitution.
    # shellcheck disable=SC2016
    printf 'REMARK=$(touch %s)\n' "$sandbox/executed" > "$sandbox/hostile.env"
    if load_state_file "$sandbox/hostile.env"; then fail 'executable state accepted'; fi
    [[ ! -e $sandbox/executed ]]
    printf '{"PATH":"hostile"}\n' > "$sandbox/hostile.env"
    if load_state_file "$sandbox/hostile.env"; then fail 'unknown key accepted'; fi
    save_current_node "$sandbox/json.env"
    jq -e --arg expected "$expected" '.REMARK == $expected and .DATA_SCHEMA == 5' "$sandbox/json.env" >/dev/null
    ;;
  desired-plan|desired-apply)
    printf '{"schema_version":1,"nodes":[{"id":"primary","enabled":false,"remark":"planned"}]}' > "$sandbox/desired.json"
    cp "$NODES_DIR/primary.env" "$sandbox/before-state"
    plan_desired "$sandbox/desired.json" > "$sandbox/plan.json"
    jq -e '.restart_required and .changes[0].after.enabled == false' "$sandbox/plan.json" >/dev/null
    ! grep -Eq 'old-private|11111111-1111' "$sandbox/plan.json"
    cmp "$sandbox/before-state" "$NODES_DIR/primary.env"
    cmp "$sandbox/original.json" "$CONFIG_FILE"
    if [[ $scenario == desired-apply ]]; then
      apply_desired "$sandbox/desired.json" > "$sandbox/applied.json"
      [[ ! -e $NODES_DIR/primary.env && -f $NODES_DIR/primary.disabled ]]
      jq -e '.REMARK == "planned"' "$NODES_DIR/primary.disabled" >/dev/null
      jq -e '.inbounds == []' "$CONFIG_FILE" >/dev/null
      apply_desired "$sandbox/desired.json" > "$sandbox/again.json"
      jq -e '.restart_required == false' "$sandbox/again.json" >/dev/null
      [[ $(wc -l < "$sandbox/restarts") == 1 ]]
    fi
    printf '{"schema_version":1,"nodes":[{"id":"missing","enabled":true}]}' > "$sandbox/invalid.json"
    if plan_desired "$sandbox/invalid.json"; then fail 'unknown node accepted'; fi
    ;;
  xhttp-mode)
    PROFILE=vless-reality-xhttp PATH_VALUE=/fixture
    save_current_node "$NODES_DIR/primary.env"
    set_xhttp_mode primary packet-up
    load_state_file "$NODES_DIR/primary.env"
    [[ $XHTTP_MODE == packet-up ]]
    render_client_config | jq -e '.outbounds[0].streamSettings.xhttpSettings.mode == "packet-up"' >/dev/null
    if valid_xhttp_mode unsafe; then fail 'invalid mode accepted'; fi
    ;;
  diagnostics)
    systemctl() { return 0; }
    ss() { printf 'LISTEN\n'; }
    doctor_report > "$sandbox/report.json"
    jq -e '.status == "passed" and .public_reachability == "not_checked" and .local_handshake == "not_checked"' "$sandbox/report.json" >/dev/null
    ! grep -Eq 'old-private|11111111-1111|edge.example' "$sandbox/report.json"
    doctor_metrics | grep -qx 'v2ray_manager_local_check_success 1'
    ss() { return 1; }
    status=0; doctor_report > "$sandbox/report.json" || status=$?
    [[ $status == 2 ]]
    jq -e '.status == "incomplete"' "$sandbox/report.json" >/dev/null
    touch "$BACKUP_DIR/manager.pending"
    status=0; doctor_report > "$sandbox/report.json" || status=$?
    [[ $status == 1 ]]
    jq -e '.checks.transaction == "pending"' "$sandbox/report.json" >/dev/null
    cmp "$sandbox/original.json" "$CONFIG_FILE"
    ;;
  empty-state)
    printf 'DATA_SCHEMA=3\n' > "$STATE_FILE"
    mv "$NODES_DIR/primary.env" "$NODES_DIR/manual.env"
    rebuild_config_from_nodes
    unset PORT UUID EXTRA_UUIDS ADDRESS PROFILE SERVER_NAME PRIVATE_KEY PUBLIC_KEY SHORT_ID REMARK PATH_VALUE CERT_SOURCE KEY_SOURCE
    change_menu <<< $'2\n25443'
    [[ ! -e $NODES_DIR/primary.env ]] || fail 'change created an unintended primary node'
    jq -e '.inbounds | length == 1 and .[0].port == 25443 and .[0].tag == "manual"' "$CONFIG_FILE" >/dev/null
    ;;
  revoked-user)
    delete_sub_link primary 1 >/dev/null
    change_menu <<< $'6\nnew-remark'
    rotate_reality_keys primary
    jq -e '.inbounds[0] | .settings.clients | length == 1 and .[0].id == "22222222-2222-4222-8222-222222222222"' "$CONFIG_FILE" >/dev/null
    ;;
  selected-node)
    PORT=24444; REMARK=secondary; save_current_node "$NODES_DIR/secondary.env"
    cp "$NODES_DIR/primary.env" "$sandbox/primary-before"
    rebuild_config_from_nodes
    change_menu <<< $'secondary\n6\nnew-secondary'
    rotate_reality_keys secondary
    cmp "$sandbox/primary-before" "$NODES_DIR/primary.env"
    jq -e '.REMARK == "new-secondary"' "$NODES_DIR/secondary.env"
    jq -e '.inbounds[] | select(.tag == "secondary") | .streamSettings.realitySettings.privateKey == "new-private"' "$CONFIG_FILE" >/dev/null
    jq -e '.inbounds | length == 2' "$CONFIG_FILE" >/dev/null
    ;;
  dotted-id)
    ask_server_values() {
      REMARK=edge.example.com; PORT=24444; UUID=33333333-3333-4333-8333-333333333333
      ADDRESS=edge.example.com; PROFILE=vless-reality-raw; SERVER_NAME=dl.google.com
      PRIVATE_KEY=test-private; PUBLIC_KEY=test-public; SHORT_ID=0123456789abcdef
    }
    add_inbound >/dev/null
    [[ -f $NODES_DIR/edge.example.com.env ]]
    load_sub_link_credentials edge.example.com
    show_connection edge.example.com > "$sandbox/link"
    export_client edge.example.com > "$sandbox/client.json"
    grep -q '@edge.example.com:24444' "$sandbox/link"
    jq -e '.outbounds[0].settings.vnext[0].port == 24444' "$sandbox/client.json" >/dev/null
    for invalid in ../primary /primary 'a/b' 'a\b' 'a b' ''; do
      if valid_node_id "$invalid"; then fail "unsafe ID accepted: $invalid"; fi
    done
    ;;
  enable-all-active)
    enable_inbound <<< 'all' > "$sandbox/no-op-output"
    grep -Fq '所有入站已经启用，无需操作' "$sandbox/no-op-output" || fail 'enabled all no-op was not explained'
    [[ -f $NODES_DIR/primary.env && ! -e $NODES_DIR/primary.disabled ]] || fail 'enabled node changed during no-op'
    [[ ! -e $sandbox/restarts ]] || fail 'enabled all no-op restarted the service'
    ;;
  disable-all-disabled)
    mv "$NODES_DIR/primary.env" "$NODES_DIR/primary.disabled"
    rebuild_config_from_nodes
    disable_inbound <<< 'all' > "$sandbox/no-op-output"
    grep -Fq '所有入站已经停用，无需操作' "$sandbox/no-op-output" || fail 'disabled all no-op was not explained'
    [[ -f $NODES_DIR/primary.disabled && ! -e $NODES_DIR/primary.env ]] || fail 'disabled node changed during no-op'
    [[ ! -e $sandbox/restarts ]] || fail 'disabled all no-op restarted the service'
    ;;
  batch-*)
    PORT=24444; REMARK=secondary; save_current_node "$NODES_DIR/secondary.env"
    rebuild_config_from_nodes
    mkdir -p "$TLS_DIR/example.com"
    printf 'old-cert\n' > "$TLS_DIR/example.com/cert.pem"
    cp "$TLS_DIR/example.com/cert.pem" "$sandbox/original-cert"
    cp "$CONFIG_FILE" "$sandbox/original.json"
    cp -a "$NODES_DIR" "$sandbox/original-nodes"
    select_node_files() { SELECTED_NODE_FILES=("$NODES_DIR/primary.env" "$NODES_DIR/secondary.env"); }
    ask_server_values() {
      if [[ $PORT == 24444 && ( $scenario == batch-input-failure || $scenario == batch-signal ) ]]; then
        printf 'injected\n' > "$sandbox/failure-injected"
        if [[ $scenario == batch-signal ]]; then kill -TERM "$BASHPID"; else return 1; fi
      fi
      PORT=$((PORT + 1000))
    }
    prepare_tls_material() { printf 'changed-cert\n' > "$TLS_DIR/example.com/cert.pem"; }
    if [[ $scenario == batch-restart-failure ]]; then
      restart_checked() {
        printf 'restart\n' >> "$sandbox/restarts"
        printf 'injected\n' > "$sandbox/failure-injected"
        [[ $(wc -l < "$sandbox/restarts") == 2 ]]
      }
    fi
    if [[ $scenario == batch-cancel ]]; then
      modify_inbound <<< '0'
      diff -r "$sandbox/original-nodes" "$NODES_DIR"
      cmp "$sandbox/original.json" "$CONFIG_FILE"
      [[ ! -e $sandbox/restarts ]]
    else
      modify_inbound <<< '3'
      [[ $scenario == batch-success ]] || fail 'injected batch failure was ignored'
      jq -e '[.inbounds[].port] == [25443,25444]' "$CONFIG_FILE" >/dev/null
      [[ $(wc -l < "$sandbox/restarts") == 1 ]]
    fi
    ;;
  pending-failure|pending-signal)
    umask 022
    apply_warp_config() {
      assert_private "$1" 600
      assert_private "${1%/*}" 700
      jq -e '.inbounds[0].streamSettings.realitySettings.privateKey == "old-private"' "$1" >/dev/null
      printf 'injected\n' > "$sandbox/failure-injected"
      if [[ $scenario == pending-signal ]]; then kill -TERM "$BASHPID"; else return 1; fi
    }
    write_config
    fail 'pending configuration failure was ignored'
    ;;
  secure-state)
    umask 022
    # Observe permissions before publication, including schema migration intermediates.
    mv() { assert_private "$3" 600; command mv "$@"; }
    save_current_node "$CONFIG_DIR/new-state.env"
    assert_private "$CONFIG_DIR/new-state.env" 600
    cp "$CONFIG_DIR/new-state.env" "$sandbox/expected-state"
    write_data_schema_marker "$CONFIG_DIR/new-state.env"
    cmp "$sandbox/expected-state" "$CONFIG_DIR/new-state.env"
    write_data_schema_marker "$CONFIG_DIR/schema-only.env"
    jq -e --argjson schema "$DATA_SCHEMA_VERSION" '.DATA_SCHEMA == $schema' "$CONFIG_DIR/schema-only.env"
    assert_private "$CONFIG_DIR/schema-only.env" 600
    [[ -z $(find "$CONFIG_DIR" -name '*.next' -o -name 'new-state.env.*' -o -name 'schema-only.env.*') ]]
    ;;
esac
touch "$sandbox/passed"
