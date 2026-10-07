#!/usr/bin/env bash
# Release pins, version selection and durable manager transactions. No host writes.
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
sandbox=$(mktemp -d)
trap 'rm -rf -- "$sandbox"' EXIT
export sandbox
manager="$sandbox/coordinator.sh"
sed -e "s|readonly BIN_DIR=.*|readonly BIN_DIR=\"$sandbox/bin\"|" \
  -e "s|readonly ASSET_DIR=.*|readonly ASSET_DIR=\"$sandbox/assets\"|" \
  -e "s|readonly CONFIG_DIR=.*|readonly CONFIG_DIR=\"$sandbox/config\"|" \
  -e "s|readonly BACKUP_DIR=.*|readonly BACKUP_DIR=\"$sandbox/backups\"|" \
  -e "s|readonly SERVICE_FILE=.*|readonly SERVICE_FILE=\"$sandbox/xray.service\"|" \
  -e "s|readonly CADDY_CONFIG=.*|readonly CADDY_CONFIG=\"$sandbox/Caddyfile\"|" \
  -e "s|readonly CADDY_SITE_DIR=.*|readonly CADDY_SITE_DIR=\"$sandbox/caddy-sites\"|" \
  -e "s|readonly WARP_BACKEND_BIN_DIR=.*|readonly WARP_BACKEND_BIN_DIR=\"$sandbox/components\"|" \
  -e "s|readonly CADDY_BRANCH_BIN=.*|readonly CADDY_BRANCH_BIN=\"$sandbox/components/caddy-manager\"|" \
  -e "s|readonly CFIP_BRANCH_BIN=.*|readonly CFIP_BRANCH_BIN=\"$sandbox/components/cloudflare-ip-manager\"|" \
  "$repo/v2ray.sh" | sed '/^if \[\[ "${BASH_SOURCE\[0\]}"/,$d' > "$manager"
cat >> "$manager" <<'MOCKS'
require_root() { :; }
acquire_mutation_lock() { :; } # Real lock coverage lives in hardening.sh on Linux.
install_dependencies() { :; }
sleep() { :; }
caddy() { [[ ${FAIL_CADDY:-0} != 1 ]]; }
install() {
  local -a args=()
  local directory=0
  while (( $# )); do
    case "$1" in
      -m|-o|-g) shift 2 ;;
      -d) directory=1; shift ;;
      *) args+=("$1"); shift ;;
    esac
  done
  if (( directory )); then mkdir -p "${args[@]}"; else cp "${args[@]}"; chmod +x "${args[-1]}"; fi
}
systemctl() {
  local unit=${!#}
  case "$1" in
    is-active) [[ -f $sandbox/active-$unit ]] ;;
    restart) touch "$sandbox/active-$unit" ;;
    stop) rm -f "$sandbox/active-$unit" ;;
    daemon-reload) : ;;
    show) if [[ $2 == --property=MainPID ]]; then printf '100\n'; else printf '0\n'; fi ;;
    *) return 1 ;;
  esac
}
curl() {
  local output=''
  printf '%s\n' "$*" >> "$sandbox/requests"
  while (( $# )); do
    if [[ $1 == --output ]]; then output=$2; shift 2; else shift; fi
  done
  if [[ -n $output ]]; then cp "$sandbox/candidate" "$output"
  else printf '{"sha":"1111111111111111111111111111111111111111","tag_name":"v26.1.2"}\n'; fi
}
if [[ -n ${TEST_MIGRATION:-} ]]; then
  migrate_project_state() {
    printf '{"generation":"new"}\n' > "$CONFIG_FILE"
    printf 'new-caddy\n' > "$CADDY_CONFIG"
    printf 'new-component\n' > "$WARP_BACKEND_BIN_DIR/example"
    [[ $TEST_MIGRATION != fail ]]
  }
fi
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
MOCKS
# shellcheck disable=SC1090
source "$manager"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_failure() {
  if "$@" > "$sandbox/output" 2>&1; then fail "unexpected success: $*"; fi
}
mkdir -p "$BIN_DIR" "$ASSET_DIR" "$NODES_DIR" "$BACKUP_DIR" "$CADDY_SITE_DIR" "$WARP_BACKEND_BIN_DIR"
cat > "$XRAY_BIN" <<'CORE'
#!/usr/bin/env bash
if [[ $1 == version ]]; then printf 'test-core\n'; fi
exit 0
CORE
chmod +x "$XRAY_BIN"
printf 'old-geoip' > "$ASSET_DIR/geoip.dat"
printf 'old-geosite' > "$ASSET_DIR/geosite.dat"
cp "$manager" "$MANAGER_BIN"
cp "$manager" "$sandbox/candidate"
printf '\n# candidate\n' >> "$sandbox/candidate"
printf '{"generation":"old"}\n' > "$CONFIG_FILE"
printf 'DATA_SCHEMA=4\n' > "$STATE_FILE"
printf 'old-caddy\n' > "$CADDY_CONFIG"
printf 'old-component\n' > "$WARP_BACKEND_BIN_DIR/example"

# Pinned versions bypass the latest API, invalid versions never reach the network.
[[ $(resolve_core_version v25.12.8) == v25.12.8 ]]
[[ ! -e $sandbox/requests ]]
expect_failure resolve_core_version '../../malicious'
[[ ! -e $sandbox/requests ]]
[[ $(resolve_core_version) == "$RECOMMENDED_XRAY_VERSION" ]]
[[ ! -e $sandbox/requests ]]
[[ $(resolve_core_version latest) == v26.1.2 ]]
[[ $(V2M_XRAY_VERSION=v25.1.1 resolve_core_version) == v25.1.1 ]]
before=$(sha256sum "$CONFIG_FILE")
bash "$manager" update.core --check --version v25.1.1 > "$sandbox/check"
[[ $(sha256sum "$CONFIG_FILE") == "$before" ]]
grep -q v25.1.1 "$sandbox/check"
expect_failure bash "$manager" update.core --version
expect_failure bash "$manager" update.core --version v1.2.3 --version v2.3.4
expect_failure bash "$manager" update.core --version v1.2.3 --latest
printf 'PASS: version validation and read-only update checks\n'

# Every declared component has an immutable revision and a full checksum.
for name in caddy cfip wireguard masque; do
  read -r repository revision file digest <<< "$(component_manifest "$name")"
  [[ $revision =~ ^[0-9a-f]{40}$ && $digest =~ ^[0-9a-f]{64}$ && -n $file && -n $repository ]]
done
(
  printf '#!/usr/bin/env bash\nexit 0\n' > "$sandbox/component-source"
  test_digest=$(sha256sum "$sandbox/component-source"); test_digest=${test_digest%% *}
  component_manifest() { printf 'owner/repo %040d script.sh %s\n' 1 "$test_digest"; }
  download_file() { cp "$sandbox/component-source" "$2"; }
  install_component caddy "$sandbox/component"
  cmp "$sandbox/component" "$sandbox/component-source"
  verify_component caddy "$sandbox/component"
  download_file() { fail 'matching component should work offline'; }
  install_component caddy "$sandbox/component"
  printf 'legacy' > "$sandbox/component"
  download_file() { printf 'wrong content' > "$2"; }
  expect_failure install_component caddy "$sandbox/component"
  [[ $(cat "$sandbox/component") == legacy ]]
  expect_failure verify_component caddy "$sandbox/component"
)
printf 'PASS: release pins, offline reuse and checksum failure preservation\n'

cp "$sandbox/candidate" "$sandbox/supported-candidate"
sed 's/^readonly DATA_SCHEMA_VERSION="5"/readonly DATA_SCHEMA_VERSION="3"/' "$sandbox/supported-candidate" > "$sandbox/candidate"
expect_failure bash "$manager" upgrade
[[ ! -e $BACKUP_DIR/manager.pending ]]
cmp "$MANAGER_BIN" "$manager"
cp "$sandbox/supported-candidate" "$sandbox/candidate"
printf 'PASS: older candidate schema rejected before replacing manager\n'

TEST_MIGRATION=success bash "$manager" upgrade > "$sandbox/upgrade"
grep -q '"new"' "$CONFIG_FILE"
[[ -f $BACKUP_DIR/manager.rollback && ! -e $BACKUP_DIR/manager.pending ]]
printf 'extra' > "$CONFIG_DIR/added-after-upgrade"
bash "$manager" rollback.sh > "$sandbox/rollback"
cmp "$MANAGER_BIN" "$manager"
grep -q '"old"' "$CONFIG_FILE"
[[ ! -e $CONFIG_DIR/added-after-upgrade ]]
[[ $(cat "$CADDY_CONFIG") == old-caddy && $(cat "$WARP_BACKEND_BIN_DIR/example") == old-component ]]
[[ ! -e $sandbox/active-xray && ! -e $sandbox/active-caddy ]]
printf 'PASS: rollback restores paired data, removes later files and preserves stopped services\n'

touch "$sandbox/active-xray" "$sandbox/active-caddy"
export TEST_MIGRATION=fail
expect_failure bash "$manager" upgrade
unset TEST_MIGRATION
cmp "$MANAGER_BIN" "$manager"
grep -q '"old"' "$CONFIG_FILE"
[[ $(cat "$CADDY_CONFIG") == old-caddy && $(cat "$WARP_BACKEND_BIN_DIR/example") == old-component ]]
[[ -e $sandbox/active-xray && -e $sandbox/active-caddy && ! -e $BACKUP_DIR/manager.pending ]]
printf 'PASS: failed migration restores both services and associated files\n'

# Simulate process death after the durable journal, without relying on EXIT traps.
bundle=$(mktemp -d "$BACKUP_DIR/manager-transaction.XXXXXX")
capture_manager_bundle "$bundle"
publish_manager_pointer "$BACKUP_DIR/manager.pending" "$bundle"
printf '{"generation":"interrupted"}' > "$CONFIG_FILE"
printf 'DATA_SCHEMA=999999\n' > "$NODES_DIR/future.disabled"
expect_failure bash "$manager" upgrade
bash "$bundle/recovery.sh" recover > "$sandbox/recovery"
grep -q '"old"' "$CONFIG_FILE"
[[ ! -e $NODES_DIR/future.disabled && ! -e $BACKUP_DIR/manager.pending ]]
printf 'PASS: persistent recovery bypasses incompatible live state\n'

# A corrupted bundle fails closed, retaining the journal and live files.
publish_manager_pointer "$BACKUP_DIR/manager.pending" "$bundle"
printf 'corrupted' >> "$bundle/files/config/config.json"
before=$(sha256sum "$CONFIG_FILE")
expect_failure bash "$manager" recover
[[ -f $BACKUP_DIR/manager.pending && $(sha256sum "$CONFIG_FILE") == "$before" ]]
rm "$BACKUP_DIR/manager.pending"
printf 'PASS: corrupted recovery snapshot is rejected\n'

printf 'DATA_SCHEMA=999999\n' > "$NODES_DIR/future.disabled"
expect_failure check_state_schema
expect_failure bash "$manager" migrate
before=$(sha256sum "$NODES_DIR/future.disabled")
bash "$manager" help > "$sandbox/help"
[[ $(sha256sum "$NODES_DIR/future.disabled") == "$before" ]]
rm "$NODES_DIR/future.disabled"
printf 'PASS: future disabled-node schema blocked, help does not migrate\n'
if [[ ${OSTYPE:-} != msys* ]]; then
  ln -s "$sandbox/candidate" "$CONFIG_DIR/external-link"
  bundle=$(mktemp -d "$BACKUP_DIR/manager-transaction.XXXXXX")
  expect_failure capture_manager_bundle "$bundle"
  [[ ! -e $BACKUP_DIR/manager.pending ]]
  rm "$CONFIG_DIR/external-link"
  printf 'PASS: mutable symlink layouts rejected before any replacement\n'
else
  printf 'SKIP: native symlink snapshot guard requires Linux\n'
fi
printf 'Reliability regression tests passed.\n'
