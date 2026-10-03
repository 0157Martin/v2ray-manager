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
  for scenario in empty-state revoked-user selected-node dotted-id batch-success batch-cancel \
    batch-input-failure batch-signal batch-restart-failure pending-failure pending-signal secure-state; do
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
    grep -qx 'REMARK=new-secondary' "$NODES_DIR/secondary.env"
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
    grep -qx 'DATA_SCHEMA=3' "$CONFIG_DIR/schema-only.env"
    assert_private "$CONFIG_DIR/schema-only.env" 600
    [[ -z $(find "$CONFIG_DIR" -name '*.next' -o -name 'new-state.env.*' -o -name 'schema-only.env.*') ]]
    ;;
esac
touch "$sandbox/passed"
