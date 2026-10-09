#!/usr/bin/env bash
# Regression tests run only in a temporary filesystem with mocked service/network operations.
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail
repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

config_connection_fingerprint() {
  jq -cS '[.inbounds[] | {tag, listen, port, protocol, settings, streamSettings}]' "$1" |
    sha256sum | awk '{print $1}'
}

if [[ ${1:-} != --case ]]; then
  sandbox=$(mktemp -d)
  trap 'rm -rf -- "$sandbox"' EXIT
  for scenario in healthy delayed-crash restarted-process invalid-core download-failure \
    update-success update-stopped update-rollback update-explicit-rollback partial-copy rollback-failure \
    manager-update manager-invalid manager-rollback tls-restore backup-collision \
    link-stale-primary link-disabled-primary link-missing-address link-ipv6 link-mismatch link-node-isolation link-multi-users link-project-migrate link-disabled-migrate \
    tls-renew-ok tls-renew-invalid tls-renew-config-failure tls-renew-restart-failure tls-renew-stopped acme-webroot acme-caddy-webroot \
    link-client-export link-client-disabled caddy-port-conflict; do
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
export sandbox
trap 'status=$?; printf "ERROR: scenario=%s line=%s status=%s command=%s\n" "$scenario" "$LINENO" "$status" "$BASH_COMMAND" >&2' ERR
# Redirect only the production path constants; test the actual function bodies.
sed -e "s|readonly BIN_DIR=.*|readonly BIN_DIR=\"$sandbox/bin\"|" \
  -e "s|readonly ASSET_DIR=.*|readonly ASSET_DIR=\"$sandbox/assets\"|" \
  -e "s|readonly CONFIG_DIR=.*|readonly CONFIG_DIR=\"$sandbox/config\"|" \
  -e "s|readonly BACKUP_DIR=.*|readonly BACKUP_DIR=\"$sandbox/backups\"|" \
  -e "s|readonly SERVICE_FILE=.*|readonly SERVICE_FILE=\"$sandbox/xray.service\"|" \
  -e "s|readonly CADDY_CONFIG=.*|readonly CADDY_CONFIG=\"$sandbox/Caddyfile\"|" \
  -e "s|readonly CADDY_SITE_DIR=.*|readonly CADDY_SITE_DIR=\"$sandbox/caddy-sites\"|" \
  -e "s|readonly CADDY_WEB_ROOT=.*|readonly CADDY_WEB_ROOT=\"$sandbox/www\"|" \
  -e "s|readonly WARP_BACKEND_BIN_DIR=.*|readonly WARP_BACKEND_BIN_DIR=\"$sandbox/components\"|" \
  -e "s|readonly HYSTERIA_BIN=.*|readonly HYSTERIA_BIN=\"$sandbox/bin/hysteria\"|" \
  -e "s|readonly HYSTERIA_CONFIG_DIR=.*|readonly HYSTERIA_CONFIG_DIR=\"$sandbox/hysteria\"|" \
  -e "s|readonly HYSTERIA_SERVICE_TEMPLATE=.*|readonly HYSTERIA_SERVICE_TEMPLATE=\"$sandbox/hysteria.service\"|" \
  "$repo_dir/v2ray.sh" > "$sandbox/manager.sh"
# shellcheck disable=SC1091
source "$sandbox/manager.sh"
# These tests isolate individual functions. Transaction/re-exec behavior is
# exercised separately in hardening.sh with a fully sandboxed child process.
run_mutation() { "$@"; }
mkdir -p "$BIN_DIR" "$ASSET_DIR" "$CONFIG_DIR" "$BACKUP_DIR"

install_dependencies() { :; }
sync_hysteria_services() { :; }
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
  local count=0 version_output
  [[ ! -f $sandbox/ticks ]] || read -r count < "$sandbox/ticks"
  case "$1" in
    is-active)
      [[ $scenario != update-stopped && $scenario != tls-renew-stopped ]] || return 1
      [[ $scenario != delayed-crash || $count -lt 2 ]] || return 1
      if [[ $scenario == update-rollback || $scenario == rollback-failure ]]; then
        version_output=$("$XRAY_BIN" version)
        [[ ${version_output%%$'\n'*} != candidate ]] || return 1
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
    daemon-reload|stop) : ;;
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
if [[ $1 == version ]]; then printf 'candidate\nadditional version details\n'; exit; fi
[[ ${CANDIDATE_INVALID:-0} != 1 ]]
CORE
  chmod +x "$1/core/xray"
  printf 'new-geoip\n' > "$1/core/geoip.dat"
  printf 'new-geosite\n' > "$1/core/geosite.dat"
}

case "$scenario" in
  caddy-port-conflict)
    jq -n '{inbounds:[{port:443}]}' > "$CONFIG_FILE"
    ss() { fail 'listener inspection should not run after Xray config conflict'; }
    if caddy_ports_available > "$sandbox/output" 2>&1; then fail 'Caddy accepted Xray port 443 conflict'; fi
    grep -Fq '无法与其共享端口' "$sandbox/output" || fail 'Caddy conflict reason missing'
    ;;
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
  acme-webroot|acme-caddy-webroot)
    mkdir -p "$sandbox/web root"
    SERVER_NAME=example.com
    getent() { return 0; }
    open_local_firewall_port() { :; }
    certbot() { printf '%s\n' "$@" > "$sandbox/certbot-args"; }
    if [[ $scenario == acme-webroot ]]; then
      V2M_ACME_WEBROOT="$sandbox/web root"
      ss() { fail 'explicit webroot mode must not require port 80 to be unused'; }
      systemctl() { :; }
    else
      unset V2M_ACME_WEBROOT
      mkdir -p "$CADDY_SITE_DIR" "$CADDY_WEB_ROOT/$SERVER_NAME"
      printf '%s {\n\troot * %s/%s\n\tfile_server\n}\n' "$SERVER_NAME" "$CADDY_WEB_ROOT" "$SERVER_NAME" > "$CADDY_SITE_DIR/$SERVER_NAME.caddy"
      systemctl() { [[ $1 == is-active && $3 == caddy ]] || [[ $1 == enable ]]; }
      ss() { printf '%s\n' 'LISTEN 0 4096 *:80'; }
      [[ $(managed_caddy_webroot "$SERVER_NAME") == "$CADDY_WEB_ROOT/$SERVER_NAME" ]] || fail 'managed Caddy webroot was not detected'
    fi
    issue_tls_material >/dev/null
    grep -Fx -- --webroot "$sandbox/certbot-args" >/dev/null || fail 'webroot mode missing'
    if [[ $scenario == acme-webroot ]]; then expected_webroot=$V2M_ACME_WEBROOT; else expected_webroot="$CADDY_WEB_ROOT/$SERVER_NAME"; fi
    grep -Fx -- "$expected_webroot" "$sandbox/certbot-args" >/dev/null || fail 'webroot path split'
    if grep -Fx -- --standalone "$sandbox/certbot-args" >/dev/null; then fail 'standalone used with webroot'; fi
    ;;
  healthy) service_healthy ;;
  delayed-crash|restarted-process)
    if service_healthy; then fail 'unhealthy process was accepted'; fi ;;
  invalid-core|download-failure|update-success|update-stopped|update-rollback|update-explicit-rollback|partial-copy|rollback-failure)
    version_output=
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
    export -f update_core rollback_core finish_core_update fetch_core install_core_files atomic_install \
      publish_manager_pointer install_dependencies install systemctl service_healthy restart_checked sleep die red green yellow
    export -f sync_hysteria_services
    if declare -F real_atomic_install >/dev/null; then export -f real_atomic_install; fi
    status=0
    bash -c 'set -Eeuo pipefail; SERVICE_NAME=xray; update_core; if [[ $scenario == update-explicit-rollback ]]; then rollback_core; fi' > "$sandbox/output" 2>&1 || status=$?
    case "$scenario" in
      update-explicit-rollback)
        [[ $status == 0 && $("$XRAY_BIN" version) == previous ]] || { cat "$sandbox/output"; fail 'explicit core rollback failed'; }
        [[ $(cat "$ASSET_DIR/geoip.dat") == old-geoip && $(cat "$ASSET_DIR/geosite.dat") == old-geosite ]] || fail 'explicit rollback lost GeoData'
        [[ -f $BACKUP_DIR/core.rollback ]] || fail 'core rollback pointer missing'
        ;;
      update-success|update-stopped)
        version_output=$("$XRAY_BIN" version)
        [[ $status == 0 && ${version_output%%$'\n'*} == candidate ]] || { cat "$sandbox/output"; fail 'update did not succeed'; }
        grep -Fxq 'candidate' "$sandbox/output" || fail 'updated version was not reported'
        if grep -Fq 'additional version details' "$sandbox/output"; then fail 'version report was not limited to one line'; fi
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
    # shellcheck disable=SC2016
    sed '/^if \[\[ "${BASH_SOURCE\[0\]}"/i require_root() { :; }\nrun_mutation() { "$@"; }' "$sandbox/manager.sh" > "$MANAGER_BIN"
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
    caddy() { :; }
    export scenario sandbox
    {
      printf 'set -Eeuo pipefail\nsource %q\n' "$sandbox/manager.sh"
      declare -f curl install systemctl sleep caddy fail
      printf 'update_manager\n'
    } > "$sandbox/update-test.sh"
    status=0
    bash "$sandbox/update-test.sh" > "$sandbox/output" 2>&1 || status=$?
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
    export ADDRESS=edge.example.com PROFILE=vless-reality-raw SERVER_NAME=example.com
    export PRIVATE_KEY=test-private PUBLIC_KEY=test-public SHORT_ID=0123456789abcdef
    export REMARK='node A & test' PATH_VALUE=
    # These cases exercise registry/URL behavior; real keys are covered by xray-config.sh.
    reality_pair_valid() { return 0; }
    save_current_node "$NODES_DIR/primary.env"
    render_config "$CONFIG_FILE"
    case "$scenario" in
      link-disabled-migrate)
        mv "$NODES_DIR/primary.env" "$NODES_DIR/primary.disabled"
        jq '.DATA_SCHEMA=1' "$NODES_DIR/primary.disabled" > "$sandbox/legacy.json"; cp "$sandbox/legacy.json" "$NODES_DIR/primary.disabled"
        rebuild_config_from_nodes
        migrate_project_state > "$sandbox/output"
        jq -e --argjson schema "$DATA_SCHEMA_VERSION" '.DATA_SCHEMA == $schema' "$NODES_DIR/primary.disabled" || fail 'disabled-only registry was not migrated'
        [[ ! -f $NODES_DIR/primary.env ]] || fail 'migration enabled a disabled node'
        jq -e '.inbounds | length == 0' "$CONFIG_FILE" >/dev/null || fail 'migration created an active inbound'
        ;;
      link-client-export)
        export_client primary > "$sandbox/client.json"
        jq -e '.outbounds[0].settings.vnext[0] | .address == "edge.example.com" and .port == 24443' "$sandbox/client.json" >/dev/null || fail 'client export not selected node JSON'
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
        [[ $output == *'@edge.example.com:24443?'* ]] || fail 'export used stale manager.env'
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
        if show_connection_loaded > "$sandbox/link" 2>/dev/null; then fail 'IPv6 address was exposed in link'; fi
        ! grep -q 'vless://' "$sandbox/link" || fail 'IPv6 link printed despite domain-only policy'
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
      link-multi-users)
        cat > "$XRAY_BIN" <<'CORE'
#!/usr/bin/env bash
if [[ $1 == uuid ]]; then
  count_file=${sandbox}/uuid-count
  count=0; [[ ! -f $count_file ]] || count=$(cat "$count_file")
  ((count+=1)); printf '%s' "$count" > "$count_file"
  printf '44444444-4444-4444-8444-%012d\n' "$count"
fi
CORE
        chmod +x "$XRAY_BIN"
        set_sub_link_count primary 3 > "$sandbox/output"
        # shellcheck disable=SC1090,SC1091
        load_state_file "$NODES_DIR/primary.env"
        [[ $(tr ',' '\n' <<<"$EXTRA_UUIDS" | wc -l) == 2 ]] || fail 'sub-link credentials not persisted'
        jq -e '.inbounds[0].settings.clients | length == 3' "$CONFIG_FILE" >/dev/null || fail 'three users not applied to Xray config'
        [[ $(grep -c 'vless://' "$sandbox/output") == 3 ]] || fail 'three sub-links not exported'
        if (replace_sub_link primary 4 > "$sandbox/missing-index-output" 2>&1); then
          fail 'replace accepted a missing sub-link index'
        fi
        grep -Fq 'v2ray users add primary 1' "$sandbox/missing-index-output" || fail 'missing-index error did not explain how to add a link'
        old_primary=$UUID
        old_second=$(cut -d, -f1 <<<"$EXTRA_UUIDS")
        add_sub_links primary 2 > "$sandbox/add-output"
        jq -e '.inbounds[0].settings.clients | length == 5' "$CONFIG_FILE" >/dev/null || fail 'sub-link add did not preserve and append users'
        replace_sub_link primary 2 > "$sandbox/replace-output"
        ! jq -e --arg old "$old_second" '.inbounds[0].settings.clients[] | select(.id == $old)' "$CONFIG_FILE" >/dev/null || fail 'replaced credential remained active'
        delete_sub_link primary 1 > "$sandbox/delete-output"
        jq -e '.inbounds[0].settings.clients | length == 4' "$CONFIG_FILE" >/dev/null || fail 'sub-link delete removed wrong number of users'
        ! jq -e --arg old "$old_primary" '.inbounds[0].settings.clients[] | select(.id == $old)' "$CONFIG_FILE" >/dev/null || fail 'deleted primary credential remained active'
        # shellcheck disable=SC1090,SC1091
        load_state_file "$NODES_DIR/primary.env"
        [[ $UUID != "$old_primary" ]] || fail 'deleting first credential did not promote the next user'
        list_sub_links primary > "$sandbox/list-output"
        grep -q '链接总数: 4' "$sandbox/list-output" || fail 'sub-link detail did not show link count'
        list_inbounds > "$sandbox/inbounds-output"
        grep -q 'REALITY 直连' "$sandbox/inbounds-output" || fail 'inbound list did not show protocol group'
        grep -Eq 'primary +启用 +VLESS-REALITY-Vision-RAW +4 +24443' "$sandbox/inbounds-output" || fail 'inbound list did not show link count'
        ;;
      link-project-migrate)
        EXTRA_UUIDS=22222222-2222-4222-8222-222222222222,33333333-3333-4333-8333-333333333333
        save_current_node "$NODES_DIR/primary.env"
        jq 'del(.DATA_SCHEMA)' "$NODES_DIR/primary.env" > "$sandbox/legacy.json"; cp "$sandbox/legacy.json" "$NODES_DIR/primary.env"
        rebuild_config_from_nodes
        before=$(config_connection_fingerprint "$CONFIG_FILE")
        migrate_project_state > "$sandbox/migrate-output"
        after=$(config_connection_fingerprint "$CONFIG_FILE")
        [[ $before == "$after" ]] || fail 'project migration changed connection parameters'
        jq -e --argjson schema "$DATA_SCHEMA_VERSION" '.DATA_SCHEMA == $schema' "$NODES_DIR/primary.env" >/dev/null || fail 'node schema marker missing after migration'
        jq -e --argjson schema "$DATA_SCHEMA_VERSION" '.DATA_SCHEMA == $schema' "$STATE_FILE" >/dev/null || fail 'manager schema marker missing after migration'
        jq -e '.inbounds[0].settings.clients | length == 3' "$CONFIG_FILE" >/dev/null || fail 'migration changed existing sub-links'
        jq 'del(.DATA_SCHEMA)' "$NODES_DIR/primary.env" > "$sandbox/legacy.json"; cp "$sandbox/legacy.json" "$NODES_DIR/primary.env"
        ensure_project_state_current doctor > "$sandbox/automatic-migrate-output"
        jq -e --argjson schema "$DATA_SCHEMA_VERSION" '.DATA_SCHEMA == $schema' "$NODES_DIR/primary.env" >/dev/null || fail 'automatic migration did not upgrade old node state'
        ;;
    esac
    ;;
esac
