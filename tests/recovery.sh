#!/usr/bin/env bash
# Regression tests run only in a temporary filesystem with mocked service/network operations.
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail
repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

if [[ ${1:-} != --case ]]; then
  sandbox=$(mktemp -d)
  trap 'rm -rf -- "$sandbox"' EXIT
  for scenario in healthy delayed-crash restarted-process invalid-core download-failure \
    update-success update-stopped update-rollback partial-copy rollback-failure \
    manager-update manager-invalid manager-rollback tls-restore backup-collision \
    link-stale-primary link-disabled-primary link-missing-address link-ipv6 link-mismatch link-node-isolation \
    tls-renew-ok tls-renew-invalid tls-renew-config-failure tls-renew-restart-failure tls-renew-stopped acme-webroot \
    link-client-export link-client-disabled; do
    mkdir "$sandbox/$scenario"
    if bash "$0" --case "$scenario" "$sandbox/$scenario"; then
      printf 'PASS: %s\n' "$scenario"
    else
      fail "$scenario"
    fi
  done
  printf '%s\n' 'Recovery tests passed.'
  exit
fi

scenario=$2
sandbox=$3
# Redirect only the production path constants; test the actual function bodies.
sed -e "s|readonly BIN_DIR=.*|readonly BIN_DIR=\"$sandbox/bin\"|" \
  -e "s|readonly ASSET_DIR=.*|readonly ASSET_DIR=\"$sandbox/assets\"|" \
  -e "s|readonly CONFIG_DIR=.*|readonly CONFIG_DIR=\"$sandbox/config\"|" \
  -e "s|readonly BACKUP_DIR=.*|readonly BACKUP_DIR=\"$sandbox/backups\"|" \
  -e "s|readonly SERVICE_FILE=.*|readonly SERVICE_FILE=\"$sandbox/xray.service\"|" \
  "$repo_dir/v2ray.sh" > "$sandbox/manager.sh"
# shellcheck disable=SC1091
source "$sandbox/manager.sh"
mkdir -p "$BIN_DIR" "$ASSET_DIR" "$CONFIG_DIR" "$BACKUP_DIR"

install_dependencies() { :; }
# Ownership is a Linux integration concern. File contents/copy failures remain real.
install() {
  local -a args=()
  while (( $# )); do
    case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac
  done
  if [[ ${OSTYPE:-} == msys* ]]; then
    local directory=0
    set -- "${args[@]}"
    args=()
    while (( $# )); do
      case "$1" in
        -m) shift 2 ;;
        -d) directory=1; shift ;;
        *) args+=("$1"); shift ;;
      esac
    done
    if (( directory )); then mkdir -p "${args[@]}"; else cp "${args[@]}"; fi
  else
    command install "${args[@]}"
  fi
}
chown() { :; }
sleep() {
  local count=0
  [[ ! -f $sandbox/ticks ]] || read -r count < "$sandbox/ticks"
  printf '%s\n' "$((count+1))" > "$sandbox/ticks"
}
systemctl() {
  local count=0
  [[ ! -f $sandbox/ticks ]] || read -r count < "$sandbox/ticks"
  case "$1" in
    is-active)
      [[ $scenario != update-stopped && $scenario != tls-renew-stopped ]] || return 1
      [[ $scenario != delayed-crash || $count -lt 2 ]] || return 1
      if [[ $scenario == update-rollback || $scenario == rollback-failure ]]; then
        [[ $("$XRAY_BIN" version) != candidate ]] || return 1
      fi
      ;;
    show)
      if [[ $2 == --property=MainPID ]]; then
        if [[ $scenario == restarted-process && $count -ge 2 ]]; then printf '200\n'; else printf '100\n'; fi
      else
        printf '0\n'
      fi
      ;;
    restart) printf 'restart\n' >> "$sandbox/service-actions" ;;
    *) fail "unexpected systemctl call: $*" ;;
  esac
}

cat > "$XRAY_BIN" <<'CORE'
#!/usr/bin/env bash
if [[ $1 == version ]]; then printf 'previous\n'; fi
CORE
chmod +x "$XRAY_BIN"
printf 'old-geoip\n' > "$ASSET_DIR/geoip.dat"
printf 'old-geosite\n' > "$ASSET_DIR/geosite.dat"
printf '{}\n' > "$CONFIG_FILE"
printf 'PORT=443\n' > "$STATE_FILE"

fetch_core() {
  [[ $scenario != download-failure ]] || return 1
  mkdir "$1/core"
  cat > "$1/core/xray" <<'CORE'
#!/usr/bin/env bash
if [[ $1 == version ]]; then printf 'candidate\n'; exit; fi
[[ ${CANDIDATE_INVALID:-0} != 1 ]]
CORE
  chmod +x "$1/core/xray"
  printf 'new-geoip\n' > "$1/core/geoip.dat"
  printf 'new-geosite\n' > "$1/core/geosite.dat"
}

case "$scenario" in
  tls-renew-*)
    mkdir -p "$TLS_DIR/example.com" "$sandbox/lineage"
    printf old-cert > "$TLS_DIR/example.com/cert.pem"
    printf old-key > "$TLS_DIR/example.com/key.pem"
    printf new-cert > "$sandbox/lineage/fullchain.pem"
    printf new-key > "$sandbox/lineage/privkey.pem"
    printf '%s\n' "$sandbox/lineage" > "$TLS_DIR/example.com/source"
    # Real cryptographic checks are exercised by unit.sh; inject deployment failures here.
    tls_pair_valid() { [[ $scenario != tls-renew-invalid ]]; }
    tls_chain_valid() { return 0; }
    if [[ $scenario == tls-renew-config-failure ]]; then
      printf '#!/usr/bin/env bash\nexit 1\n' > "$XRAY_BIN"
    fi
    restart_checked() {
      printf 'restart\n' >> "$sandbox/service-actions"
      [[ $scenario != tls-renew-restart-failure || $(cat "$TLS_DIR/example.com/cert.pem") == old-cert ]]
    }
    status=0
    refresh_tls_certificates "$sandbox/lineage" > "$sandbox/output" 2>&1 || status=$?
    case "$scenario" in
      tls-renew-ok|tls-renew-stopped)
        [[ $status == 0 && $(cat "$TLS_DIR/example.com/cert.pem") == new-cert && $(cat "$TLS_DIR/example.com/key.pem") == new-key ]] || { cat "$sandbox/output"; fail 'renewal not deployed'; }
        if [[ $scenario == tls-renew-stopped ]]; then [[ ! -e $sandbox/service-actions ]] || fail 'renewal started stopped service'; fi
        ;;
      *)
        [[ $status != 0 && $(cat "$TLS_DIR/example.com/cert.pem") == old-cert && $(cat "$TLS_DIR/example.com/key.pem") == old-key ]] || fail 'failed renewal did not preserve old pair'
        if [[ $scenario == tls-renew-invalid ]]; then [[ ! -e $sandbox/service-actions ]] || fail 'invalid renewal restarted service'; fi
        ;;
    esac
    ;;
  acme-webroot)
    mkdir -p "$sandbox/web root"
    V2M_ACME_WEBROOT="$sandbox/web root"
    SERVER_NAME=example.com
    getent() { return 0; }
    ss() { fail 'webroot mode must not require port 80 to be unused'; }
    open_local_firewall_port() { :; }
    systemctl() { :; }
    certbot() { printf '%s\n' "$@" > "$sandbox/certbot-args"; }
    issue_tls_material >/dev/null
    grep -Fx -- --webroot "$sandbox/certbot-args" >/dev/null || fail 'webroot mode missing'
    grep -Fx -- "$V2M_ACME_WEBROOT" "$sandbox/certbot-args" >/dev/null || fail 'webroot path split'
    if grep -Fx -- --standalone "$sandbox/certbot-args" >/dev/null; then fail 'standalone used with webroot'; fi
    ;;
  healthy) service_healthy ;;
  delayed-crash|restarted-process)
    if service_healthy; then fail 'unhealthy process was accepted'; fi ;;
  invalid-core|download-failure|update-success|update-stopped|update-rollback|partial-copy|rollback-failure)
    if [[ $scenario == invalid-core ]]; then export CANDIDATE_INVALID=1; fi
    if [[ $scenario == partial-copy || $scenario == rollback-failure ]]; then
      # Fail after the executable changed, leaving a mixed set to roll back.
      eval "$(declare -f atomic_install | sed '1s/atomic_install/real_atomic_install/')"
      atomic_install() {
        if [[ $scenario == partial-copy && $1 == */core/geoip.dat ]]; then return 1; fi
        if [[ $scenario == rollback-failure && $1 == */previous/xray ]]; then return 1; fi
        real_atomic_install "$@"
      }
    fi
    # Run the function as a simple command in a fresh shell so errexit is enabled.
    export scenario sandbox XRAY_BIN ASSET_DIR CONFIG_FILE BACKUP_DIR RELEASE_API
    export -f update_core finish_core_update fetch_core install_core_files atomic_install \
      install_dependencies install systemctl service_healthy restart_checked sleep die red green yellow
    if declare -F real_atomic_install >/dev/null; then export -f real_atomic_install; fi
    status=0
    bash -c 'set -Eeuo pipefail; SERVICE_NAME=xray; update_core' > "$sandbox/output" 2>&1 || status=$?
    case "$scenario" in
      update-success|update-stopped)
        [[ $status == 0 && $("$XRAY_BIN" version) == candidate ]] || { cat "$sandbox/output"; fail 'update did not succeed'; }
        [[ $(cat "$ASSET_DIR/geoip.dat") == new-geoip ]] || fail 'new GeoData missing'
        if [[ $scenario == update-stopped ]]; then [[ ! -e $sandbox/service-actions ]] || fail 'stopped service was started'; fi
        ;;
      rollback-failure)
        [[ $status != 0 ]] || fail 'rollback failure reported success'
        compgen -G "$BACKUP_DIR/core-update.*/previous/xray" >/dev/null || fail 'recovery files were lost'
        ;;
      *)
        [[ $status != 0 ]] || fail 'failure reported success'
        [[ $("$XRAY_BIN" version) == previous ]] || { cat "$sandbox/output"; fail 'old core not preserved'; }
        [[ $(cat "$ASSET_DIR/geoip.dat") == old-geoip && $(cat "$ASSET_DIR/geosite.dat") == old-geosite ]] || fail 'GeoData not restored'
        if [[ $scenario == invalid-core || $scenario == download-failure ]]; then
          [[ ! -e $sandbox/service-actions ]] || fail 'preflight failure restarted live service'
        fi
        ;;
    esac
    ;;
  manager-update|manager-invalid|manager-rollback)
    cp "$repo_dir/v2ray.sh" "$MANAGER_BIN"
    cp "$MANAGER_BIN" "$sandbox/original"
    curl() {
      local output=
      while (( $# )); do
        if [[ $1 == --output ]]; then output=$2; shift 2; else shift; fi
      done
      if [[ -z $output ]]; then printf '{"sha":"1111111111111111111111111111111111111111"}\n'; return; fi
      if [[ $scenario == manager-invalid ]]; then printf '<html>error</html>\n' > "$output"; return; fi
      cp "$sandbox/original" "$output"
      printf '\n# test update\n' >> "$output"
    }
    export scenario sandbox MANAGER_BIN BACKUP_DIR MANAGER_URL MANAGER_API
    export -f update_manager validate_manager atomic_install install curl die red green
    status=0
    bash -c 'set -Eeuo pipefail; update_manager' > "$sandbox/output" 2>&1 || status=$?
    if [[ $scenario == manager-invalid ]]; then
      [[ $status != 0 ]] || fail 'invalid manager accepted'
      cmp "$MANAGER_BIN" "$sandbox/original" || fail 'invalid download changed manager'
    else
      [[ $status == 0 ]] || { cat "$sandbox/output"; fail 'manager update failed'; }
      cmp "$BACKUP_DIR/manager.previous.sh" "$sandbox/original" || fail 'previous manager missing'
      if [[ $scenario == manager-rollback ]]; then
        rollback_manager
        cmp "$MANAGER_BIN" "$sandbox/original" || fail 'manager rollback failed'
      fi
    fi
    ;;
  tls-restore)
    mkdir -p "$TLS_DIR/example.com" "$TLS_DIR/second.example.com" "$NODES_DIR"
    printf 'certificate\n' > "$TLS_DIR/example.com/cert.pem"
    printf 'private-key\n' > "$TLS_DIR/example.com/key.pem"
    printf 'second-key\n' > "$TLS_DIR/second.example.com/key.pem"
    printf 'node\n' > "$NODES_DIR/primary.env"
    jq -n --arg cert "$TLS_DIR/example.com/cert.pem" '{certificateFile:$cert}' > "$CONFIG_FILE"
    create_backup
    printf 'broken\n' > "$TLS_DIR/example.com/cert.pem"
    rm "$TLS_DIR/second.example.com/key.pem"
    cat > "$XRAY_BIN" <<'CORE'
#!/usr/bin/env bash
set -e
cert=$(jq -r '.certificateFile' "$4")
[[ $(cat "$cert") == certificate ]]
CORE
    restore_archive "$LAST_BACKUP"
    [[ $(cat "$TLS_DIR/example.com/cert.pem") == certificate ]] || fail 'certificate not restored'
    [[ $(cat "$TLS_DIR/second.example.com/key.pem") == second-key ]] || fail 'domain directory missing'
    ;;
  backup-collision)
    date() { printf '20260929T000000Z\n'; }
    create_backup
    first=$LAST_BACKUP
    create_backup
    [[ $LAST_BACKUP != "$first" && -f $first && -f $LAST_BACKUP ]] || fail 'same-second backup overwritten'
    touch -t 202601010000 "$first"
    touch -t 202601010001 "$LAST_BACKUP"
    [[ $(list_backups | sed -n '1p') == "$LAST_BACKUP" ]] || fail 'latest backup selected by random suffix'
    ;;
  link-*)
    mkdir -p "$NODES_DIR"
    export PORT=24443 UUID=11111111-1111-4111-8111-111111111111
    export ADDRESS=192.0.2.20 PROFILE=vless-reality-raw SERVER_NAME=example.com
    export PRIVATE_KEY=test-private PUBLIC_KEY=test-public SHORT_ID=0123456789abcdef
    export REMARK='node A & test' PATH_VALUE=
    # These cases exercise registry/URL behavior; real keys are covered by xray-config.sh.
    reality_pair_valid() { return 0; }
    save_current_node "$NODES_DIR/primary.env"
    render_config "$CONFIG_FILE"
    case "$scenario" in
      link-client-export)
        export_client primary > "$sandbox/client.json"
        jq -e '.outbounds[0].settings.vnext[0] | .address == "192.0.2.20" and .port == 24443' "$sandbox/client.json" >/dev/null || fail 'client export not selected node JSON'
        if export_client ../primary > "$sandbox/invalid.json" 2>/dev/null; then fail 'path traversal accepted'; fi
        ;;
      link-client-disabled)
        mv "$NODES_DIR/primary.env" "$NODES_DIR/primary.disabled"
        if export_client primary > "$sandbox/client.json" 2>/dev/null; then fail 'disabled node exported as client'; fi
        [[ ! -s $sandbox/client.json ]] || fail 'disabled node produced client JSON'
        ;;
      link-stale-primary)
        printf 'PORT=9999\n' > "$STATE_FILE"
        output=$(show_connection)
        [[ $output == *'@192.0.2.20:24443?'* ]] || fail 'export used stale manager.env'
        ;;
      link-disabled-primary)
        mv "$NODES_DIR/primary.env" "$NODES_DIR/primary.disabled"
        PORT=24444
        save_current_node "$NODES_DIR/alternate.env"
        render_config "$CONFIG_FILE"
        output=$(show_connection)
        [[ $output == *':24444?'* && $output != *':24443?'* ]] || fail 'disabled primary exported'
        ;;
      link-missing-address)
        ADDRESS=YOUR_SERVER_IP
        if show_connection_loaded > "$sandbox/link" 2>/dev/null; then fail 'placeholder accepted'; fi
        ! grep -q 'vless://' "$sandbox/link" || fail 'invalid link printed'
        ;;
      link-ipv6)
        ADDRESS=2001:db8::10
        render_config "$CONFIG_FILE"
        jq -e '.inbounds[0].listen == "::"' "$CONFIG_FILE" >/dev/null || fail 'IPv6 address has IPv4-only listener'
        output=$(show_connection_loaded)
        [[ $output == *'@[2001:db8::10]:24443?'* ]] || fail 'IPv6 authority missing brackets'
        ;;
      link-mismatch)
        PORT=24444
        if show_connection_loaded > "$sandbox/link" 2>/dev/null; then fail 'stale port accepted'; fi
        ! grep -q 'vless://' "$sandbox/link" || fail 'mismatched link printed'
        ;;
      link-node-isolation)
        PORT=24444; REMARK=node-Z
        save_current_node "$NODES_DIR/z-last.env"
        PORT=24443; REMARK=node-A
        rebuild_config_from_nodes
        [[ $PORT == 24443 && $REMARK == node-A ]] || fail 'rebuild changed selected node'
        open_local_firewall_port() { :; }
        open_enabled_inbound_ports >/dev/null
        [[ $PORT == 24443 && $REMARK == node-A ]] || fail 'firewall changed selected node'
        output=$(show_connection_loaded)
        [[ $output == *':24443?'* && $output == *'#node-A'* ]] || fail 'wrong node exported after operation'
        ;;
    esac
    ;;
esac
