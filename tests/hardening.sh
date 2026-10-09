#!/usr/bin/env bash
# Real mutation entry/re-exec and snapshots; host/service effects are sandboxed.
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
sandbox=$(mktemp -d)
trap 'rm -rf -- "$sandbox"' EXIT
export sandbox
manager="$sandbox/manager.sh"
sed -e "s|readonly BIN_DIR=.*|readonly BIN_DIR=\"$sandbox/bin\"|" \
  -e "s|readonly ASSET_DIR=.*|readonly ASSET_DIR=\"$sandbox/assets\"|" \
  -e "s|readonly CONFIG_DIR=.*|readonly CONFIG_DIR=\"$sandbox/config\"|" \
  -e "s|readonly BACKUP_DIR=.*|readonly BACKUP_DIR=\"$sandbox/backups\"|" \
  -e "s|readonly SERVICE_FILE=.*|readonly SERVICE_FILE=\"$sandbox/xray.service\"|" \
  -e "s|readonly CADDY_CONFIG=.*|readonly CADDY_CONFIG=\"$sandbox/Caddyfile\"|" \
  -e "s|readonly CADDY_SITE_DIR=.*|readonly CADDY_SITE_DIR=\"$sandbox/caddy-sites\"|" \
  -e "s|readonly LOCK_FILE=.*|readonly LOCK_FILE=\"$sandbox/manager.lock\"|" \
  -e "s|readonly ACME_RENEWAL_DIR=.*|readonly ACME_RENEWAL_DIR=\"$sandbox/renewal\"|" \
  -e "s|readonly HYSTERIA_BIN=.*|readonly HYSTERIA_BIN=\"$sandbox/bin/hysteria\"|" \
  -e "s|readonly HYSTERIA_CONFIG_DIR=.*|readonly HYSTERIA_CONFIG_DIR=\"$sandbox/hysteria\"|" \
  -e "s|readonly HYSTERIA_SERVICE_TEMPLATE=.*|readonly HYSTERIA_SERVICE_TEMPLATE=\"$sandbox/hysteria.service\"|" \
  "$repo/v2ray.sh" | sed '/^if \[\[ "${BASH_SOURCE\[0\]}"/,$d' > "$manager"
cat >> "$manager" <<'MOCKS'
require_root() { :; }
install() {
  local directory=0
  local -a args=()
  while (( $# )); do
    case "$1" in
      -o|-g) shift 2 ;;
      -m) if [[ ${OSTYPE:-} == msys* ]]; then shift 2; else args+=("$1" "$2"); shift 2; fi ;;
      -d) directory=1; args+=("$1"); shift ;;
      *) args+=("$1"); shift ;;
    esac
  done
  if [[ ${TEST_SCENARIO:-} == tls-copy && ${args[*]} == *new-key* ]]; then return 1; fi
  if [[ ${OSTYPE:-} == msys* ]]; then
    if (( directory )); then mkdir -p "${args[@]:1}"; else cp "${args[@]}"; fi
  else command install "${args[@]}"; fi
}
chown() { :; }
ensure_service_user() { :; }
systemctl() {
  printf '%s\n' "$*" >> "$sandbox/services"
  if [[ $1 == is-active ]]; then [[ ${TEST_ACTIVE:-0} == 1 ]]; else return 0; fi
}
restart_checked() { systemctl restart xray; }
tls_pair_valid() { return 0; }
tls_chain_valid() { return 0; }
open_enabled_inbound_ports() { :; }
warp_trace() { return 1; }
caddy() { return 0; }
configure_caddy_site() {
  printf 'changed-site\n' > "$CADDY_SITE_DIR/example.com.caddy"
  printf 'changed-main\n' > "$CADDY_CONFIG"
  return 1
}
change_menu() {
  load_edit_node primary
  if [[ ${TEST_SCENARIO:-} == cancel ]]; then
    printf broken > "$CONFIG_FILE"
    return 125
  fi
  PROFILE=vless-tls-ws; PATH_VALUE=/ws
  CERT_SOURCE="$sandbox/new-cert"; KEY_SOURCE="$sandbox/new-key"
  if [[ ${TEST_SCENARIO:-} == tls-preflight ]]; then validate_pending_config() { return 1; }; fi
  if [[ ${TEST_SCENARIO:-} == signal ]]; then
    printf broken > "$CONFIG_FILE"
    kill -TERM "$BASHPID"
  fi
  write_config "$EDIT_NODE_FILE"
}
# Windows does not provide util-linux flock. Its lock tests are explicitly skipped.
if [[ ${OSTYPE:-} == msys* ]]; then acquire_mutation_lock() { :; }; fi
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
MOCKS
# shellcheck disable=SC1090
source "$manager"
mkdir -p "$BIN_DIR" "$ASSET_DIR" "$NODES_DIR" "$BACKUP_DIR" "$CADDY_SITE_DIR" "$ACME_RENEWAL_DIR"
cat > "$XRAY_BIN" <<'CORE'
#!/usr/bin/env bash
if [[ $1 == uuid ]]; then
  value=$(openssl rand -hex 4)
  printf '%s-1111-4111-8111-111111111111\n' "$value"
fi
exit 0
CORE
chmod +x "$XRAY_BIN"
PORT=24443 UUID=11111111-1111-4111-8111-111111111111 EXTRA_UUIDS=''
ADDRESS=edge.example.com PROFILE=vmess-tcp SERVER_NAME=example.com
PRIVATE_KEY='' PUBLIC_KEY='' SHORT_ID='' REMARK=primary PATH_VALUE='' CERT_SOURCE='' KEY_SOURCE=''
save_current_node "$NODES_DIR/primary.env"
cp "$NODES_DIR/primary.env" "$STATE_FILE"
rebuild_config_from_nodes
cp "$CONFIG_FILE" "$sandbox/original.json"
cp "$NODES_DIR/primary.env" "$sandbox/original-node"
printf original > "$CADDY_CONFIG"
printf original > "$CADDY_SITE_DIR/example.com.caddy"
mkdir -p "$TLS_DIR/example.com"
printf old-cert > "$TLS_DIR/example.com/cert.pem"
printf old-key > "$TLS_DIR/example.com/key.pem"
printf new-cert > "$sandbox/new-cert"
printf new-key > "$sandbox/new-key"

expect_failure() {
  local status=0
  bash "$manager" "$@" > "$sandbox/output" 2>&1 || status=$?
  if (( status == 0 )); then cat "$sandbox/output"; printf 'FAIL: unexpectedly succeeded: %s\n' "$*" >&2; exit 1; fi
}
assert_restored() {
  cmp "$CONFIG_FILE" "$sandbox/original.json"
  cmp "$NODES_DIR/primary.env" "$sandbox/original-node"
  [[ $(cat "$TLS_DIR/example.com/cert.pem") == old-cert ]]
  [[ $(cat "$TLS_DIR/example.com/key.pem") == old-key ]]
  [[ $(cat "$CADDY_CONFIG") == original ]]
  [[ $(cat "$CADDY_SITE_DIR/example.com.caddy") == original ]]
}

expect_failure warp all
assert_restored
[[ ! -e $WARP_STATE_FILE ]]
TEST_ACTIVE=1 expect_failure warp all
if grep -q '^restart ' "$sandbox/services"; then printf 'Unexpected service restart\n' >&2; exit 1; fi
printf 'PASS: failed WARP preflight leaves original routing\n'
for TEST_SCENARIO in tls-copy tls-preflight signal; do
  export TEST_SCENARIO
  expect_failure change primary
  assert_restored
  printf 'PASS: complete rollback after %s\n' "$TEST_SCENARIO"
done
unset TEST_SCENARIO

export TEST_SCENARIO=cancel
bash "$manager" change primary > "$sandbox/output" 2>&1 || {
  cat "$sandbox/output"
  printf 'FAIL: cancellation returned an error\n' >&2
  exit 1
}
assert_restored
grep -q '已取消操作' "$sandbox/output"
printf 'PASS: cancellation rolls back partial state and exits successfully\n'
unset TEST_SCENARIO

printf 'authenticator = standalone\n' > "$ACME_RENEWAL_DIR/example.com.conf"
if check_caddy_renewal_compatibility >/dev/null 2>&1; then exit 1; fi
TEST_ACTIVE=1 check_caddy_activation_compatibility
if TEST_ACTIVE=0 check_caddy_activation_compatibility >/dev/null 2>&1; then exit 1; fi
printf 'authenticator = webroot\n' > "$ACME_RENEWAL_DIR/example.com.conf"
check_caddy_renewal_compatibility
printf 'PASS: standalone renewal blocks only a new Caddy activation\n'

PORT=24444 PROFILE=vless-tls-xhttp PATH_VALUE=/xhttp
save_current_node "$NODES_DIR/xhttp.env"
rebuild_config_from_nodes
# Model an actual pre-h2c server, not just a no-op schema migration.
jq '(.inbounds[] | select(.tag == "xhttp")) |=
  (.listen="0.0.0.0" | .streamSettings.security="tls" |
   .streamSettings.tlsSettings={certificates:[{certificateFile:"legacy-cert",keyFile:"legacy-key"}]})' \
  "$CONFIG_FILE" > "$sandbox/legacy.json"
cp "$sandbox/legacy.json" "$CONFIG_FILE"
cp "$CONFIG_FILE" "$sandbox/original.json"
printf '' > "$sandbox/services"
expect_failure migrate
assert_restored
if grep -q '^restart ' "$sandbox/services"; then printf 'Unexpected service restart\n' >&2; exit 1; fi
TEST_ACTIVE=1 expect_failure migrate
assert_restored
grep -q '^restart xray' "$sandbox/services"
grep -q '^restart caddy' "$sandbox/services"
printf 'PASS: Caddy migration failure restores both components\n'

UUID=22222222-2222-4222-8222-222222222222 PROFILE=vmess-tcp PORT=24443 PATH_VALUE=''
save_current_node "$NODES_DIR/primary.env"
cp "$NODES_DIR/primary.env" "$sandbox/original-node"
expect_failure migrate
grep -q '非预期变化' "$sandbox/output"
assert_restored
printf 'PASS: XHTTP presence does not bypass another node fingerprint\n'

# Security policy must survive both routing modes and block resolved domains.
inject_warp_config "$CONFIG_FILE" all
jq -e '.routing.domainStrategy == "IPOnDemand" and
  .routing.rules[0].outboundTag == "block" and
  (.routing.rules[1].ip | index("127.0.0.0/8")) != null and
  .routing.rules[-1].outboundTag == "warp"' "$CONFIG_FILE" >/dev/null
printf 'PASS: private-target blocks precede WARP routing\n'

if [[ ${OSTYPE:-} == msys* ]]; then
  printf 'SKIP: real flock concurrency/inheritance requires Linux\n'
else
  rm -f "$NODES_DIR/xhttp.env"
  UUID=11111111-1111-4111-8111-111111111111 PROFILE=vmess-tcp PORT=24443 PATH_VALUE=''
  save_current_node "$NODES_DIR/primary.env"
  rebuild_config_from_nodes
  bash "$manager" users add primary 1 > "$sandbox/writer-a" 2>&1 & first=$!
  bash "$manager" users add primary 1 > "$sandbox/writer-b" 2>&1 & second=$!
  wait "$first" || { cat "$sandbox/writer-a"; exit 1; }
  wait "$second" || { cat "$sandbox/writer-b"; exit 1; }
  jq -e '.inbounds[0].settings.clients | length == 3' "$CONFIG_FILE" >/dev/null
  printf 'PASS: simultaneous writers preserve both added users\n'
  # Upgrade/migration subprocesses must reuse the inherited lock, not deadlock.
  (
    acquire_mutation_lock
    timeout 20 bash "$manager" migrate > "$sandbox/inherited-lock" 2>&1
  ) || { cat "$sandbox/inherited-lock"; exit 1; }
  printf 'PASS: migration child inherits the lock\n'
fi
printf 'Hardening regression tests passed.\n'
