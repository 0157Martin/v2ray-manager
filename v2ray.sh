#!/usr/bin/env bash
# Modern Xray/VLESS installer and manager, exposed through the v2ray command.
# Supported hosts: Debian and Ubuntu with systemd. Run as root.
# Author: Martin&林知远 (https://github.com/0157Martin)
# SPDX-License-Identifier: GPL-3.0-or-later
# State loaders intentionally assign shared uppercase fields inside isolated
# subshell functions; ShellCheck cannot follow those dynamic assignments.
# shellcheck disable=SC2030,SC2031
set -Eeuo pipefail

readonly APP_NAME="v2ray-manager"
readonly AUTHOR="Martin&林知远"
readonly MANAGER_VERSION="6.5.2"
readonly DATA_SCHEMA_VERSION="5"
readonly RECOMMENDED_XRAY_VERSION="v26.3.27"
readonly DEFAULT_PORT="443"
readonly DEFAULT_REALITY_SERVER_NAME="dl.google.com"
readonly BIN_DIR="/usr/local/bin"
readonly MANAGER_BIN="$BIN_DIR/v2ray"
readonly XRAY_BIN="$BIN_DIR/xray-core"
readonly ASSET_DIR="/usr/local/share/xray"
readonly CONFIG_DIR="/etc/xray"
readonly CONFIG_FILE="$CONFIG_DIR/config.json"
readonly TLS_DIR="$CONFIG_DIR/tls"
readonly TLS_CERT_FILE="$TLS_DIR/cert.pem"
readonly TLS_KEY_FILE="$TLS_DIR/key.pem"
readonly BACKUP_DIR="/var/backups/v2ray-manager"
readonly LEGACY_MANAGER_BACKUP="$BACKUP_DIR/legacy-v2ray-command"
readonly SERVICE_FILE="/etc/systemd/system/xray.service"
readonly STATE_FILE="$CONFIG_DIR/manager.env"
readonly WARP_STATE_FILE="$CONFIG_DIR/warp.env"
readonly WARP_BACKEND_STATE_FILE="$CONFIG_DIR/warp-backend.env"
readonly WARP_PROXY_PORT="40000"
readonly WARP_BACKEND_BIN_DIR="/usr/local/libexec/v2ray-manager"
readonly WARP_WIREGUARD_BIN="$WARP_BACKEND_BIN_DIR/warp-wireguard"
readonly WARP_MASQUE_BIN="$WARP_BACKEND_BIN_DIR/warp-masque"
readonly LOCK_FILE="/run/lock/v2ray-manager.lock"
readonly ACME_RENEWAL_DIR="/etc/letsencrypt/renewal"
readonly NODES_DIR="$CONFIG_DIR/nodes"
readonly RELEASE_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
readonly MANAGER_URL="https://raw.githubusercontent.com/0157Martin/v2ray-manager/main/v2ray.sh"
readonly MANAGER_API="https://api.github.com/repos/0157Martin/v2ray-manager/commits/main"
readonly SERVICE_NAME="xray"
readonly CADDY_CONFIG="/etc/caddy/Caddyfile"
readonly CADDY_SITE_DIR="/etc/caddy/conf.d"
readonly CADDY_WEB_ROOT="/var/www/v2ray-manager"
readonly CADDY_BRANCH_BIN="/usr/local/libexec/v2ray-manager/caddy-manager"
readonly CFIP_BRANCH_BIN="/usr/local/libexec/v2ray-manager/cloudflare-ip-manager"
readonly HYSTERIA_BIN="/usr/local/bin/hysteria"
readonly HYSTERIA_CONFIG_DIR="/etc/hysteria-v2ray-manager"
readonly HYSTERIA_SERVICE_TEMPLATE="/etc/systemd/system/hysteria-v2ray-manager@.service"
readonly HYSTERIA_VERSION="v2.13.0"

# Release lock embedded in the standalone artifact. Changes require review and
# tests; checksums are not fetched from the same mutable source as the scripts.
component_manifest() {
  case "$1" in
    caddy) printf '%s\n' '0157Martin/caddy-manager bfd682404b38e53280b227ad385843f5c1e6bc33 caddy-manager.sh 33b9e550e09e2629af606e70f53da1976aee3a4d300e1199899866565f13de17' ;;
    cfip) printf '%s\n' '0157Martin/cloudflare-ip-manager c6a2e4c8c8a7543e523468f396c6cdbae3b5564e cloudflare-ip-manager.sh a6ecf8bcc4e2ba26dbbb8aa2073c96736d6b95e40f079fb265f4cb9a8e599450' ;;
    wireguard) printf '%s\n' '0157Martin/warp-wireguard-manager bc1d425add8f172838ea450cfc2955ade1e73a0c warp-wireguard.sh fde080bb07f33a8caa3c8741d6cb47d281f05da683c0861c845799cf75df9040' ;;
    masque) printf '%s\n' '0157Martin/warp-masque-manager 93cd9564cb9e7d6872916dab5ef00bbf4d21816b warp-masque.sh e36c316d2920338b7b5526b0dc7e13a7ec219a08e51c57910d5d7a91db5a323b' ;;
    *) return 1 ;;
  esac
}

download_file() {
  curl --fail --show-error --location --proto '=https' --proto-redir '=https' \
    --retry 3 --connect-timeout 15 --max-time 120 --output "$2" "$1"
}

verify_component() {
  local manifest repository revision file expected actual
  manifest=$(component_manifest "$1") || return 1
  read -r repository revision file expected <<< "$manifest"
  [[ -f $2 && -x $2 ]] || return 1
  actual=$(sha256sum "$2") || return 1
  [[ ${actual%% *} == "$expected" ]] || {
    red "组件 $1 与本版本锁定摘要不符，请通过对应的 install/repair 命令更新。" >&2
    return 1
  }
}

install_component() (
  set -Eeuo pipefail
  local name=$1 destination=$2 repository revision file expected actual temporary manifest
  manifest=$(component_manifest "$name") || return 1
  read -r repository revision file expected <<< "$manifest"
  # Verify existing installations too; do not silently execute a mutable legacy copy.
  if [[ -f $destination && -x $destination ]]; then
    actual=$(sha256sum "$destination") || return 1
    [[ ${actual%% *} != "$expected" ]] || return 0
  fi
  acquire_mutation_lock || return 1
  if [[ ${V2M_INTERNAL_MIGRATION:-0} != 1 ]]; then require_no_pending_manager || return 1; fi
  temporary=$(mktemp) || return 1
  trap 'rm -f -- "$temporary"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  download_file "https://raw.githubusercontent.com/$repository/$revision/$file" "$temporary" || return 1
  actual=$(sha256sum "$temporary") || return 1
  [[ ${actual%% *} == "$expected" ]] || { red "组件 $name 的 SHA-256 校验失败，保留原文件。" >&2; return 1; }
  bash -n "$temporary" || return 1
  install -d -m 755 "$(dirname "$destination")" || return 1
  atomic_install "$temporary" "$destination" 755 || return 1
)

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
cyan_value() { printf '\033[36m%s\033[0m' "$*"; }
step() { printf '\033[33m%s\033[0m  %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { red "错误：$*"; exit 1; }
pause() { read -r -p "按 Enter 键返回菜单…" _; }

ui_box_top() { printf '\033[38;5;39m╭──────────────────────────────────────────────────────────────╮\033[0m\n'; }
ui_box_divider() { printf '\033[38;5;39m├──────────────────────────────────────────────────────────────┤\033[0m\n'; }
ui_box_bottom() { printf '\033[38;5;39m╰──────────────────────────────────────────────────────────────╯\033[0m\n'; }
ui_box_title() { ui_box_top; printf '\033[1;38;5;51m│  %s\033[0m\n' "$1"; ui_box_divider; }
ui_menu_item() { printf '\033[38;5;39m│\033[0m  %s\n' "$1"; }

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行：sudo bash $0"
}

# Start a fresh Bash so an interactive caller's `|| true` cannot disable errexit
# inside the mutation. Each operation owns one lock and one recovery snapshot.
run_mutation() {
  bash "${BASH_SOURCE[0]}" __mutation "$@"
}

acquire_mutation_lock() {
  # The update -> new manager -> migrate child inherits FD 9, preventing deadlock.
  if [[ ${V2M_LOCK_HELD:-0} == 1 && $(readlink /proc/self/fd/9 2>/dev/null) == "$LOCK_FILE" ]]; then
    return 0
  fi
  command -v flock >/dev/null || die "缺少 flock，请安装 util-linux 后重试。"
  exec 9>"$LOCK_FILE"
  flock -x 9 || die "无法取得配置写锁。"
  export V2M_LOCK_HELD=1
}

mutation_entry() {
  local operation=${1:-}
  case "$operation" in
    apply_desired|set_xhttp_mode) ;;
    install_xray|add_inbound|modify_inbound|disable_inbound|enable_inbound|delete_inbound|change_menu|rotate_reality_keys|add_sub_links|delete_sub_link|replace_sub_link|set_sub_link_count|service_action|install_caddy|configure_caddy_site|deploy_caddy_page|call_caddy_branch|call_cloudflare_ip_branch|install_warp|set_warp_policy|disable_warp_policy|set_warp_ip_strategy|repair_warp|uninstall_warp|update_core|rollback_core|update_manager|rollback_manager|recover_manager|restore_latest|manual_backup|open_enabled_inbound_ports|uninstall_xray|refresh_tls_certificates|migrate_project_state) ;;
    *) die "不允许的内部修改操作。" ;;
  esac
  acquire_mutation_lock
  # Manager transactions own a durable snapshot, including the executable. Do
  # not wrap them in the generic config-only EXIT handler or migrate first.
  case "$operation" in
    recover_manager) "$@"; return ;;
    update_manager|rollback_manager) require_no_pending_manager; "$@"; return ;;
  esac
  if [[ $operation != migrate_project_state || ${V2M_INTERNAL_MIGRATION:-0} != 1 ]]; then
    require_no_pending_manager
  fi
  begin_mutation_snapshot
  if [[ $operation != migrate_project_state && $operation != uninstall_xray ]]; then
    ensure_project_state_current menu
  fi
  "$@"
}

begin_mutation_snapshot() {
  umask 077
  install -d -m 700 "$BACKUP_DIR"
  MUTATION_SNAPSHOT=$(mktemp -d "$BACKUP_DIR/transaction.XXXXXX")
  local name path
  for name in config caddy-main caddy-sites service; do
    case "$name" in
      config) path=$CONFIG_DIR ;;
      caddy-main) path=$CADDY_CONFIG ;;
      caddy-sites) path=$CADDY_SITE_DIR ;;
      service) path=$SERVICE_FILE ;;
    esac
    if [[ -e $path ]]; then cp -a -- "$path" "$MUTATION_SNAPSHOT/$name"; fi
  done
  MUTATION_XRAY_ACTIVE=0; MUTATION_CADDY_ACTIVE=0
  systemctl is-active --quiet "$SERVICE_NAME" && MUTATION_XRAY_ACTIVE=1
  systemctl is-active --quiet caddy && MUTATION_CADDY_ACTIVE=1
  trap 'finish_mutation "$?"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

finish_mutation() {
  local status=$1 name path failed=0 xray_changed=0 caddy_changed=0 unit_changed=0 cancelled=0
  trap - EXIT INT TERM
  (( status == 125 )) && cancelled=1
  if (( status != 0 )); then
    for name in config caddy-main caddy-sites service; do
      case "$name" in
        config) path=$CONFIG_DIR ;;
        caddy-main) path=$CADDY_CONFIG ;;
        caddy-sites) path=$CADDY_SITE_DIR ;;
        service) path=$SERVICE_FILE ;;
      esac
      if diff -qr -- "$path" "$MUTATION_SNAPSHOT/$name" >/dev/null 2>&1; then continue; fi
      [[ -e $path || -e $MUTATION_SNAPSHOT/$name ]] || continue
      case "$name" in
        config) xray_changed=1 ;;
        service) xray_changed=1; unit_changed=1 ;;
        caddy-*) caddy_changed=1 ;;
      esac
      # Preserve failed material for recovery when a subsequent restore fails.
      if [[ -e $path ]]; then
        mv -- "$path" "$MUTATION_SNAPSHOT/failed-$name" || { failed=1; continue; }
      fi
      if [[ -e $MUTATION_SNAPSHOT/$name ]]; then
        cp -a -- "$MUTATION_SNAPSHOT/$name" "$path" || failed=1
      fi
    done
    if (( unit_changed )); then systemctl daemon-reload || failed=1; fi
    if (( MUTATION_XRAY_ACTIVE )); then
      if (( xray_changed )) || ! systemctl is-active --quiet "$SERVICE_NAME"; then restart_checked || failed=1; fi
    elif systemctl is-active --quiet "$SERVICE_NAME"; then
      systemctl stop "$SERVICE_NAME" || failed=1
    fi
    if (( MUTATION_CADDY_ACTIVE )); then
      if (( caddy_changed )) || ! systemctl is-active --quiet caddy; then systemctl restart caddy || failed=1; fi
    elif systemctl is-active --quiet caddy; then
      systemctl stop caddy || failed=1
    fi
    if (( failed )); then
      red "自动恢复未完成；完整现场保留在 $MUTATION_SNAPSHOT。" >&2
      exit 1
    fi
    if (( cancelled )); then
      yellow '已取消操作，配置和服务状态保持不变。' >&2
    else
      yellow '操作失败，已恢复修改前的配置、证书、Caddy 路由和服务状态。' >&2
    fi
  fi
  rm -rf -- "$MUTATION_SNAPSHOT"
  (( cancelled )) && exit 0
  exit "$status"
}

publish_config() (
  local source=$1 temporary
  temporary=$(mktemp "${CONFIG_FILE}.XXXXXX") || return 1
  trap 'rm -f -- "$temporary"' EXIT
  install -m 640 -o root -g xray "$source" "$temporary" || return 1
  mv -f -- "$temporary" "$CONFIG_FILE"
)

publish_tls_material() (
  local target=$1 cert=$2 key=$3 staging committed=0 changed=0
  staging=$(mktemp -d "$target/.publish.XXXXXX") || return 1
  chmod 700 "$staging" || return 1
  [[ ! -f $target/cert.pem ]] || cp -p "$target/cert.pem" "$staging/old-cert.pem" || return 1
  [[ ! -f $target/key.pem ]] || cp -p "$target/key.pem" "$staging/old-key.pem" || return 1
  trap '
    status=$?
    if (( changed && ! committed )); then
      for name in cert key; do
        if [[ -f $staging/old-$name.pem ]]; then
          cp -p "$staging/old-$name.pem" "$target/$name.pem" || exit 1
        else rm -f -- "$target/$name.pem" || exit 1; fi
      done
    fi
    rm -rf -- "$staging"
    exit "$status"
  ' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  install -m 640 -o root -g xray "$cert" "$staging/cert.pem" || return 1
  install -m 640 -o root -g xray "$key" "$staging/key.pem" || return 1
  changed=1
  mv -f -- "$staging/cert.pem" "$target/cert.pem" || return 1
  mv -f -- "$staging/key.pem" "$target/key.pem" || return 1
  committed=1
)

# Apply before WARP selection so neither direct nor SOCKS routing can bypass it.
# IPOnDemand also checks domain destinations, not just literal IP requests.
protect_outbound_targets() (
  local config=$1 temporary
  temporary=$(mktemp "${config}.XXXXXX") || return 1
  trap 'rm -f -- "$temporary"' EXIT
  jq '.routing = {domainStrategy:"IPOnDemand",rules:[
    {type:"field",domain:["full:localhost","domain:localhost"],outboundTag:"block"},
    {type:"field",ip:["0.0.0.0/8","10.0.0.0/8","100.64.0.0/10","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.168.0.0/16","224.0.0.0/4","240.0.0.0/4","::/128","::1/128","::/96","64:ff9b::/96","fc00::/7","fe80::/10","ff00::/8"],outboundTag:"block"}
  ]}' "$config" > "$temporary" || return 1
  cat "$temporary" > "$config"
)

check_caddy_renewal_compatibility() {
  local renewal
  for renewal in "$ACME_RENEWAL_DIR"/*.conf; do
    [[ -f $renewal ]] || continue
    if grep -Eq '^[[:space:]]*authenticator[[:space:]]*=[[:space:]]*standalone[[:space:]]*$' "$renewal"; then
      red "拒绝占用 TCP 80：$renewal 仍使用 Certbot standalone 续期。请先迁移到 DNS 或可用 webroot 验证并通过 certbot renew --dry-run，再启用 Caddy。" >&2
      return 1
    fi
  done
}

# An already-active Caddy owns TCP 80 today, so blocking a config reload cannot
# repair the existing renewal conflict and can prevent a required Xray/Caddy
# migration. Keep reporting that conflict in doctor, but gate only transitions
# that would newly start Caddy and take the HTTP challenge port.
check_caddy_activation_compatibility() {
  systemctl is-active --quiet caddy && return 0
  check_caddy_renewal_compatibility
}

migration_connection_fingerprint() {
  jq -cS '[.inbounds[] | select(.protocol != "hysteria") | {
    tag, listen, port, protocol, settings, streamSettings
  } | if .protocol == "vless" and .streamSettings.network == "xhttp" and
    (.streamSettings.security == "tls" or .streamSettings.security == "none") then
      .listen="127.0.0.1" | .streamSettings.security="none" | del(.streamSettings.tlsSettings)
    else . end] | sort_by(.tag)' "$1" | sha256sum | awk '{print $1}'
}

require_supported_os() {
  [[ -r /etc/os-release ]] || die "无法识别系统。"
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ ${ID:-} == "debian" || ${ID:-} == "ubuntu" ]] || die "仅支持 Debian/Ubuntu。"
  command -v systemctl >/dev/null || die "需要 systemd。"
}

install_dependencies() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl unzip jq coreutils iproute2 tar openssl gnupg util-linux diffutils
}

# Only modify a firewall that is already explicitly active.  We deliberately do
# not insert raw iptables/nftables rules: their persistence and policy are owned
# by the server administrator.
open_local_firewall_port() {
  local port=${1:?missing port} transport=${2:-tcp}
  valid_port "$port" || die "端口无效：$port"
  [[ $transport == tcp || $transport == udp ]] || die '端口传输类型无效。'

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${port}/${transport}" >/dev/null
    green "本机 UFW 已放行 ${transport^^} ${port}。"
    return
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${port}/${transport}" >/dev/null
    firewall-cmd --reload >/dev/null
    green "本机 firewalld 已放行 ${transport^^} ${port}。"
    return
  fi

  yellow "未检测到已启用的 UFW/firewalld；未修改本机防火墙规则。"
}

open_enabled_inbound_ports() (
  local node_file node_port transport seen=' '
  [[ -d $NODES_DIR ]] || { yellow "尚无入站配置可放行。"; return; }
  for node_file in "$NODES_DIR"/*.env; do
    [[ -e $node_file ]] || continue
    # shellcheck disable=SC1090
    load_state_file "$node_file"
    node_port=$PORT
    transport=$(profile_transport)
    [[ $seen == *" ${node_port}/${transport} "* ]] && continue
    seen+="${node_port}/${transport} "
    open_local_firewall_port "$node_port" "$transport"
  done
  yellow "云服务商安全组不会由脚本自动修改；请确认已放行上述对应 TCP/UDP 端口。"
)

ensure_service_user() {
  if ! getent passwd xray >/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin xray
  fi
}

arch_name() {
  case "$(uname -m)" in
    x86_64|amd64) printf '64' ;;
    aarch64|arm64) printf 'arm64-v8a' ;;
    armv7l|armv7) printf 'arm32-v7a' ;;
    *) die "不支持的 CPU 架构：$(uname -m)" ;;
  esac
}

valid_core_version() { [[ $1 =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; }

resolve_core_version() {
  local requested=${1:-${V2M_XRAY_VERSION:-$RECOMMENDED_XRAY_VERSION}} tag
  if [[ $requested != latest ]]; then
    valid_core_version "$requested" || { red '内核版本必须是 v 开头的完整发布标签。' >&2; return 1; }
    printf '%s\n' "$requested"
    return
  fi
  tag=$(curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --retry 3 --connect-timeout 15 --max-time 60 -H 'Accept: application/vnd.github+json' \
    "$RELEASE_API" | jq -er '.tag_name') || return 1
  valid_core_version "$tag" || { red '无法读取有效的 Xray 发布标签。' >&2; return 1; }
  printf '%s\n' "$tag"
}

check_core_update() {
  local tag
  tag=$(resolve_core_version "${1:-}") || return 1
  printf '当前内核：%s\n固定基线：%s\n目标版本：%s\n' "$(command_version_line "$XRAY_BIN" '未安装')" "$RECOMMENDED_XRAY_VERSION" "$tag"
}

core_update_command() {
  local version='' check=0 version_seen=0
  while (( $# )); do
    case "$1" in
      --version)
        (( $# >= 2 && ! version_seen )) || die '用法：v2ray update.core [--version <vX.Y.Z> | --latest] [--check]'
        version=$2; version_seen=1; valid_core_version "$version" || die '无效的内核版本。'; shift 2 ;;
      --latest)
        (( ! version_seen )) || die '--latest 与 --version 不能同时指定。'
        version=latest; version_seen=1; shift ;;
      --check) check=1; shift ;;
      *) die '用法：v2ray update.core [--version <vX.Y.Z> | --latest] [--check]' ;;
    esac
  done
  if (( check )); then check_core_update "$version"; else run_mutation update_core "$version"; fi
}

fetch_core() {
  local temp_dir=$1 arch tag url expected actual
  arch=$(arch_name) || return 1
  tag=$(resolve_core_version "${2:-}") || return 1
  url="https://github.com/XTLS/Xray-core/releases/download/${tag}/Xray-linux-${arch}.zip"
  step "下载 Xray Core > ${tag} (${arch})"
  curl --fail --show-error --location --retry 3 --connect-timeout 15 --max-time 600 \
    --output "$temp_dir/xray.zip" "$url" || return 1
  curl --fail --show-error --location --retry 3 --connect-timeout 15 --max-time 60 \
    --output "$temp_dir/xray.zip.dgst" "${url}.dgst" || return 1
  expected=$(awk -F '= ' '/256=/ {gsub(/\r/, "", $2); print $2; exit}' "$temp_dir/xray.zip.dgst") || return 1
  actual=$(sha256sum "$temp_dir/xray.zip" | awk '{print $1}') || return 1
  [[ -n "$expected" && "${expected,,}" == "$actual" ]] || die "Xray 发布包 SHA-256 校验失败。"

  unzip -q "$temp_dir/xray.zip" -d "$temp_dir/core" || return 1
  [[ -x "$temp_dir/core/xray" ]] || die "发布包内没有 xray 可执行文件。"
  [[ -s "$temp_dir/core/geoip.dat" && -s "$temp_dir/core/geosite.dat" ]] || die "发布包缺少 GeoData。"
}

# Replace through a same-directory temporary file, including a running executable.
atomic_install() {
  local source=$1 target=$2 mode=$3 temporary
  temporary=$(mktemp "${target}.XXXXXX") || return 1
  if install -m "$mode" "$source" "$temporary" && mv -f -- "$temporary" "$target"; then
    return 0
  fi
  rm -f -- "$temporary"
  return 1
}

install_core_files() {
  local source=$1
  atomic_install "$source/xray" "$XRAY_BIN" 755 || return 1
  atomic_install "$source/geoip.dat" "$ASSET_DIR/geoip.dat" 644 || return 1
  atomic_install "$source/geosite.dat" "$ASSET_DIR/geosite.dat" 644
}

download_core() (
  set -Eeuo pipefail
  install_dependencies
  local temp_dir
  temp_dir=$(mktemp -d)
  trap 'rm -rf -- "$temp_dir"' EXIT
  fetch_core "$temp_dir"
  install -d -m 755 "$BIN_DIR" "$ASSET_DIR" "$CONFIG_DIR"
  install_core_files "$temp_dir/core"
)

valid_port() { [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
valid_uuid() { [[ $1 =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }
valid_node_id() { [[ $1 =~ ^[A-Za-z0-9._-]+$ ]]; }
valid_server_name() {
  [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && $1 == *.* && $1 != *..* ]] &&
    ! [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}
valid_public_ipv4() {
  local ip=${1:-} octet
  local -a octets
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a octets <<<"$ip"
  for octet in "${octets[@]}"; do ((10#$octet <= 255)) || return 1; done
  case "$ip" in
    0.*|10.*|127.*|169.254.*|192.0.0.*|192.0.2.*|192.168.*|198.18.*|198.19.*|198.51.100.*|203.0.113.*|224.*|225.*|226.*|227.*|228.*|229.*|230.*|231.*|232.*|233.*|234.*|235.*|236.*|237.*|238.*|239.*|24[0-9].*|25[0-5].*) return 1 ;;
  esac
  [[ ${octets[0]} -ne 172 || ${octets[1]} -lt 16 || ${octets[1]} -gt 31 ]]
}
reality_target_supported() { [[ ${1,,} != www.microsoft.com && ${1,,} != microsoft.com ]]; }
check_reality_target() {
  local target=$1 output
  command -v openssl >/dev/null && command -v timeout >/dev/null || return 2
  output=$(timeout 12 openssl s_client -connect "$target:443" -servername "$target" \
    -verify_hostname "$target" -tls1_3 -groups X25519 -alpn h2 </dev/null 2>&1 || true)
  [[ $output == *'TLSv1.3'* || $output == *'TLSv1.3,'* ]] || return 1
  [[ $output == *'ALPN protocol: h2'* ]] || return 1
  [[ $output == *'Verify return code: 0 (ok)'* ]] || return 1
}
valid_transport_path() { [[ $1 =~ ^/[A-Za-z0-9._~/-]+$ && $1 != *//* ]]; }
valid_route_target() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9.:%_-]*$ && $1 != *..* ]]; }
valid_profile() { [[ $1 == vless-reality-raw || $1 == vless-reality-xhttp || $1 == vless-reality-grpc || $1 == vless-tls-raw || $1 == vless-tls-xhttp || $1 == vless-tls-ws || $1 == vless-tls-grpc || $1 == trojan-reality-raw || $1 == vmess-tcp || $1 == vmess-tls-ws || $1 == vmess-tls-grpc || $1 == trojan-tls-ws || $1 == hysteria-tls-quic ]]; }
profile_transport() { if [[ ${PROFILE:-} == hysteria-tls-quic ]]; then printf udp; else printf tcp; fi; }
profile_available_for_new_deployment() { valid_profile "${1:-${PROFILE:-}}"; }
valid_xhttp_mode() { [[ $1 == auto || $1 == packet-up || $1 == stream-up ]]; }
profile_uses_tls() { [[ ${PROFILE:-} == *-tls-* ]]; }
# TLS-XHTTP terminates public TLS at Caddy. Its Xray listener is a loopback
# h2c upstream, so it neither owns a certificate nor exposes its backend port.
profile_requires_xray_tls() { [[ ${PROFILE:-} == *-tls-* && ${PROFILE:-} != vless-tls-xhttp ]]; }
profile_uses_reality() { [[ ${PROFILE:-vless-reality-raw} == *-reality-* ]]; }
profile_supports_caddy_route() {
  case "${1:-${PROFILE:-}}" in
    vless-tls-xhttp|vless-tls-ws|vmess-tls-ws|trojan-tls-ws) return 0 ;;
    *) return 1 ;;
  esac
}

profile_group() {
  case ${PROFILE:-vless-reality-raw} in
    *-reality-*) printf 'reality' ;;
    *-tls-xhttp|*-tls-ws|*-tls-grpc) printf 'http-tls' ;;
    vless-tls-raw|hysteria-tls-quic) printf 'modern-direct' ;;
    vmess-tcp) printf 'compatibility' ;;
    *) printf 'other' ;;
  esac
}

profile_name() {
  case ${PROFILE:-vless-reality-raw} in
    vless-reality-raw) printf 'VLESS-REALITY-Vision-RAW' ;;
    vless-reality-xhttp) printf 'VLESS-REALITY-XHTTP' ;;
    vless-reality-grpc) printf 'VLESS-REALITY-gRPC' ;;
    vless-tls-xhttp) printf 'VLESS-XHTTP-TLS' ;;
    vless-tls-ws) printf 'VLESS-WebSocket-TLS' ;;
    vless-tls-grpc) printf 'VLESS-gRPC-TLS' ;;
    vless-tls-raw) printf 'VLESS-TLS-Vision-RAW' ;;
    trojan-reality-raw) printf 'Trojan-REALITY-RAW' ;;
    vmess-tcp) printf 'VMess-TCP-Legacy' ;;
    vmess-tls-ws) printf 'VMess-WebSocket-TLS-Legacy' ;;
    vmess-tls-grpc) printf 'VMess-gRPC-TLS-Legacy' ;;
    trojan-tls-ws) printf 'Trojan-WebSocket-TLS' ;;
    hysteria-tls-quic) printf 'Hysteria-2-TLS-QUIC (官方服务端)' ;;
  esac
}

# Menu numbers are presentation-only. Persisted state and non-interactive
# automation use the stable profile IDs returned here, so a menu reorder never
# rewrites an existing node or changes its connection semantics.
profile_from_menu_choice() {
  case ${1:-} in
    1) printf 'vless-reality-raw' ;;
    2) printf 'vless-reality-xhttp' ;;
    3) printf 'vless-reality-grpc' ;;
    4) printf 'trojan-reality-raw' ;;
    5) printf 'vless-tls-xhttp' ;;
    6) printf 'vless-tls-ws' ;;
    7) printf 'vless-tls-grpc' ;;
    8) printf 'vmess-tls-ws' ;;
    9) printf 'vmess-tls-grpc' ;;
    10) printf 'trojan-tls-ws' ;;
    11) printf 'vless-tls-raw' ;;
    12) printf 'hysteria-tls-quic' ;;
    13) printf 'vmess-tcp' ;;
    *) return 1 ;;
  esac
}

choose_profile() {
  local choice default_path
  printf '\n'
  ui_box_title '选择协议组合'
  ui_menu_item '直连 / Cloudflare 灰云 DNS（不能经过普通橙云）'
  ui_menu_item '1) VLESS-REALITY-Vision-RAW  [高级：目标站/客户端兼容性通过检测后使用]'
  ui_menu_item '2) VLESS-REALITY-XHTTP       [新式 HTTP 传输；REALITY 仍须直连]'
  ui_menu_item '3) VLESS-REALITY-gRPC        [HTTP/2 传输；REALITY 仍须直连]'
  ui_menu_item '4) Trojan-REALITY-RAW        [Trojan 认证语义；REALITY 仍须直连]'
  ui_box_divider
  ui_menu_item 'HTTP/CDN / Cloudflare 橙云（需要自有域名）'
  ui_menu_item '5) VLESS-XHTTP-TLS           [Caddy 终止 TLS，h2c 转发；适合 CDN]'
  ui_menu_item '6) VLESS-WebSocket-TLS       [客户端兼容广，适合 Caddy/CDN]'
  ui_menu_item '7) VLESS-gRPC-TLS            [适合现有 HTTP/2 反向代理]'
  ui_menu_item '8) VMess-WebSocket-TLS       [VMess 兼容；可经 Caddy/CDN]'
  ui_menu_item '9) VMess-gRPC-TLS            [VMess 兼容；适合既有 HTTP/2 反代]'
  ui_menu_item '10) Trojan-WebSocket-TLS     [传统 Trojan + WS + TLS]'
  ui_box_divider
  ui_menu_item '现代证书直连（不能经过普通橙云）'
  ui_menu_item '11) VLESS-TLS-Vision-RAW     [自有证书、直连；RAW 不走橙云]'
  ui_menu_item '12) Hysteria 2 TLS/QUIC      [官方 Hysteria 服务端；UDP/QUIC 直连]'
  ui_box_divider
  ui_menu_item '兼容保留（新部署不优先）'
  ui_menu_item '13) VMess-TCP                [无 TLS，仅限旧客户端或可信链路]'
  ui_box_divider
  ui_menu_item '0) 取消并返回'
  ui_box_bottom
  read -r -p '请选择协议组合 [0-13]:' choice
  if [[ $choice == 0 ]]; then
    yellow '已取消协议选择。'
    return 125
  fi
  PROFILE=$(profile_from_menu_choice "$choice") || die "协议组合选择无效。"
  case "$PROFILE" in
    vless-reality-raw|trojan-reality-raw|vmess-tcp) PATH_VALUE='' ;;
    vless-reality-xhttp)
      default_path=${PATH_VALUE:-/$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')}
      [[ $default_path == /* ]] || default_path="/$default_path"
      read -r -p "XHTTP 路径 [${default_path}]:" PATH_VALUE
      PATH_VALUE=${PATH_VALUE:-$default_path}
      [[ $PATH_VALUE == /* ]] || PATH_VALUE="/$PATH_VALUE"
      ;;
    vless-reality-grpc)
      default_path=${PATH_VALUE:-grpc-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')}
      default_path=${default_path#/}
      read -r -p "gRPC serviceName [${default_path}]:" PATH_VALUE
      PATH_VALUE=${PATH_VALUE:-$default_path}
      PATH_VALUE=${PATH_VALUE#/}
      ;;
    *-tls-xhttp|*-tls-ws|*-tls-grpc)
      default_path=${PATH_VALUE:-/$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')}
      if [[ $PROFILE == *-tls-grpc ]]; then
        default_path=${default_path#/}; read -r -p "gRPC serviceName [${default_path}]:" PATH_VALUE; PATH_VALUE=${PATH_VALUE:-$default_path}; PATH_VALUE=${PATH_VALUE#/}
      else
        [[ $default_path == /* ]] || default_path="/$default_path"; read -r -p "传输路径 [${default_path}]:" PATH_VALUE; PATH_VALUE=${PATH_VALUE:-$default_path}; [[ $PATH_VALUE == /* ]] || PATH_VALUE="/$PATH_VALUE"
      fi
      # Resolve certificates after SERVER_NAME has been collected.
      CERT_SOURCE=
      KEY_SOURCE=
      ;;
    vless-tls-raw|hysteria-tls-quic) PATH_VALUE=''; CERT_SOURCE=''; KEY_SOURCE='' ;;
  esac
  green "已选择协议：$(profile_name)"
}

generate_reality_credentials() {
  local output
  output=$("$XRAY_BIN" x25519)
  parse_reality_credentials "$output"
  SHORT_ID=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
  [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" && ${#SHORT_ID} -eq 16 ]] || die "无法生成 REALITY 凭据。"
  reality_pair_valid || die "生成的 REALITY 凭据未通过校验。"
}

parse_reality_credentials() {
  local output=${1//$'\r'/}
  PRIVATE_KEY=$(awk -F ': *' '/^PrivateKey:|^Private key:/ {print $2; exit}' <<<"$output")
  PUBLIC_KEY=$(awk -F ': *' '/^Password \(PublicKey\):|^Password:|^Public key:/ {print $2; exit}' <<<"$output")
}

reality_pair_valid() (
  local expected_public=${PUBLIC_KEY:-} derived_public
  [[ ${PRIVATE_KEY:-} =~ ^[A-Za-z0-9_-]{43}$ && $expected_public =~ ^[A-Za-z0-9_-]{43}$ ]] || return 1
  [[ ${SHORT_ID:-} =~ ^([0-9a-fA-F]{2}){0,8}$ ]] || return 1
  # RFC 8410 PKCS#8 X25519 prefix followed by the 32 private bytes. Feed the
  # private key over stdin so it never appears in another process's argv.
  derived_public=$({
    printf '\x30\x2e\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x6e\x04\x22\x04\x20'
    printf '%s=' "$PRIVATE_KEY" | tr '_-' '/+' | base64 -d
  } | openssl pkey -inform DER -pubout -outform DER 2>/dev/null |
    tail -c 32 | base64 -w 0 | tr '/+' '_-' | tr -d '=') || return 1
  [[ $derived_public == "$expected_public" ]]
)

ask_server_values() {
  local default_port default_uuid default_name default_server
  if [[ -n ${PORT:-} ]]; then default_port=$PORT; else default_port=$(find_free_port "$DEFAULT_PORT"); fi
  default_uuid=${UUID:-$("$XRAY_BIN" uuid)}
  default_name=${REMARK:-xray-reality}
  default_server=${SERVER_NAME:-$DEFAULT_REALITY_SERVER_NAME}
  local previous_profile=${PROFILE:-vless-reality-raw}

  if [[ ${V2M_NONINTERACTIVE:-0} == 1 ]]; then
    PROFILE=${V2M_PROFILE:-${PROFILE:-vless-reality-raw}}
    XHTTP_MODE=${V2M_XHTTP_MODE:-${XHTTP_MODE:-auto}}
    valid_xhttp_mode "$XHTTP_MODE" || die 'XHTTP 模式必须为 auto、packet-up 或 stream-up。'
    PATH_VALUE=${V2M_PATH:-${PATH_VALUE:-}}
    valid_profile "$PROFILE" || die "V2M_PROFILE 无效。"
    if [[ $PROFILE == *-tls-ws || $PROFILE == vless-reality-xhttp || $PROFILE == vless-tls-xhttp ]]; then
      PATH_VALUE=${PATH_VALUE:-/xhttp}
      [[ $PATH_VALUE == /* ]] || PATH_VALUE="/$PATH_VALUE"
    elif [[ $PROFILE == *-tls-grpc || $PROFILE == vless-reality-grpc ]]; then
      PATH_VALUE=${PATH_VALUE:-grpc}
      PATH_VALUE=${PATH_VALUE#/}
    else
      PATH_VALUE=''
    fi
    if profile_uses_tls; then
      CERT_SOURCE=${V2M_CERT_FILE:-${CERT_SOURCE:-}}
      KEY_SOURCE=${V2M_KEY_FILE:-${KEY_SOURCE:-}}
      if [[ $previous_profile != *-tls-* && -z ${V2M_SERVER_NAME:-} ]]; then
        die "TLS 自动证书需要 V2M_SERVER_NAME 指定你拥有的域名。"
      fi
    fi
    if [[ -n ${V2M_PORT:-} ]]; then
      PORT=$V2M_PORT
    elif [[ -z ${PORT:-} ]]; then
      if [[ $PROFILE == *-tls-xhttp || $PROFILE == *-tls-ws || $PROFILE == *-tls-grpc ]]; then
        PORT=$(find_free_port 24443)
      else
        PORT=$(find_free_port "$DEFAULT_PORT")
      fi
    fi
    UUID=${V2M_UUID:-$default_uuid}
    SERVER_NAME=${V2M_SERVER_NAME:-$default_server}
    REMARK=${V2M_REMARK:-$default_name}
    ADDRESS=${V2M_ADDRESS:-${ADDRESS:-}}
    if [[ -z $ADDRESS ]] && profile_uses_tls; then ADDRESS=$SERVER_NAME; fi
    valid_port "$PORT" || die "V2M_PORT 必须是 1 到 65535 的端口。"
    valid_uuid "$UUID" || die "V2M_UUID 格式无效。"
    valid_server_name "$SERVER_NAME" || die "V2M_SERVER_NAME 必须是有效完整域名。"
    if profile_uses_reality && ! reality_target_supported "$SERVER_NAME"; then
      die "当前 Xray 版本已知无法稳定使用 $SERVER_NAME 作为 REALITY 目标；请改用 dl.google.com。"
    fi
    valid_server_name "$ADDRESS" || die "为避免在分享链接中暴露公网 IP，V2M_ADDRESS 必须是指向服务器的完整域名。"
    if profile_uses_reality && [[ -z ${PRIVATE_KEY:-} || -z ${PUBLIC_KEY:-} || -z ${SHORT_ID:-} ]]; then
      generate_reality_credentials
    fi
    return
  fi

  choose_profile
  if profile_uses_tls && [[ $previous_profile != *-tls-* ]]; then default_server=; fi
  if [[ -z ${PORT:-} && ( $PROFILE == *-tls-xhttp || $PROFILE == *-tls-ws || $PROFILE == *-tls-grpc ) ]]; then
    default_port=$(find_free_port 24443)
    yellow "HTTP/CDN 协议默认让 Xray 使用后端端口 $default_port，为 Caddy 保留公网 443。"
  fi

  while :; do
    read -r -p "监听端口 [${default_port}]：" PORT
    PORT=${PORT:-$default_port}
    valid_port "$PORT" && break
    yellow "请输入 1 到 65535 的端口。"
  done
  UUID=$default_uuid
  valid_uuid "$UUID" || die "UUID 格式无效。"
  green "UUID 已自动生成或沿用现有值；需要手动修改时可使用 v2ray change。"
  while :; do
    if profile_uses_tls; then
      read -r -p "你拥有的 TLS 域名（自动匹配或申请证书）[${default_server}]：" SERVER_NAME
    else
      read -r -p "REALITY 目标域名 [${default_server}]：" SERVER_NAME
    fi
    SERVER_NAME=${SERVER_NAME:-$default_server}
    if valid_server_name "$SERVER_NAME"; then
      if profile_uses_reality && ! reality_target_supported "$SERVER_NAME"; then
        yellow "当前 Xray 版本已知无法稳定使用 $SERVER_NAME 作为 REALITY 目标，请改用 dl.google.com。"
        continue
      fi
      if profile_uses_reality; then
        if check_reality_target "$SERVER_NAME"; then
          green "REALITY 目标已通过 TLS 1.3、H2、证书和 SNI 检查。"
        else
          case $? in
            2) yellow '缺少 openssl/timeout，暂时无法验证 REALITY 目标。' ;;
            *) yellow "目标 $SERVER_NAME 未通过 REALITY 必要条件检查，请更换目标域名。"; continue ;;
          esac
        fi
      fi
      break
    fi
    yellow "请输入有效的完整域名，例如 dl.google.com。"
  done
  if profile_uses_tls; then
    ADDRESS=$SERVER_NAME
    green "分享链接入口域名将使用：$ADDRESS"
  else
    while :; do
      read -r -p "客户端入口域名（须指向本机；REALITY 使用灰云）[${ADDRESS:-}]：" value
      ADDRESS=${value:-${ADDRESS:-}}
      valid_server_name "$ADDRESS" && break
      yellow "请输入完整域名；为避免泄露公网 IP，分享链接不接受 IP 地址。"
    done
  fi
  read -r -p "备注名称 [${default_name}]：" REMARK
  REMARK=${REMARK:-$default_name}

  if profile_uses_reality && [[ -z ${PRIVATE_KEY:-} || -z ${PUBLIC_KEY:-} || -z ${SHORT_ID:-} ]]; then
    generate_reality_credentials
  fi
}

# Require a current certificate for this hostname and a matching private key.
tls_pair_valid() {
  local cert=$1 key=$2 cert_public key_public not_before starts now
  [[ -r $cert && -r $key ]] || return 1
  openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 || return 1
  # Some OpenSSL releases print a mismatch but still return status 0 for
  # -checkhost, so require its explicit positive result as well.
  openssl x509 -in "$cert" -noout -checkhost "$SERVER_NAME" 2>/dev/null |
    grep -Fqx "Hostname $SERVER_NAME does match certificate" || return 1
  not_before=$(openssl x509 -in "$cert" -noout -startdate 2>/dev/null) || return 1
  starts=$(date -u -d "${not_before#notBefore=}" +%s 2>/dev/null) || return 1
  now=$(date -u +%s) || return 1
  (( starts <= now )) || return 1
  cert_public=$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null) || return 1
  key_public=$(openssl pkey -in "$key" -passin pass: -pubout 2>/dev/null) || return 1
  [[ $cert_public == "$key_public" ]]
}

tls_chain_valid() {
  openssl verify -purpose sslserver -verify_hostname "$SERVER_NAME" -untrusted "$1" "$1" >/dev/null 2>&1
}

find_tls_material() {
  local cert key
  # Prefer renewable sources to the installed copy. Never read private-key contents into logs.
  for cert in /etc/letsencrypt/live/*/fullchain.pem; do
    key="${cert%/*}/privkey.pem"
    if tls_pair_valid "$cert" "$key" && tls_chain_valid "$cert"; then
      CERT_SOURCE=$cert; KEY_SOURCE=$key; return 0
    fi
  done
  # acme.sh internal files are not deployment paths; use --install-cert first.
  for cert in "$TLS_DIR/$SERVER_NAME/cert.pem" "$TLS_CERT_FILE"; do
    key="${cert%/*}/key.pem"
    if tls_pair_valid "$cert" "$key" && tls_chain_valid "$cert"; then
      CERT_SOURCE=$cert; KEY_SOURCE=$key; return 0
    fi
  done
  return 1
}

install_tls_renew_hook() {
  local hook=/etc/letsencrypt/renewal-hooks/deploy/v2ray-manager
  install -d -m 755 "${hook%/*}"
  cat > "$hook" <<'HOOK'
#!/usr/bin/env bash
set -Eeuo pipefail
exec /usr/local/bin/v2ray cert-refresh "${RENEWED_LINEAGE:?Missing renewed lineage}"
HOOK
  chmod 750 "$hook"
}

refresh_tls_domain() (
  local target=$1 lineage=$2 backup active=0 changed=0 committed=0
  valid_server_name "${target##*/}" || return 1
  if ! SERVER_NAME=${target##*/} tls_pair_valid "$lineage/fullchain.pem" "$lineage/privkey.pem" ||
    ! SERVER_NAME=${target##*/} tls_chain_valid "$lineage/fullchain.pem"; then
      red "拒绝部署 ${target##*/}：续期证书、私钥、域名或 CA 信任校验失败。" >&2; return 1;
  fi
  backup=$(mktemp -d "$target/.renewal.XXXXXX") || return 1
  chmod 700 "$backup" || return 1
  cp -p "$target/cert.pem" "$backup/cert.pem" || return 1
  cp -p "$target/key.pem" "$backup/key.pem" || return 1
  systemctl is-active --quiet "$SERVICE_NAME" && active=1
  trap '
    status=$?
    if (( changed && ! committed )); then
      if cp -p "$backup/cert.pem" "$target/cert.pem" && cp -p "$backup/key.pem" "$target/key.pem"; then
        if (( active )); then restart_checked || red "旧证书已恢复，但服务恢复失败。" >&2; fi
      else
        red "证书回滚失败，请从备份恢复。" >&2
      fi
      red "续期部署失败，备份保留在 $backup" >&2
    fi
    exit "$status"
  ' EXIT
  install -m 640 -o root -g xray "$lineage/fullchain.pem" "$backup/new-cert.pem" || return 1
  install -m 640 -o root -g xray "$lineage/privkey.pem" "$backup/new-key.pem" || return 1
  changed=1
  mv -f "$backup/new-cert.pem" "$target/cert.pem" || return 1
  mv -f "$backup/new-key.pem" "$target/key.pem" || return 1
  "$XRAY_BIN" run -test -config "$CONFIG_FILE" || return 1
  if (( active )); then restart_checked || return 1; fi
  committed=1
  rm -f -- "$backup/cert.pem" "$backup/key.pem"
  rmdir -- "$backup"
)

refresh_tls_certificates() (
  local lineage=${1:-} target failures=0
  [[ $lineage == /* && -d $lineage ]] || { red "请指定续期证书目录的绝对路径。" >&2; return 1; }
  for target in "$TLS_DIR"/*; do
    [[ -d $target && -r $target/source ]] || continue
    [[ $(cat "$target/source") == "$lineage" ]] || continue
    refresh_tls_domain "$target" "$lineage" || failures=1
  done
  return "$failures"
)

issue_tls_material() {
  local webroot=''
  local -a challenge_args=(--standalone)
  if [[ -n ${V2M_ACME_WEBROOT:-} ]]; then
    [[ $V2M_ACME_WEBROOT == /* && -d $V2M_ACME_WEBROOT ]] || die "V2M_ACME_WEBROOT 必须是已有网站根目录的绝对路径。"
    webroot=$V2M_ACME_WEBROOT
  elif webroot=$(managed_caddy_webroot "$SERVER_NAME"); then
    green "检测到由本项目管理的 Caddy 站点，使用 webroot 申请证书：$webroot"
  fi
  if [[ -n $webroot ]]; then
    challenge_args=(--webroot --webroot-path "$webroot")
  else
    [[ -z $(ss -H -lnt 'sport = :80') ]] || die "TCP 80 已占用且未确认当前域名的 Caddy webroot；请先用 v2ray caddy 配置该域名、设置 V2M_ACME_WEBROOT，或提供已有证书。"
  fi
  getent ahosts "$SERVER_NAME" >/dev/null || die "域名无法解析，请先将 $SERVER_NAME 解析到本服务器。"
  if ! command -v certbot >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y certbot
  fi
  open_local_firewall_port 80
  yellow "正在向 Let's Encrypt 申请 $SERVER_NAME 的证书（接受其服务条款）。域名须指向本服务器，公网 TCP 80 须可访问。"
  local -a account_args=(--register-unsafely-without-email)
  [[ -z ${V2M_ACME_EMAIL:-} ]] || account_args=(--email "$V2M_ACME_EMAIL")
  certbot certonly "${challenge_args[@]}" --non-interactive --agree-tos "${account_args[@]}" \
    --preferred-challenges http --cert-name "$SERVER_NAME" -d "$SERVER_NAME" || \
    die "证书申请失败；检查域名 A/AAAA 记录、公网 TCP 80 和网站 challenge 路径后重试。"
  CERT_SOURCE="/etc/letsencrypt/live/$SERVER_NAME/fullchain.pem"
  KEY_SOURCE="/etc/letsencrypt/live/$SERVER_NAME/privkey.pem"
  systemctl enable --now certbot.timer
}

managed_caddy_webroot() {
  local domain=$1 site_file="$CADDY_SITE_DIR/$1.caddy" webroot="$CADDY_WEB_ROOT/$1"
  valid_server_name "$domain" || return 1
  systemctl is-active --quiet caddy || return 1
  [[ -f $site_file && -d $webroot ]] || return 1
  grep -Fq "root * $webroot" "$site_file" || return 1
  printf '%s\n' "$webroot"
}

prepare_tls_material() {
  profile_requires_xray_tls || return 0
  valid_server_name "$SERVER_NAME" || die "TLS 需要有效域名。"
  command -v openssl >/dev/null || { apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y openssl; }
  if [[ -n ${CERT_SOURCE:-} || -n ${KEY_SOURCE:-} ]]; then
    tls_pair_valid "${CERT_SOURCE:-}" "${KEY_SOURCE:-}" || die "指定的 TLS 证书/私钥无效、过期、不匹配或不属于 $SERVER_NAME。"
  elif ! find_tls_material; then
    issue_tls_material
  fi
  tls_pair_valid "$CERT_SOURCE" "$KEY_SOURCE" || die "未取得有效的 TLS 证书和私钥。"
  if ! tls_chain_valid "$CERT_SOURCE"; then
    yellow "指定证书未通过本机系统 CA 信任校验；使用自建 CA 时，客户端需安装对应 CA，否则会拒绝连接。"
  fi
  local target="$TLS_DIR/$SERVER_NAME"
  install -d -m 750 -o root -g xray "$TLS_DIR" "$target"
  publish_tls_material "$target" "$CERT_SOURCE" "$KEY_SOURCE" || return 1
  if [[ $CERT_SOURCE == /etc/letsencrypt/live/*/fullchain.pem ]]; then
    printf '%s\n' "${CERT_SOURCE%/*}" > "$target/source"
    chmod 600 "$target/source"
    install_tls_renew_hook
  fi
  green "TLS 证书路径已自动填充：$target/cert.pem"
}

# Existing nodes still using the shared certificate keep their previous paths.
tls_cert_path() {
  if [[ -r $TLS_DIR/$SERVER_NAME/cert.pem ]]; then printf '%s' "$TLS_DIR/$SERVER_NAME/cert.pem"; else printf '%s' "$TLS_CERT_FILE"; fi
}
tls_key_path() {
  if [[ -r $TLS_DIR/$SERVER_NAME/key.pem ]]; then printf '%s' "$TLS_DIR/$SERVER_NAME/key.pem"; else printf '%s' "$TLS_KEY_FILE"; fi
}

ensure_port_available() {
  local listeners transport
  transport=$(profile_transport)
  if [[ $transport == udp ]]; then listeners=$(ss -H -lnup "sport = :${PORT}" 2>/dev/null) || die '无法检查 UDP 监听。'
  else listeners=$(ss -H -lntp "sport = :${PORT}" 2>/dev/null) || die '无法检查 TCP 监听。'; fi
  [[ -z $listeners ]] && return 0
  if grep -q 'xray-core' <<<"$listeners"; then
    return 0
  fi
  red "错误：${transport^^} 端口 ${PORT} 已被其他服务占用："
  printf '%s\n' "$listeners"
  die "请选择其他端口，不会停止现有服务。"
}
render_config() (
  umask 077
  local destination=$1 rendered
  rendered=$(mktemp) || return 1
  trap 'rm -f -- "$rendered"' EXIT
  jq -n \
    --argjson port "$PORT" \
    --arg id "$UUID" \
    --arg extraIds "${EXTRA_UUIDS:-}" \
    --arg server "$SERVER_NAME" \
    --arg private "${PRIVATE_KEY:-}" \
    --arg short "${SHORT_ID:-}" \
    --arg profile "${PROFILE:-vless-reality-raw}" \
    --arg path "${PATH_VALUE:-}" \
    --arg listen "$(if [[ ${PROFILE:-} == vless-tls-xhttp ]]; then printf '127.0.0.1'; elif [[ ${ADDRESS:-} == *:* ]]; then printf '::'; else printf '0.0.0.0'; fi)" \
    --arg cert "${TLS_CERT_PATH_OVERRIDE:-$(tls_cert_path)}" \
    --arg key "${TLS_KEY_PATH_OVERRIDE:-$(tls_key_path)}" '{
      log: {loglevel: "warning"},
      inbounds: [{
        tag: "vless-reality",
        listen: $listen,
        port: $port,
        protocol: (if $profile == "hysteria-tls-quic" then "hysteria" elif ($profile | startswith("trojan-")) then "trojan" elif ($profile | startswith("vmess-")) then "vmess" else "vless" end),
        settings: (if $profile == "hysteria-tls-quic" then {version:2,clients: (([$id] + ($extraIds | split(",") | map(select(length > 0)))) | map({auth: .}))}
        elif ($profile | startswith("trojan-")) then {clients: (([$id] + ($extraIds | split(",") | map(select(length > 0)))) | map({password: .}))}
        elif ($profile | startswith("vmess-")) then {clients: (([$id] + ($extraIds | split(",") | map(select(length > 0)))) | map({id: ., alterId: 0}))}
        else {
          clients: (([$id] + ($extraIds | split(",") | map(select(length > 0)))) | map({id: .} + (if ($profile == "vless-reality-raw" or $profile == "vless-tls-raw") then {flow: "xtls-rprx-vision"} else {} end))),
          decryption: "none"
        } end),
        streamSettings: ({
          network: (if $profile == "hysteria-tls-quic" then "hysteria" elif ($profile == "vless-reality-xhttp" or $profile == "vless-tls-xhttp") then "xhttp" elif ($profile | endswith("-grpc")) then "grpc" elif ($profile | endswith("-ws")) then "ws" else "raw" end),
          security: (if $profile == "vless-tls-xhttp" then "none" elif ($profile | contains("-tls-")) then "tls" elif ($profile | contains("-reality-")) then "reality" else "none" end)
        } + (if ($profile | contains("-reality-")) then {realitySettings: {
            show: false,
            target: ($server + ":443"),
            xver: 0,
            serverNames: [$server],
            privateKey: $private,
            shortIds: [$short]
          }} elif ($profile | contains("-tls-") and $profile != "vless-tls-xhttp") then {tlsSettings: ({certificates: [{certificateFile: $cert, keyFile: $key}]} + (if $profile == "hysteria-tls-quic" then {alpn:["h3"]} else {} end))} else {} end)
          + (if $profile == "hysteria-tls-quic" then {hysteriaSettings:{version:2}}
            elif ($profile == "vless-reality-xhttp" or $profile == "vless-tls-xhttp") then {xhttpSettings: {path: $path, mode: "auto"}}
            elif ($profile | endswith("-grpc")) then {grpcSettings: {serviceName: $path, multiMode: false}}
            elif ($profile | endswith("-ws")) then {wsSettings: {path: $path}}
            else {} end)),
        sniffing: {enabled: true, destOverride: ["http", "tls", "quic"]}
      }],
      outbounds: [
        {protocol: "freedom", tag: "direct"},
        {protocol: "blackhole", tag: "block"}
      ]
    }' > "$rendered" || return 1
  protect_outbound_targets "$rendered" || return 1
  cat "$rendered" > "$destination"
)

apply_warp_config() {
  local config_file=$1 mode domains strategy
  protect_outbound_targets "$config_file" || return 1
  [[ -r $WARP_STATE_FILE ]] || return 0
  WARP_MODE=off
  WARP_DOMAINS=''
  WARP_IP_STRATEGY=UseIPv4v6
  # This file is generated by this script with mode 0600.
  # shellcheck disable=SC1090
  load_state_file "$WARP_STATE_FILE"
  mode=${WARP_MODE:-off}
  domains=${WARP_DOMAINS:-}
  strategy=${WARP_IP_STRATEGY:-UseIPv4v6}
  [[ $mode == off ]] && return 0
  [[ $mode == selective || $mode == all ]] || { red "WARP 策略模式无效。" >&2; return 1; }
  [[ $strategy == UseIPv4v6 || $strategy == UseIPv4 || $strategy == UseIPv6 ]] || { red "WARP IP 策略无效。" >&2; return 1; }
  if [[ $mode == selective && -z $domains ]]; then
    red "WARP 指定域名列表为空。" >&2
    return 1
  fi
  inject_warp_config "$config_file" "$mode" "$domains" "$strategy"
}

inject_warp_config() {
  local config_file=$1 mode=$2 domains=${3:-} strategy=${4:-UseIPv4v6} temporary
  protect_outbound_targets "$config_file" || return 1
  temporary=$(mktemp)
  jq --arg mode "$mode" --arg domains "$domains" --arg strategy "$strategy" --argjson port "$WARP_PROXY_PORT" '
    .outbounds += [{protocol:"socks",tag:"warp",targetStrategy:$strategy,settings:{servers:[{address:"127.0.0.1",port:$port}]}}]
    | .routing = {
        domainStrategy:"IPOnDemand",
        rules: (.routing.rules
          + if $mode == "all" then
              [{type:"field",network:"tcp",outboundTag:"warp"}]
            else
              [{type:"field",network:"tcp",domain:($domains | split(",")),outboundTag:"warp"}]
            end)
      }
  ' "$config_file" > "$temporary" || { rm -f -- "$temporary"; return 1; }
  mv -f -- "$temporary" "$config_file"
}

write_config() {
  local node_file=${1:-$NODES_DIR/primary.env}
  ensure_service_user
  install -d -m 755 "$CONFIG_DIR"
  create_backup
  prepare_tls_material
  validate_pending_config node
  [[ -f $STATE_FILE ]] || save_current_node "$STATE_FILE"
  install -d -m 700 "$NODES_DIR"
  save_current_node "$node_file"
  rebuild_or_restore
}

# Keep credentials private from creation, including on failure or interruption.
# Xray determines the configuration format from the final file extension.
validate_pending_config() (
  umask 077
  local mode=$1 temporary_dir temporary
  temporary_dir=$(mktemp -d "$CONFIG_DIR/.config.XXXXXX") || return 1
  trap 'rm -rf -- "$temporary_dir"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  temporary="$temporary_dir/config.json"
  if [[ $mode == empty ]]; then
    jq -n '{log:{loglevel:"warning"},inbounds:[],outbounds:[{protocol:"freedom",tag:"direct"},{protocol:"blackhole",tag:"block"}]}' > "$temporary" || return 1
  else
    render_config "$temporary" || return 1
  fi
  apply_warp_config "$temporary" || return 1
  XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_BIN" run -test -config "$temporary" || return 1
  if [[ $mode == empty ]]; then
    publish_config "$temporary" || return 1
  fi
)

write_empty_config() {
  ensure_service_user
  install -d -m 755 "$CONFIG_DIR"
  install -d -m 700 "$NODES_DIR"
  validate_pending_config empty
  write_data_schema_marker "$STATE_FILE"
}

valid_state_key() {
  case "$1" in
    DATA_SCHEMA|PORT|UUID|EXTRA_UUIDS|ADDRESS|PROFILE|PATH_VALUE|CERT_SOURCE|KEY_SOURCE|SERVER_NAME|PRIVATE_KEY|PUBLIC_KEY|SHORT_ID|REMARK|XHTTP_MODE|WARP_MODE|WARP_DOMAINS|WARP_IP_STRATEGY|WARP_BACKEND) return 0 ;;
    *) return 1 ;;
  esac
}

# Decode the literal formats emitted by Bash printf %q, never eval/source them.
decode_legacy_value() {
  local encoded=$1 char index
  DECODED_STATE_VALUE=''
  if [[ $encoded == \$\'*\' ]]; then
    DECODED_STATE_VALUE=$(printf '%b.' "${encoded:2:${#encoded}-3}")
    DECODED_STATE_VALUE=${DECODED_STATE_VALUE%.}
  elif [[ $encoded == \"*\" || $encoded == \'*\' ]]; then
    DECODED_STATE_VALUE=${encoded:1:${#encoded}-2}
  else
    for ((index=0; index<${#encoded}; index++)); do
      char=${encoded:index:1}
      if [[ $char == $'\\' ]]; then
        ((index+=1)); (( index < ${#encoded} )) || return 1
        char=${encoded:index:1}
      elif [[ $char == [[:space:]] || $char == [\$\`\'\"\;\&\|\<\>\(\)\{\}] ]]; then
        return 1
      fi
      DECODED_STATE_VALUE+=$char
    done
  fi
}

state_to_json() {
  local file=$1 first line key encoded
  [[ -f $file ]] || return 1
  first=$(head -c 1 "$file") || return 1
  if [[ $first == '{' ]]; then
    jq -e 'type == "object"' "$file" >/dev/null || return 1
    cat "$file"
  else
    (
      while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ -n $line && $line != \#* ]] || continue
        [[ $line == *=* ]] || return 1
        key=${line%%=*}; encoded=${line#*=}
        valid_state_key "$key" || return 1
        decode_legacy_value "$encoded" || return 1
        jq -cn --arg key "$key" --arg value "$DECODED_STATE_VALUE" '{key:$key,value:$value}'
      done < "$file"
    ) | jq -s 'from_entries |
      if has("DATA_SCHEMA") then .DATA_SCHEMA |= tonumber else . end |
      if has("PORT") then .PORT |= tonumber else . end'
  fi
}

load_state_file() {
  local file=$1 temporary key value invalid=0
  temporary=$(mktemp) || return 1
  if ! state_to_json "$file" | jq -ej '
      if (type == "object" and all(.[]; type == "string" or type == "number") and all(.[] | tostring | explode; index(0) == null))
      then to_entries[] | .key, "\u0000", (.value|tostring), "\u0000" else error("invalid state") end' > "$temporary"; then
    rm -f -- "$temporary"; red '状态文件格式无效，未执行其内容。' >&2; return 1
  fi
  # Validate every key before assigning any field.
  while IFS= read -r -d '' key && IFS= read -r -d '' value; do
    valid_state_key "$key" || invalid=1
  done < "$temporary"
  if (( invalid )); then rm -f -- "$temporary"; return 1; fi
  EXTRA_UUIDS=''; XHTTP_MODE=auto
  while IFS= read -r -d '' key && IFS= read -r -d '' value; do
    printf -v "$key" '%s' "$value"
  done < "$temporary"
  rm -f -- "$temporary"
}

state_schema() { state_to_json "$1" | jq -r '.DATA_SCHEMA // 1'; }

save_current_node() (
  umask 077
  local destination=$1 temporary json_file
  temporary=$(mktemp "${destination}.XXXXXX") || return 1
  json_file=$(mktemp "${destination}.XXXXXX") || return 1
  trap 'rm -f -- "$temporary" "$json_file"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  cat > "$temporary" <<EOF || return 1
DATA_SCHEMA=${DATA_SCHEMA_VERSION}
PORT=${PORT}
UUID=${UUID}
EXTRA_UUIDS=$(printf %q "${EXTRA_UUIDS:-}")
ADDRESS=$(printf %q "${ADDRESS:-}")
PROFILE=$(printf %q "${PROFILE:-vless-reality-raw}")
PATH_VALUE=$(printf %q "${PATH_VALUE:-}")
CERT_SOURCE=$(printf %q "${CERT_SOURCE:-}")
KEY_SOURCE=$(printf %q "${KEY_SOURCE:-}")
SERVER_NAME=$(printf %q "$SERVER_NAME")
PRIVATE_KEY=$(printf %q "${PRIVATE_KEY:-}")
PUBLIC_KEY=$(printf %q "${PUBLIC_KEY:-}")
SHORT_ID=$(printf %q "${SHORT_ID:-}")
REMARK=$(printf %q "$REMARK")
XHTTP_MODE=$(printf %q "${XHTTP_MODE:-auto}")
EOF
  state_to_json "$temporary" > "$json_file" || return 1
  mv -f -- "$json_file" "$destination"
)

rebuild_config_from_nodes() (
  install -d -m 700 "$NODES_DIR" || return 1
  local work_dir combined node_file node_id rendered
  work_dir=$(mktemp -d) || return 1
  trap 'rm -rf -- "$work_dir"' EXIT
  combined="$work_dir/inbounds.json"
  printf '[]\n' > "$combined" || return 1
  for node_file in "$NODES_DIR"/*.env; do
    [[ -e $node_file ]] || continue
    # Node files are generated by this script with mode 0600.
    # shellcheck disable=SC1090
    EXTRA_UUIDS=''
    # shellcheck disable=SC1090
    load_state_file "$node_file" || return 1
    node_id=$(basename "$node_file" .env)
    # Hysteria2 is served by the official Hysteria process. Keeping it out of
    # Xray avoids the known Xray inbound interoperability failures.
    [[ $PROFILE == hysteria-tls-quic ]] && continue
    rendered="$work_dir/${node_id}.json"
    render_config "$rendered" || return 1
    jq --arg tag "$node_id" '.inbounds[0].tag=$tag | .inbounds[0]' "$rendered" > "$work_dir/inbound.json" || return 1
    jq --slurpfile inbound "$work_dir/inbound.json" '. + $inbound' "$combined" > "$work_dir/next.json" || return 1
    mv "$work_dir/next.json" "$combined" || return 1
  done
  jq -n --slurpfile inbounds "$combined" '{log:{loglevel:"warning"},inbounds:$inbounds[0],outbounds:[{protocol:"freedom",tag:"direct"},{protocol:"blackhole",tag:"block"}]}' > "$work_dir/config.json" || return 1
  apply_warp_config "$work_dir/config.json" || return 1
  XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_BIN" run -test -config "$work_dir/config.json" >/dev/null || { rm -rf "$work_dir"; red "多入站配置未通过 Xray 校验。"; return 1; }
  publish_config "$work_dir/config.json"
)

rebuild_or_restore() {
  rebuild_config_from_nodes && return 0
  if [[ -n ${LAST_BACKUP:-} ]]; then
    yellow "合并配置失败，正在恢复入站注册表和配置…"
    restore_archive "$LAST_BACKUP"
  fi
  die "多入站配置生成失败，已回滚。"
}

write_service() {
  cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=Xray Service managed by v2ray-manager
Documentation=https://xtls.github.io/
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=xray
Environment=XRAY_LOCATION_ASSET=/usr/local/share/xray
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
ExecStart=/usr/local/bin/xray-core run -config /etc/xray/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

install_manager_command() {
  [[ -r "$0" ]] || die "无法读取当前脚本，未能安装 v2ray 管理命令。"
  if [[ -L "$MANAGER_BIN" && ! -e "$MANAGER_BIN" ]]; then
    yellow "检测到失效的 v2ray 命令链接，正在修复。"
    rm -f -- "$MANAGER_BIN"
  fi
  if [[ "$(readlink -f "$0")" != "$(readlink -f "$MANAGER_BIN" 2>/dev/null || true)" ]]; then
    if [[ -e "$MANAGER_BIN" ]] && ! grep -q 'APP_NAME="v2ray-manager"' "$MANAGER_BIN" 2>/dev/null; then
      install -d -m 700 "$BACKUP_DIR"
      if [[ ! -e "$LEGACY_MANAGER_BACKUP" ]]; then
        cp -a "$MANAGER_BIN" "$LEGACY_MANAGER_BACKUP"
        yellow "已保存现有 v2ray 管理命令：$LEGACY_MANAGER_BACKUP"
      fi
    fi
    install -m 755 "$0" "$MANAGER_BIN"
  fi
}

stop_legacy_service() {
  if [[ -f /etc/v2ray/manager.env && -f /etc/systemd/system/v2ray.service ]] && \
     grep -q '/usr/local/bin/v2ray-core' /etc/systemd/system/v2ray.service; then
    yellow "检测到本项目 1.x 服务，正在停用；旧文件会保留以便人工回退。"
    systemctl disable --now v2ray 2>/dev/null || true
  fi
}
hysteria_asset() {
  case "$(uname -m)" in
    x86_64|amd64) printf '%s\t%s\n' hysteria-linux-amd64 907ba8c9693edb104b20582681fb7dc15639d5b64a9cbb616a7b539190a86691 ;;
    aarch64|arm64) printf '%s\t%s\n' hysteria-linux-arm64 a68a61a84452ca250ce0368202521965ca9cc9d801a404f1dc9008ac6cf677a7 ;;
    *) red "Hysteria 官方服务端暂不支持此架构：$(uname -m)" >&2; return 1 ;;
  esac
}

install_hysteria_core() (
  set -Eeuo pipefail
  local asset expected actual temporary
  IFS=$'\t' read -r asset expected < <(hysteria_asset) || return 1
  if [[ -x $HYSTERIA_BIN ]]; then
    actual=$(sha256sum "$HYSTERIA_BIN") || return 1
    [[ ${actual%% *} == "$expected" ]] && return 0
  fi
  temporary=$(mktemp) || return 1
  trap 'rm -f -- "$temporary"' EXIT
  download_file "https://github.com/HyNetworks/hysteria/releases/download/app%2F${HYSTERIA_VERSION}/${asset}" "$temporary" || return 1
  actual=$(sha256sum "$temporary") || return 1
  [[ ${actual%% *} == "$expected" ]] || { red 'Hysteria 官方二进制 SHA-256 校验失败。' >&2; return 1; }
  chmod 755 "$temporary"
  "$temporary" version >/dev/null || return 1
  atomic_install "$temporary" "$HYSTERIA_BIN" 755
)

write_hysteria_service_template() {
  cat > "$HYSTERIA_SERVICE_TEMPLATE" <<EOF
[Unit]
Description=Hysteria2 inbound %i managed by v2ray-manager
Documentation=https://v2.hysteria.network/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=$HYSTERIA_BIN server -c $HYSTERIA_CONFIG_DIR/%i.yaml
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=$TLS_DIR

[Install]
WantedBy=multi-user.target
EOF
}

render_hysteria_node() {
  local node_id=$1 config=$HYSTERIA_CONFIG_DIR/$node_id.yaml auth_file=$HYSTERIA_CONFIG_DIR/$node_id.auth auth_cmd=$HYSTERIA_CONFIG_DIR/$node_id-auth
  local credential
  valid_node_id "$node_id" || return 1
  valid_port "$PORT" && valid_server_name "$SERVER_NAME" || return 1
  tls_pair_valid "$(tls_cert_path)" "$(tls_key_path)" || return 1
  install -d -m 700 "$HYSTERIA_CONFIG_DIR"
  {
    printf '%s\n' "$UUID"
    if [[ -n ${EXTRA_UUIDS:-} ]]; then tr ',' '\n' <<<"$EXTRA_UUIDS"; fi
  } > "$auth_file"
  chmod 600 "$auth_file"
  while IFS= read -r credential; do valid_uuid "$credential" || return 1; done < "$auth_file"
  cat > "$auth_cmd" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
grep -Fqx -- "\${2:-}" "$auth_file"
printf '%s\n' "\${2:-}"
EOF
  chmod 700 "$auth_cmd"
  cat > "$config" <<EOF
listen: ":$PORT"
tls:
  cert: "$(tls_cert_path)"
  key: "$(tls_key_path)"
  sniGuard: strict
auth:
  type: command
  command: "$auth_cmd"
masquerade:
  type: string
  string:
    content: "404 Not Found"
    headers:
      content-type: "text/plain; charset=utf-8"
    statusCode: 404
EOF
  chmod 600 "$config"
}

sync_hysteria_services() (
  set -Eeuo pipefail
  local node_file node_id config found=0
  declare -A enabled=()
  for node_file in "$NODES_DIR"/*.env; do
    [[ -f $node_file ]] || continue
    EXTRA_UUIDS=''; load_state_file "$node_file" || return 1
    [[ $PROFILE == hysteria-tls-quic ]] || continue
    ((found+=1)); node_id=$(basename "$node_file" .env); enabled["$node_id"]=1
  done
  if (( found )); then
    install_hysteria_core || return 1
    install -d -m 700 "$HYSTERIA_CONFIG_DIR"
    write_hysteria_service_template || return 1
    for node_file in "$NODES_DIR"/*.env; do
      [[ -f $node_file ]] || continue
      EXTRA_UUIDS=''; load_state_file "$node_file" || return 1
      [[ $PROFILE == hysteria-tls-quic ]] || continue
      node_id=$(basename "$node_file" .env)
      render_hysteria_node "$node_id" || return 1
    done
    systemctl daemon-reload || return 1
  fi
  [[ -d $HYSTERIA_CONFIG_DIR ]] || return 0
  for config in "$HYSTERIA_CONFIG_DIR"/*.yaml; do
    [[ -f $config ]] || continue
    node_id=$(basename "$config" .yaml)
    if [[ -n ${enabled[$node_id]:-} ]]; then
      systemctl enable "hysteria-v2ray-manager@${node_id}.service" >/dev/null
      systemctl restart "hysteria-v2ray-manager@${node_id}.service" || return 1
      systemctl is-active --quiet "hysteria-v2ray-manager@${node_id}.service" || return 1
    else
      systemctl disable --now "hysteria-v2ray-manager@${node_id}.service" >/dev/null 2>&1 || true
      rm -f -- "$config" "$HYSTERIA_CONFIG_DIR/$node_id.auth" "$HYSTERIA_CONFIG_DIR/$node_id-auth"
    fi
  done
  systemctl daemon-reload || return 1
)

hysteria_node_matches_runtime() {
  local node_id node_file
  for node_file in "$NODES_DIR"/*.env; do
    [[ -f $node_file ]] || continue
    node_id=$(basename "$node_file" .env)
    [[ -r $HYSTERIA_CONFIG_DIR/$node_id.yaml ]] || continue
    grep -Fqx "listen: \":$PORT\"" "$HYSTERIA_CONFIG_DIR/$node_id.yaml" || continue
    grep -Fqx "$UUID" "$HYSTERIA_CONFIG_DIR/$node_id.auth" || continue
    systemctl is-active --quiet "hysteria-v2ray-manager@${node_id}.service" && return 0
  done
  return 1
}
install_xray() {
  require_supported_os
  # Install the manager first so users retain a recovery path if download or validation fails.
  install_manager_command
  if [[ -x "$XRAY_BIN" ]]; then
    yellow "检测到已有 Xray，将保留当前内核；内核升级请使用 v2ray update。"
    install_dependencies
  else
    step "安装依赖并准备 Xray Core"
    download_core
  fi
  if [[ ${V2M_NONINTERACTIVE:-0} == 1 ]]; then
    ask_server_values
    ensure_port_available
    step "生成并校验配置文件"
    write_config
  elif compgen -G "$NODES_DIR/*.env" >/dev/null; then
    green "检测到已有入站，安装过程将保留现有协议和链接。"
    rebuild_config_from_nodes || die "现有入站配置校验失败，未修改服务。"
  else
    step "初始化 Xray（暂不添加协议）"
    write_empty_config
  fi
  step "安装 systemd 服务"
  write_service
  stop_legacy_service
  systemctl enable "$SERVICE_NAME"
  restart_or_rollback
  green "Xray Core 和管理脚本安装完成。"
  open_enabled_inbound_ports
  if compgen -G "$NODES_DIR/*.env" >/dev/null; then
    green "已有协议和链接保持不变；需要时运行 v2ray links 查看。"
  else
    green '尚未添加协议。请运行 v2ray add，或进入“入站管理 → 添加新入站”手动选择。'
  fi
}

load_state() {
  [[ -r "$STATE_FILE" ]] || die "找不到管理状态，请先安装或重新运行安装以迁移到 2.x。"
  # This file is created by this script with mode 0600.
  # shellcheck disable=SC1090
  EXTRA_UUIDS=''
  DATA_SCHEMA=1
  # shellcheck disable=SC1090
  load_state_file "$STATE_FILE"
  PROFILE=${PROFILE:-vless-reality-raw}
  PATH_VALUE=${PATH_VALUE:-}
  EXTRA_UUIDS=${EXTRA_UUIDS:-}
}

create_backup() {
  LAST_BACKUP=""
  [[ -r "$CONFIG_FILE" && -r "$STATE_FILE" ]] || return 0
  install -d -m 700 "$BACKUP_DIR"
  local timestamp archive
  timestamp=$(date -u +%Y%m%dT%H%M%SZ)
  archive=$(mktemp "$BACKUP_DIR/config-${timestamp}-XXXXXX.tar.gz")
  local -a backup_items=(config.json manager.env)
  [[ -f $WARP_STATE_FILE ]] && backup_items+=(warp.env)
  [[ -f $WARP_BACKEND_STATE_FILE ]] && backup_items+=(warp-backend.env)
  [[ -d $TLS_DIR ]] && backup_items+=(tls)
  [[ -d $NODES_DIR ]] && backup_items+=(nodes)
  if ! tar -czf "$archive" -C "$CONFIG_DIR" "${backup_items[@]}"; then
    rm -f -- "$archive"
    die "配置备份失败，未修改现有配置。"
  fi
  chmod 600 "$archive"
  LAST_BACKUP=$archive

  local -a archives
  mapfile -t archives < <(list_backups)
  local index
  for ((index=10; index<${#archives[@]}; index++)); do
    rm -f -- "${archives[$index]}"
  done
}

list_backups() {
  # Random suffixes avoid collisions; modification time determines recency.
  find "$BACKUP_DIR" -maxdepth 1 -type f -name 'config-*.tar.gz' -printf '%T@ %p\n' |
    sort -nr | cut -d ' ' -f 2-
}

restore_archive() (
  set -Eeuo pipefail
  local archive=$1 temp_dir
  [[ -r "$archive" ]] || die "备份文件不可读：$archive"
  temp_dir=$(mktemp -d) || return 1
  trap 'rm -rf -- "$temp_dir"' EXIT
  tar -xzf "$archive" -C "$temp_dir" || return 1
  [[ -r "$temp_dir/config.json" && -r "$temp_dir/manager.env" ]] || die "备份内容不完整。"
  # Validate against the archived certificates, not the possibly broken live ones.
  jq --arg live "$TLS_DIR/" --arg staged "$temp_dir/tls/" \
    'walk(if type == "string" then if startswith($live) then $staged + .[($live|length):] else . end else . end)' \
    "$temp_dir/config.json" > "$temp_dir/validation.json" || return 1
  XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_BIN" run -test -config "$temp_dir/validation.json" >/dev/null || die "备份配置未通过 Xray 校验。"
  if [[ -d $temp_dir/tls ]]; then
    # Retain both legacy shared certificates and all per-domain directories.
    chown -R root:xray "$temp_dir/tls" || return 1
    find "$temp_dir/tls" -type d -exec chmod 750 {} + || return 1
    find "$temp_dir/tls" -type f -exec chmod 640 {} + || return 1
    find "$temp_dir/tls" -type f -name source -exec chmod 600 {} + || return 1
    install -d -m 750 -o root -g xray "$TLS_DIR" || return 1
    cp -a "$temp_dir/tls/." "$TLS_DIR/" || return 1
  fi
  publish_config "$temp_dir/config.json" || return 1
  install -m 600 -o root -g root "$temp_dir/manager.env" "$STATE_FILE" || return 1
  if [[ -f $temp_dir/warp.env ]]; then
    install -m 600 -o root -g root "$temp_dir/warp.env" "$WARP_STATE_FILE" || return 1
  else
    rm -f -- "$WARP_STATE_FILE" || return 1
  fi
  if [[ -f $temp_dir/warp-backend.env ]]; then
    install -m 600 -o root -g root "$temp_dir/warp-backend.env" "$WARP_BACKEND_STATE_FILE" || return 1
  else
    rm -f -- "$WARP_BACKEND_STATE_FILE" || return 1
  fi
  if [[ -d $temp_dir/nodes ]]; then
    rm -rf "$NODES_DIR" || return 1
    install -d -m 700 "$NODES_DIR" || return 1
    cp -a "$temp_dir/nodes/." "$NODES_DIR/" || return 1
  fi
)

restore_latest() {
  [[ -d "$BACKUP_DIR" ]] || die "没有可恢复的配置备份。"
  local archive
  archive=$(list_backups | sed -n '1p')
  [[ -n "$archive" ]] || die "没有可恢复的配置备份。"
  restore_archive "$archive"
  # Old archives must not reactivate the pre-hardening outbound policy.
  migrate_project_state
  restart_checked || die "备份已恢复，但服务未通过健康检查，请运行 v2ray log。"
  green "已恢复备份：$(basename "$archive")"
  show_connection
}

manual_backup() {
  create_backup
  [[ -n ${LAST_BACKUP:-} ]] || die "当前没有可备份的有效配置。"
  green "配置已备份：$LAST_BACKUP"
}

# Observe one stable process for five seconds; a successful systemctl job alone
# cannot detect a crash immediately after Type=simple has started the process.
service_healthy() {
  local initial_pid initial_restarts current_pid current_restarts attempt
  initial_pid=$(systemctl show --property=MainPID --value "$SERVICE_NAME") || return 1
  initial_restarts=$(systemctl show --property=NRestarts --value "$SERVICE_NAME") || return 1
  [[ $initial_pid =~ ^[1-9][0-9]*$ && $initial_restarts =~ ^[0-9]+$ ]] || return 1
  for ((attempt=0; attempt<5; attempt++)); do
    sleep 1
    systemctl is-active --quiet "$SERVICE_NAME" || return 1
    current_pid=$(systemctl show --property=MainPID --value "$SERVICE_NAME") || return 1
    current_restarts=$(systemctl show --property=NRestarts --value "$SERVICE_NAME") || return 1
    [[ $current_pid == "$initial_pid" && $current_restarts == "$initial_restarts" ]] || return 1
  done
}

restart_checked() {
  systemctl restart "$SERVICE_NAME" && service_healthy && sync_hysteria_services
}

restart_or_rollback() {
  if restart_checked; then
    return 0
  fi
  red "新配置启动失败。"
  if [[ -n ${LAST_BACKUP:-} ]]; then
    yellow "正在恢复上一份配置…"
    restore_archive "$LAST_BACKUP"
    restart_checked || die "回滚后服务仍无法启动，请运行 v2ray log。"
    die "新配置已回滚，服务已恢复。"
  fi
  die "服务启动失败，请运行 v2ray log 查看原因。"
}

server_address() {
  if valid_server_name "${ADDRESS:-}"; then
    printf '%s' "$ADDRESS"
    return
  fi
  if profile_uses_tls && valid_server_name "${SERVER_NAME:-}"; then
    printf '%s' "$SERVER_NAME"
    return
  fi
  printf '%s' 'YOUR_SERVER_DOMAIN'
}

# The node registry is authoritative after add/modify/disable operations.
load_connection_state() {
  local node_file
  if [[ -d $NODES_DIR ]]; then
    if [[ -f $NODES_DIR/primary.env ]]; then
      node_file="$NODES_DIR/primary.env"
    else
      for node_file in "$NODES_DIR"/*.env; do
        [[ -f $node_file ]] && break
      done
    fi
    [[ -f $node_file ]] || { red "没有启用的入站，无法导出链接。" >&2; return 1; }
    # shellcheck disable=SC1090
    EXTRA_UUIDS=''
    # shellcheck disable=SC1090
    load_state_file "$node_file"
  else
    load_state
  fi
}

show_connection() (
  local node_id=${1:-} address_override=${2:-} selected_domain
  if [[ -n $node_id ]]; then
    if ! valid_node_id "$node_id" || [[ ! -f $NODES_DIR/$node_id.env ]]; then
      red "找不到启用的入站：$node_id" >&2
      return 1
    fi
    # shellcheck disable=SC1090
    load_state_file "$NODES_DIR/$node_id.env"
  else
    load_connection_state || return 1
  fi
  if [[ -n $address_override ]]; then
    [[ $PROFILE == *-tls-xhttp || $PROFILE == *-tls-ws ]] || {
      red "自定义 CDN/优选 IP 仅适用于 TLS XHTTP/WebSocket 入站。" >&2
      return 1
    }
    if [[ $address_override == cfip || $address_override == preferred ]]; then
      address_override=$(call_cloudflare_ip_branch get) || return 1
      selected_domain=$(call_cloudflare_ip_branch domain) || return 1
      [[ ${selected_domain,,} == "${SERVER_NAME,,}" ]] || {
        red "优选 IP 保存的 TLS 域名是 $selected_domain，与入站域名 $SERVER_NAME 不一致。请重新测试或设置。" >&2
        return 1
      }
    fi
    valid_server_name "$address_override" || valid_public_ipv4 "$address_override" || {
      red "CDN 入口必须是有效域名或公网 IPv4。" >&2; return 1;
    }
  fi
  show_connection_loaded "$CONFIG_FILE" "$address_override"
)

# Build client transport from the same profile as the server; never export
# server certificates, private keys or REALITY target settings.
render_client_config() {
  local client_port
  valid_xhttp_mode "${XHTTP_MODE:-auto}" || return 1
  client_port=$(client_entry_port)
  if [[ ${PROFILE:-} == hysteria-tls-quic ]]; then
    jq -n --arg address "$(server_address)" --argjson port "$client_port" \
      --arg password "$UUID" --arg server "$SERVER_NAME" '{
      log:{level:"warn"},
      inbounds:[
        {type:"socks",tag:"socks-in",listen:"127.0.0.1",listen_port:10800},
        {type:"http",tag:"http-in",listen:"127.0.0.1",listen_port:10801}
      ],
      outbounds:[{type:"hysteria2",tag:"proxy",server:$address,server_port:$port,
        password:$password,tls:{enabled:true,server_name:$server}}]
    }'
    return
  fi
  render_config /dev/stdout | jq --arg address "$(server_address)" --argjson clientPort "$client_port" \
    --arg server "$SERVER_NAME" --arg public "${PUBLIC_KEY:-}" --arg short "${SHORT_ID:-}" \
    --arg profile "${PROFILE:-}" --arg xhttpMode "${XHTTP_MODE:-auto}" '
    .inbounds[0] as $in |
    ($in.settings.clients[0] // $in.settings.users[0]) as $user |
    ($in.streamSettings | del(.tlsSettings, .realitySettings) |
      if $profile == "vless-tls-xhttp" then
        .security = "tls"
        | .tlsSettings = {serverName: $server, fingerprint: "chrome", alpn: ["h2"]}
      elif .security == "reality" then .realitySettings = {
        serverName: $server, fingerprint: "chrome", password: $public, shortId: $short
      } elif .security == "tls" then .tlsSettings = {
        serverName: $server, fingerprint: "chrome"
      } else . end |
      if .network == "hysteria" then .hysteriaSettings.auth = $user.auth | del(.tlsSettings.fingerprint) | .tlsSettings.alpn = ["h3"]
      elif .network == "xhttp" then .xhttpSettings.mode = $xhttpMode | if .security == "tls" then .xhttpSettings.host = $server else . end
      elif .network == "ws" and .security == "tls" then .wsSettings.headers.Host = $server
      else . end) as $stream |
    {
      log: {loglevel: "warning"},
      inbounds: [
        {tag: "socks", listen: "127.0.0.1", port: 10800, protocol: "socks", settings: {auth: "noauth", udp: true}},
        {tag: "http", listen: "127.0.0.1", port: 10801, protocol: "http", settings: {}}
      ],
      outbounds: [{tag: "proxy", protocol: $in.protocol,
        settings: (if $in.protocol == "hysteria" then {version:2,address:($address | ltrimstr("[") | rtrimstr("]")),port:$clientPort}
        elif $in.protocol == "trojan" then {
          servers: [{address: ($address | ltrimstr("[") | rtrimstr("]")), port: $clientPort, password: $user.password}]
        } else {vnext: [{address: ($address | ltrimstr("[") | rtrimstr("]")), port: $clientPort,
          users: [($user + (if $in.protocol == "vless" then {encryption: "none"} else {security: "auto"} end))]}]} end),
        streamSettings: $stream
      }]
    }'
}

export_client() (
  if [[ -n ${1:-} ]]; then
    if ! valid_node_id "$1" || [[ ! -f $NODES_DIR/$1.env ]]; then
      red "找不到启用的入站：$1" >&2
      return 1
    fi
    # shellcheck disable=SC1090
    load_state_file "$NODES_DIR/$1.env" || return 1
  else
    load_connection_state || return 1
  fi
  show_connection_loaded "$CONFIG_FILE" >/dev/null || return 1
  render_client_config
)

connection_matches_config() {
  local config_file=${1:-$CONFIG_FILE}
  if [[ ${PROFILE:-} == hysteria-tls-quic ]]; then
    hysteria_node_matches_runtime
    return
  fi
  [[ -r $config_file ]] || return 1
  render_config /dev/stdout | jq -e --slurpfile live "$config_file" '
    def signature: {
      port, protocol, clients: (.settings.clients // .settings.users),
      network: (if .streamSettings.network == "tcp" then "raw" else .streamSettings.network end),
      security: (.streamSettings.security // "none"),
      reality: (if .streamSettings.security == "reality" then {
        key: .streamSettings.realitySettings.privateKey,
        names: .streamSettings.realitySettings.serverNames,
        ids: .streamSettings.realitySettings.shortIds
      } else null end),
      ws: .streamSettings.wsSettings.path,
      xhttp: .streamSettings.xhttpSettings.path,
      grpc: .streamSettings.grpcSettings.serviceName
    };
    (.inbounds[0] | signature) as $expected |
    any($live[0].inbounds[]; signature == $expected)
  ' >/dev/null
}

managed_caddy_route_exists() {
  local domain=$1 port=$2 path=$3 site_dir=${CADDY_SITE_DIR_OVERRIDE:-$CADDY_SITE_DIR} site_file
  valid_server_name "$domain" && valid_port "$port" && valid_transport_path "$path" || return 1
  site_file="$site_dir/$domain.caddy"
  [[ -r $site_file ]] || return 1
  awk -v wanted_path="$path" -v wanted_backend="127.0.0.1:$port" '
    $1 ~ /^@/ && $2 == "path" && $3 == wanted_path && $4 == wanted_path "/*" { matcher=$1; next }
    matcher != "" && $1 == "reverse_proxy" && $2 == matcher && index($3, wanted_backend) { found=1 }
    END { exit(found ? 0 : 1) }
  ' "$site_file"
}

profile_uses_managed_caddy_route() {
  profile_supports_caddy_route || return 1
  managed_caddy_route_exists "$SERVER_NAME" "$PORT" "$PATH_VALUE"
}

client_entry_port() {
  local address_override=${1:-}
  if [[ -n $address_override || ${PROFILE:-} == vless-tls-xhttp ]] || profile_uses_managed_caddy_route; then
    printf '443'
  else
    printf '%s' "$PORT"
  fi
}
show_connection_loaded() (
  local address uri_address encoded_name encoded_path link transport security flow query display_name protocol vmess_payload client_port
  local credential link_name index=0
  local -a credentials extra_credentials
  local cdn_address=${2:-}
  address=${cdn_address:-$(server_address)}
  client_port=$(client_entry_port "$cdn_address")
  if ! valid_server_name "$address" && { [[ -z $cdn_address ]] || ! valid_public_ipv4 "$address"; }; then
    red "无法导出链接：入口必须是域名，不能输出公网 IP。请把域名解析到服务器，并在入站配置中填写该域名。" >&2
    return 1
  fi
  address=${address#[}; address=${address%]}
  uri_address=$address
  [[ $address != *:* ]] || uri_address="[$address]"
  valid_uuid "$UUID" || { red "无法导出链接：UUID 格式无效。" >&2; return 1; }
  credentials=("$UUID")
  if [[ -n ${EXTRA_UUIDS:-} ]]; then
    IFS=',' read -r -a extra_credentials <<<"$EXTRA_UUIDS"
    for credential in "${extra_credentials[@]}"; do
      valid_uuid "$credential" || { red "无法导出链接：存在无效的子链接凭据。" >&2; return 1; }
      credentials+=("$credential")
    done
  fi
  (( ${#credentials[@]} <= 10 )) || { red "无法导出链接：单个入站最多支持 10 条链接。" >&2; return 1; }
  if profile_uses_reality && ! reality_pair_valid; then
    red "无法导出链接：REALITY 密钥对或 Short ID 无效，请从对应入站菜单修复或重新生成。" >&2
    return 1
  fi
  if profile_requires_xray_tls && ! tls_pair_valid "${TLS_CERT_PATH_OVERRIDE:-$(tls_cert_path)}" "${TLS_KEY_PATH_OVERRIDE:-$(tls_key_path)}"; then
    red "无法导出链接：TLS 证书无效、过期、域名不符或私钥不匹配。" >&2
    return 1
  fi
  if ! connection_matches_config "${1:-$CONFIG_FILE}"; then
    red "无法导出链接：入站状态与当前 config.json 不一致。请运行 v2ray doctor，并从入站管理菜单检查对应节点。" >&2
    return 1
  fi
  encoded_path=$(jq -rn --arg value "${PATH_VALUE:-}" '$value|@uri')
  display_name=$(profile_name)
  protocol=vless
  link=''
  case "$PROFILE" in
    hysteria-tls-quic)
      protocol=hysteria2; transport=quic; security=tls; flow=none
      query="sni=${SERVER_NAME}"
      ;;
    vless-tls-raw)
      transport=raw; security=tls; flow=xtls-rprx-vision
      query="encryption=none&flow=${flow}&security=tls&sni=${SERVER_NAME}&fp=chrome&type=tcp"
      ;;
    vless-reality-raw)
      transport=raw; security=reality; flow=xtls-rprx-vision
      query="encryption=none&flow=${flow}&security=reality&sni=${SERVER_NAME}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp"
      ;;
    vless-reality-xhttp)
      transport=xhttp; security=reality; flow=none
      query="encryption=none&security=reality&sni=${SERVER_NAME}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=xhttp&path=${encoded_path}&mode=${XHTTP_MODE:-auto}"
      ;;
    vless-reality-grpc)
      transport=grpc; security=reality; flow=none
      query="encryption=none&security=reality&sni=${SERVER_NAME}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=grpc&serviceName=${encoded_path}"
      ;;
    vless-tls-xhttp)
      transport=xhttp; security=tls; flow=none
      query="encryption=none&security=tls&sni=${SERVER_NAME}&fp=chrome&alpn=h2&type=xhttp&host=${SERVER_NAME}&path=${encoded_path}&mode=${XHTTP_MODE:-auto}"
      ;;
    vless-tls-ws)
      transport=websocket; security=tls; flow=none
      query="encryption=none&security=tls&sni=${SERVER_NAME}&fp=chrome&type=ws&host=${SERVER_NAME}&path=${encoded_path}"
      ;;
    vless-tls-grpc)
      transport=grpc; security=tls; flow=none
      query="encryption=none&security=tls&sni=${SERVER_NAME}&fp=chrome&type=grpc&serviceName=${encoded_path}"
      ;;
    trojan-reality-raw)
      protocol=trojan; transport=raw; security=reality; flow=none
      query="security=reality&sni=${SERVER_NAME}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp"
      ;;
    trojan-tls-ws)
      protocol=trojan; transport=websocket; security=tls; flow=none
      query="security=tls&sni=${SERVER_NAME}&fp=chrome&type=ws&host=${SERVER_NAME}&path=${encoded_path}"
      ;;
    vmess-tcp|vmess-tls-ws|vmess-tls-grpc)
      protocol=vmess
      if [[ $PROFILE == vmess-tcp ]]; then transport=tcp; security=none; PATH_VALUE=''; else security=tls; fi
      [[ $PROFILE == vmess-tls-ws ]] && transport=ws
      [[ $PROFILE == vmess-tls-grpc ]] && transport=grpc
      flow=none
      ;;
  esac
  printf '\n使用协议: %s\n' "$display_name"
  printf '%s\n' "-------------- ${display_name} --------------"
  printf '协议 (protocol)       = '; cyan_value "$protocol"; printf '\n'
  printf '地址 (address)        = '; cyan_value "$address"; printf '\n'
  printf '端口 (port)           = '; cyan_value "$client_port"; printf '\n'
  printf '可用子链接数量        = '; cyan_value "${#credentials[@]}"; printf '\n'
  printf '传输协议 (network)  = '; cyan_value "$transport"; printf '\n'
  printf '传输安全 (security) = '; cyan_value "$security"; printf '\n'
  printf '流控 (flow)           = '; cyan_value "$flow"; printf '\n'
  printf 'SNI                   = '; cyan_value "$SERVER_NAME"; printf '\n'
  [[ -n ${PATH_VALUE:-} ]] && { printf '路径 (path/service)   = '; cyan_value "$PATH_VALUE"; printf '\n'; }
  if profile_uses_reality; then
    printf '公钥 (public key)     = '; cyan_value "$PUBLIC_KEY"; printf '\n'
    printf 'Short ID              = '; cyan_value "$SHORT_ID"; printf '\n'
  fi
  printf '%s\n' '------------------- 链接 (URL) -------------------'
  for credential in "${credentials[@]}"; do
    ((index+=1))
    link_name=$REMARK
    (( ${#credentials[@]} == 1 )) || link_name="${REMARK}-${index}"
    encoded_name=$(jq -rn --arg value "$link_name" '$value|@uri')
    if [[ $protocol == vmess ]]; then
      vmess_payload=$(jq -cn --arg ps "$link_name" --arg add "$address" --arg port "$client_port" --arg id "$credential" \
        --arg net "$transport" --arg host "$SERVER_NAME" --arg path "${PATH_VALUE:-}" --arg tls "${security/none/}" \
        '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:$net,type:"none",host:$host,path:$path,tls:$tls,sni:$host}')
      link="vmess://$(printf '%s' "$vmess_payload" | base64 -w 0)"
    elif [[ $protocol == hysteria2 ]]; then
      link="${protocol}://${credential}@${uri_address}:${client_port}/?${query}#${encoded_name}"
    else
      link="${protocol}://${credential}@${uri_address}:${client_port}?${query}#${encoded_name}"
    fi
    (( ${#credentials[@]} == 1 )) || printf '[%s/%s] ' "$index" "${#credentials[@]}"
    cyan_value "$link"; printf '\n'
  done
  printf '%s\n\n' '---------------------- END ----------------------'
  yellow "请确认云服务商安全组已放行客户端入口 $(profile_transport) ${client_port}；可执行 v2ray firewall 放行已启用入站的本机 UFW/firewalld 规则。私钥仅保存在服务器，不要公开。"
)

# manager.env may have stale or no connection data; edits use the node registry.
load_edit_node() {
  local node_id=${1:-} candidate
  local -a candidates=()
  if [[ -z $node_id ]]; then
    for candidate in "$NODES_DIR"/*.env; do
      [[ -f $candidate ]] && candidates+=("$candidate")
    done
    (( ${#candidates[@]} > 0 )) || die "没有启用的入站，请先运行 v2ray add。"
    if (( ${#candidates[@]} == 1 )); then
      node_id=$(basename "${candidates[0]}" .env)
    else
      list_inbounds
      read -r -p '请输入要修改的一个启用入站 ID：' node_id
    fi
  fi
  if ! valid_node_id "$node_id" || [[ ! -f $NODES_DIR/$node_id.env ]]; then
    die "找不到启用的入站：$node_id"
  fi
  EDIT_NODE_FILE="$NODES_DIR/$node_id.env"
  EXTRA_UUIDS=''
  # shellcheck disable=SC1090
  load_state_file "$EDIT_NODE_FILE"
}

change_config() {
  [[ -x "$XRAY_BIN" ]] || die "尚未安装。"
  load_edit_node "${1:-}"
  ask_server_values
  write_config "$EDIT_NODE_FILE"
  restart_or_rollback
  green "配置已更新并重启服务。"
  open_enabled_inbound_ports
  show_connection "$(basename "$EDIT_NODE_FILE" .env)"
}

change_menu() {
  [[ -x "$XRAY_BIN" ]] || die "尚未安装。"
  load_edit_node "${1:-}"
  printf '\n当前选择: %s\n\n' "$(profile_name)"
  ui_box_title '修改入站配置'
  ui_menu_item '1) 更改协议组合'
  ui_menu_item '2) 更改端口'
  ui_menu_item '3) 更改服务器地址'
  ui_menu_item '4) 更改目标域名 / SNI'
  ui_menu_item '5) 更改 UUID'
  ui_menu_item '6) 更改备注'
  ui_menu_item '7) 轮换 REALITY 密钥'
  ui_menu_item '8) 重新输入全部配置'
  ui_box_divider
  ui_menu_item '0) 返回'
  ui_box_bottom
  read -r -p '请选择 [0-8]:' choice
  case "$choice" in
    1) choose_profile ;;
    2)
      read -r -p "新端口 [${PORT}]:" value
      PORT=${value:-$PORT}
      valid_port "$PORT" || die "端口无效。"
      ensure_port_available
      ;;
    3)
      read -r -p "客户端连接域名 [${ADDRESS:-未设置}]:" value
      ADDRESS=${value:-${ADDRESS:-}}
      valid_server_name "$ADDRESS" || die "入口必须是完整域名，分享链接不会写入公网 IP。"
      ;;
    4)
      read -r -p "新 SNI [${SERVER_NAME}]:" value
      SERVER_NAME=${value:-$SERVER_NAME}
      valid_server_name "$SERVER_NAME" || die "域名无效。"
      ;;
    5)
      read -r -p "新 UUID [回车自动生成]:" value
      UUID=${value:-$("$XRAY_BIN" uuid)}
      valid_uuid "$UUID" || die "UUID 格式无效。"
      ;;
    6)
      read -r -p "新备注 [${REMARK}]:" value
      REMARK=${value:-$REMARK}
      ;;
    7)
      profile_uses_reality || die "TLS 组合不使用 REALITY 密钥。"
      rotate_reality_keys "$(basename "$EDIT_NODE_FILE" .env)"; return
      ;;
    8) change_config "$(basename "$EDIT_NODE_FILE" .env)"; return ;;
    0) return ;;
    *) die "无效选择。" ;;
  esac
  write_config "$EDIT_NODE_FILE"
  restart_or_rollback
  green "配置已更新并重启服务。"
  open_enabled_inbound_ports
  show_connection "$(basename "$EDIT_NODE_FILE" .env)"
}

find_free_port() {
  local candidate=${1:-24443} flags=-lnt
  [[ $(profile_transport) != udp ]] || flags=-lnu
  while ss -H "$flags" "sport = :${candidate}" 2>/dev/null | grep -q .; do
    ((candidate+=1)); (( candidate <= 65535 )) || return 1
  done
  printf '%s' "$candidate"
}

list_inbounds() (
  install -d -m 700 "$NODES_DIR"
  local node_file state node_id group wanted_group heading link_count
  printf '\n'
  ui_box_title '入站列表'
  printf '  %-22s %-7s %-30s %-8s %s\n' '入站 ID' '状态' '协议组合' '链接数' '端口'
  printf '  %s\n' '-------------------------------------------------------------------------------'
  for wanted_group in reality http-tls modern-direct compatibility other; do
    case $wanted_group in
      reality) heading='REALITY 直连（灰云 / DNS only）' ;;
      http-tls) heading='TLS HTTP/CDN（XHTTP / WebSocket / gRPC）' ;;
      modern-direct) heading='现代证书直连（Vision RAW / Hysteria2）' ;;
      compatibility) heading='兼容保留（新部署不优先）' ;;
      other) heading='其他协议' ;;
    esac
    printf '\n[%s]\n' "$heading"
    for node_file in "$NODES_DIR"/*.env "$NODES_DIR"/*.disabled; do
      [[ -e $node_file ]] || continue
      # Node files are generated by this script with mode 0600.
      EXTRA_UUIDS=''
      # shellcheck disable=SC1090
      load_state_file "$node_file"
      group=$(profile_group)
      [[ $group == "$wanted_group" ]] || continue
      node_id=$(basename "$node_file"); node_id=${node_id%.env}; node_id=${node_id%.disabled}
      [[ $node_file == *.env ]] && state='启用' || state='停用'
      link_count=1
      [[ -z ${EXTRA_UUIDS:-} ]] || link_count=$(( $(tr -cd ',' <<<"$EXTRA_UUIDS" | wc -c) + 2 ))
      printf '%-22s %-7s %-30s %-8s %s\n' "$node_id" "$state" "$(profile_name)" "$link_count" "$PORT"
    done
  done
  ui_box_bottom
  printf '\n'
)

add_inbound() {
  [[ -x $XRAY_BIN ]] || die "请先安装 Xray。"
  PORT=''; UUID=''; EXTRA_UUIDS=''; ADDRESS=''; PROFILE=''; PATH_VALUE=''; PRIVATE_KEY=''; PUBLIC_KEY=''; SHORT_ID=''; REMARK=''; CERT_SOURCE=''; KEY_SOURCE=''; SERVER_NAME=''
  ask_server_values
  ensure_port_available
  create_backup
  prepare_tls_material
  local node_id="$REMARK" suffix=1
  node_id=$(printf '%s' "$node_id" | tr -cs 'A-Za-z0-9._-' '-' | sed 's/^-//;s/-$//')
  [[ -n $node_id ]] || node_id="node-$(date +%s)"
  while [[ -e $NODES_DIR/$node_id.env || -e $NODES_DIR/$node_id.disabled ]]; do node_id="${node_id}-${suffix}"; ((suffix+=1)); done
  save_current_node "$NODES_DIR/$node_id.env"
  rebuild_or_restore
  restart_or_rollback
  sync_managed_caddy_route || die "新增入站后同步 Caddy 路由失败，正在恢复修改前状态。"
  green "已添加入站：$node_id"
  open_enabled_inbound_ports
  show_connection_loaded "$CONFIG_FILE"
}

sync_managed_caddy_route() {
  profile_supports_caddy_route || return 0
  if ! managed_caddy_webroot "$SERVER_NAME" >/dev/null; then
    yellow "尚未发现由本项目管理的 $SERVER_NAME Caddy 站点；请使用 v2ray caddy 同步 $PATH_VALUE 路由。"
    return 0
  fi
  configure_caddy_site xray "$SERVER_NAME" "127.0.0.1:$PORT" "$PATH_VALUE"
}

show_all_links() (
  local node_file node_id failures=0 count=0
  for node_file in "$NODES_DIR"/*.env; do
    [[ -e $node_file ]] || continue
    # shellcheck disable=SC1090
    EXTRA_UUIDS=''
    # shellcheck disable=SC1090
    load_state_file "$node_file"
    node_id=$(basename "$node_file" .env)
    ((count+=1))
    printf '\n================ %s ================\n' "$node_id"
    show_connection_loaded "$CONFIG_FILE" || ((failures+=1))
  done
  (( count > 0 && failures == 0 ))
)

load_sub_link_credentials() {
  local node_id=$1 node_file credential
  local -a extra_credentials
  if ! valid_node_id "$node_id" || [[ ! -f $NODES_DIR/$node_id.env ]]; then
    die "找不到启用的入站：$node_id"
  fi
  node_file="$NODES_DIR/$node_id.env"
  EXTRA_UUIDS=''
  # shellcheck disable=SC1090
  load_state_file "$node_file"
  SUB_LINK_CREDENTIALS=("$UUID")
  if [[ -n ${EXTRA_UUIDS:-} ]]; then
    IFS=',' read -r -a extra_credentials <<<"$EXTRA_UUIDS"
    for credential in "${extra_credentials[@]}"; do
      valid_uuid "$credential" || die "入站 $node_id 含有无效的子链接凭据。"
      SUB_LINK_CREDENTIALS+=("$credential")
    done
  fi
  (( ${#SUB_LINK_CREDENTIALS[@]} <= 10 )) || die "单个入站最多支持 10 条链接。"
  SUB_LINK_NODE_FILE=$node_file
}

save_sub_link_credentials() {
  local node_id=$1 operation=$2
  shift 2
  local -a credentials=("$@")
  (( ${#credentials[@]} >= 1 && ${#credentials[@]} <= 10 )) || die "子链接总数必须是 1 到 10。"
  UUID=${credentials[0]}
  if (( ${#credentials[@]} > 1 )); then
    EXTRA_UUIDS=$(IFS=,; printf '%s' "${credentials[*]:1}")
  else
    EXTRA_UUIDS=''
  fi
  create_backup
  save_current_node "$SUB_LINK_NODE_FILE"
  rebuild_or_restore
  restart_or_rollback
  green "入站 $node_id：$operation，当前共 ${#credentials[@]} 条链接。"
}

set_sub_link_count() {
  local node_id=$1 count=$2 credential
  local -a selected
  [[ $count =~ ^([1-9]|10)$ ]] || die "子链接总数必须是 1 到 10。"
  load_sub_link_credentials "$node_id"
  while (( ${#SUB_LINK_CREDENTIALS[@]} < count )); do
    credential=$("$XRAY_BIN" uuid)
    valid_uuid "$credential" || die "Xray 生成了无效 UUID。"
    SUB_LINK_CREDENTIALS+=("$credential")
  done
  selected=("${SUB_LINK_CREDENTIALS[@]:0:count}")
  save_sub_link_credentials "$node_id" "已设置链接总数为 $count" "${selected[@]}"
  show_connection_loaded "$CONFIG_FILE"
}

list_sub_links() {
  local node_id=$1 index=0 credential masked link_label
  load_sub_link_credentials "$node_id"
  printf '\n入站: %s\n协议: %s\n端口: %s\n链接总数: %s\n' "$node_id" "$(profile_name)" "$PORT" "${#SUB_LINK_CREDENTIALS[@]}"
  printf '%-6s %-22s %s\n' '序号' '凭据标识' '导出备注'
  printf '%s\n' '------------------------------------------------------------'
  for credential in "${SUB_LINK_CREDENTIALS[@]}"; do
    ((index+=1))
    masked="${credential:0:8}…${credential: -4}"
    link_label=$REMARK
    (( ${#SUB_LINK_CREDENTIALS[@]} == 1 )) || link_label="${REMARK}-${index}"
    printf '%-6s %-22s %s\n' "$index" "$masked" "$link_label"
  done
  printf '\n'
}

add_sub_links() {
  local node_id=$1 add_count=${2:-1} credential
  [[ $add_count =~ ^([1-9]|10)$ ]] || die "每次新增数量必须是 1 到 10。"
  load_sub_link_credentials "$node_id"
  (( ${#SUB_LINK_CREDENTIALS[@]} + add_count <= 10 )) || die "新增后会超过单个入站 10 条链接的上限。"
  while (( add_count > 0 )); do
    credential=$("$XRAY_BIN" uuid)
    valid_uuid "$credential" || die "Xray 生成了无效 UUID。"
    SUB_LINK_CREDENTIALS+=("$credential")
    add_count=$((add_count - 1))
  done
  save_sub_link_credentials "$node_id" '已新增子链接' "${SUB_LINK_CREDENTIALS[@]}"
  show_connection_loaded "$CONFIG_FILE"
}

delete_sub_link() {
  local node_id=$1 index=$2 array_index
  local -a remaining
  [[ $index =~ ^([1-9]|10)$ ]] || die "链接序号必须是 1 到 10。"
  load_sub_link_credentials "$node_id"
  (( ${#SUB_LINK_CREDENTIALS[@]} > 1 )) || die "不能删除唯一链接；每个入站至少保留一条。"
  (( index <= ${#SUB_LINK_CREDENTIALS[@]} )) || die "链接序号不存在：$index"
  array_index=$((index - 1))
  remaining=("${SUB_LINK_CREDENTIALS[@]:0:array_index}" "${SUB_LINK_CREDENTIALS[@]:array_index+1}")
  save_sub_link_credentials "$node_id" "已删除第 $index 条链接" "${remaining[@]}"
  list_sub_links "$node_id"
}

replace_sub_link() {
  local node_id=$1 index=$2 array_index credential
  [[ $index =~ ^([1-9]|10)$ ]] || die "链接序号必须是 1 到 10。"
  load_sub_link_credentials "$node_id"
  (( index <= ${#SUB_LINK_CREDENTIALS[@]} )) || die "链接序号不存在：$index；入站 $node_id 当前只有 ${#SUB_LINK_CREDENTIALS[@]} 条链接。新增链接请运行：v2ray users add $node_id 1"
  credential=$("$XRAY_BIN" uuid)
  valid_uuid "$credential" || die "Xray 生成了无效 UUID。"
  array_index=$((index - 1))
  SUB_LINK_CREDENTIALS[array_index]=$credential
  save_sub_link_credentials "$node_id" "已重新生成第 $index 条链接" "${SUB_LINK_CREDENTIALS[@]}"
  show_connection_loaded "$CONFIG_FILE"
}

sub_link_menu() {
  local choice node_id count index answer
  while :; do
    printf '\n'
    list_inbounds
    ui_box_title '子链接用户管理'
    ui_menu_item '1) 查看指定入站的链接用户'
    ui_menu_item '2) 新增链接用户'
    ui_menu_item '3) 删除指定链接用户'
    ui_menu_item '4) 重新生成指定链接凭据'
    ui_menu_item '5) 输出指定入站全部链接'
    ui_menu_item '6) 兼容模式：设置链接总数'
    ui_box_divider
    ui_menu_item '0) 返回连接与导出'
    ui_box_bottom
    read -r -p '请选择 [0-6]:' choice
    case "$choice" in
      1) read -r -p '请输入启用的入站 ID：' node_id; list_sub_links "$node_id"; pause ;;
      2) read -r -p '请输入启用的入站 ID：' node_id; read -r -p '新增数量 [1]：' count; run_mutation add_sub_links "$node_id" "${count:-1}"; pause ;;
      3)
        read -r -p '请输入启用的入站 ID：' node_id; list_sub_links "$node_id"
        read -r -p '请输入要删除的链接序号：' index
        read -r -p "确认删除第 $index 条链接？[y/N] " answer
        [[ ${answer,,} == y || ${answer,,} == yes ]] && run_mutation delete_sub_link "$node_id" "$index"
        pause
        ;;
      4)
        read -r -p '请输入启用的入站 ID：' node_id; list_sub_links "$node_id"
        read -r -p '请输入要重新生成的链接序号：' index
        read -r -p "确认使第 $index 条旧链接失效并重新生成？[y/N] " answer
        [[ ${answer,,} == y || ${answer,,} == yes ]] && run_mutation replace_sub_link "$node_id" "$index"
        pause
        ;;
      5) read -r -p '请输入启用的入站 ID：' node_id; show_connection "$node_id"; pause ;;
      6) read -r -p '请输入启用的入站 ID：' node_id; read -r -p '请输入链接总数 [1-10]：' count; run_mutation set_sub_link_count "$node_id" "$count"; pause ;;
      0) return ;;
      *) yellow '无效选择。'; pause ;;
    esac
  done
}

SELECTED_NODE_FILES=()
select_node_files() {
  local wanted_state=${1:-any} allow_empty=${2:-0} input node_id candidate
  local -a requested candidates
  local -A seen=()
  SELECTED_NODE_FILES=()
  list_inbounds >&2
  read -r -p '请输入入站 ID（多个用空格或逗号分隔，all 表示全部）：' input
  input=${input//,/ }
  read -r -a requested <<<"$input"
  (( ${#requested[@]} > 0 )) || die '至少选择一个入站。'
  if [[ ${requested[0],,} == all ]]; then
    case "$wanted_state" in
      enabled) candidates=("$NODES_DIR"/*.env) ;;
      disabled) candidates=("$NODES_DIR"/*.disabled) ;;
      any) candidates=("$NODES_DIR"/*.env "$NODES_DIR"/*.disabled) ;;
      *) die "未知入站选择状态：$wanted_state" ;;
    esac
    for candidate in "${candidates[@]}"; do [[ -e $candidate ]] && SELECTED_NODE_FILES+=("$candidate"); done
  else
    for node_id in "${requested[@]}"; do
      node_id=${node_id%.env}; node_id=${node_id%.disabled}
      valid_node_id "$node_id" || die "入站 ID 格式无效：$node_id"
      [[ -z ${seen[$node_id]:-} ]] || continue
      seen[$node_id]=1
      candidate=
      case "$wanted_state" in
        enabled) [[ -e $NODES_DIR/$node_id.env ]] && candidate="$NODES_DIR/$node_id.env" ;;
        disabled) [[ -e $NODES_DIR/$node_id.disabled ]] && candidate="$NODES_DIR/$node_id.disabled" ;;
        any)
          if [[ -e $NODES_DIR/$node_id.env ]]; then candidate="$NODES_DIR/$node_id.env"
          elif [[ -e $NODES_DIR/$node_id.disabled ]]; then candidate="$NODES_DIR/$node_id.disabled"; fi
          ;;
        *) die "未知入站选择状态：$wanted_state" ;;
      esac
      [[ -n $candidate ]] || die "找不到符合当前操作状态的入站：$node_id"
      SELECTED_NODE_FILES+=("$candidate")
    done
  fi
  if (( ${#SELECTED_NODE_FILES[@]} == 0 )); then
    (( allow_empty )) && return 0
    die '没有符合条件的入站。'
  fi
}

selected_node_names() {
  local file
  for file in "${SELECTED_NODE_FILES[@]}"; do basename "$file" | sed -E 's/\.(env|disabled)$//'; done
}

disable_inbound() {
  local node_file
  select_node_files enabled 1
  if (( ${#SELECTED_NODE_FILES[@]} == 0 )); then
    green '所有入站已经停用，无需操作。'
    return 0
  fi
  create_backup
  for node_file in "${SELECTED_NODE_FILES[@]}"; do mv "$node_file" "${node_file%.env}.disabled"; done
  rebuild_or_restore
  restart_or_rollback
  green "已批量停用 ${#SELECTED_NODE_FILES[@]} 个入站。"
}

modify_inbound() (
  local node_file mode value node_id
  select_node_files enabled
  create_backup
  [[ -n ${LAST_BACKUP:-} ]] || die "无法创建修改前备份，未修改入站。"
  INBOUND_EDIT_ARCHIVE=$LAST_BACKUP
  INBOUND_EDIT_COMMITTED=0
  INBOUND_EDIT_RESTART_ATTEMPTED=0
  trap 'finish_inbound_edit "$?" "${INBOUND_EDIT_ARCHIVE:-}" "${INBOUND_EDIT_COMMITTED:-0}" "${INBOUND_EDIT_RESTART_ATTEMPTED:-0}"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if (( ${#SELECTED_NODE_FILES[@]} > 1 )); then
    printf '%s\n' '批量修改方式：' '1) 全部改为同一客户端入口域名' \
      '2) 全部改为同一 REALITY 目标域名' '3) 逐个完整修改' '0) 取消'
    read -r -p '请选择 [0-3]：' mode
    case "$mode" in
      1)
        read -r -p '新的客户端入口域名：' value
        valid_server_name "$value" || die '请输入有效的完整入口域名。'
        for node_file in "${SELECTED_NODE_FILES[@]}"; do
          # shellcheck disable=SC1090
          load_state_file "$node_file"
          ADDRESS=$value
          save_current_node "$node_file"
        done
        ;;
      2)
        read -r -p "新的 REALITY 目标域名 [${DEFAULT_REALITY_SERVER_NAME}]：" value
        value=${value:-$DEFAULT_REALITY_SERVER_NAME}
        valid_server_name "$value" || die '请输入有效的完整 REALITY 目标域名。'
        reality_target_supported "$value" || die "当前 Xray 版本不支持稳定使用 $value；请改用 $DEFAULT_REALITY_SERVER_NAME。"
        for node_file in "${SELECTED_NODE_FILES[@]}"; do
          # shellcheck disable=SC1090
          load_state_file "$node_file"
          profile_uses_reality || die "$(basename "$node_file") 不是 REALITY 入站，批量操作已取消。"
        done
        for node_file in "${SELECTED_NODE_FILES[@]}"; do
          # shellcheck disable=SC1090
          load_state_file "$node_file"
          SERVER_NAME=$value
          save_current_node "$node_file"
        done
        ;;
      3)
        for node_file in "${SELECTED_NODE_FILES[@]}"; do
          node_id=$(basename "$node_file" .env)
          cyan_value "正在修改：$node_id"; printf '\n'
          EXTRA_UUIDS=''
          # shellcheck disable=SC1090
          load_state_file "$node_file"
          ask_server_values
          ensure_port_available
          prepare_tls_material
          save_current_node "$node_file"
        done
        ;;
      0) return ;;
      *) die '批量修改方式无效。' ;;
    esac
  else
    node_file=${SELECTED_NODE_FILES[0]}
    EXTRA_UUIDS=''
    # shellcheck disable=SC1090
    load_state_file "$node_file"
    ask_server_values
    ensure_port_available
    prepare_tls_material
    save_current_node "$node_file"
  fi
  rebuild_config_from_nodes || die "入站配置生成失败，正在恢复修改前状态。"
  INBOUND_EDIT_RESTART_ATTEMPTED=1
  restart_checked || die "新配置启动失败，正在恢复修改前状态。"
  INBOUND_EDIT_COMMITTED=1
  trap - EXIT INT TERM
  green "已更新 ${#SELECTED_NODE_FILES[@]} 个入站。"
  open_enabled_inbound_ports
  list_inbounds
)

finish_inbound_edit() {
  local status=$1 archive=$2 committed=$3 restart_attempted=$4
  trap - EXIT INT TERM
  if (( status != 0 && ! committed )); then
    if restore_archive "$archive"; then
      yellow "已恢复本次修改前的全部入站和配置。"
      if (( restart_attempted )); then
        restart_checked || { red "配置已恢复，但服务恢复失败，请运行 v2ray log。"; exit 1; }
      fi
    else
      red "自动回滚失败，修改前备份保留在 $archive。"
      exit 1
    fi
  fi
  exit "$status"
}

enable_inbound() {
  local node_file
  select_node_files disabled 1
  if (( ${#SELECTED_NODE_FILES[@]} == 0 )); then
    green '所有入站已经启用，无需操作。'
    return 0
  fi
  create_backup
  for node_file in "${SELECTED_NODE_FILES[@]}"; do mv "$node_file" "${node_file%.disabled}.env"; done
  rebuild_or_restore
  restart_or_rollback
  green "已批量启用 ${#SELECTED_NODE_FILES[@]} 个入站。"
}

delete_inbound() {
  local node_file answer names
  select_node_files any
  names=$(selected_node_names | paste -sd ', ' -)
  read -r -p "确认删除 ${#SELECTED_NODE_FILES[@]} 个入站（$names）？请输入 DELETE：" answer
  [[ $answer == DELETE ]] || return
  create_backup
  for node_file in "${SELECTED_NODE_FILES[@]}"; do rm -f -- "$node_file"; done
  rebuild_or_restore
  restart_or_rollback
  green "已批量删除 ${#SELECTED_NODE_FILES[@]} 个入站。"
}

manage_inbounds_menu() {
  local choice
  while :; do
    printf '\n'
    ui_box_title '入站管理'
    ui_menu_item '1) 查看入站列表'
    ui_menu_item '2) 添加新入站'
    ui_menu_item '3) 修改入站（支持批量）'
    ui_menu_item '4) 停用入站（支持批量）'
    ui_menu_item '5) 启用入站（支持批量）'
    ui_menu_item '6) 删除入站（支持批量）'
    ui_box_divider
    ui_menu_item '0) 返回主菜单'
    ui_box_bottom
    read -r -p '请选择 [0-6]:' choice
    case "$choice" in
      1) list_inbounds; pause ;; 2) run_mutation add_inbound; pause ;; 3) run_mutation modify_inbound; pause ;;
      4) run_mutation disable_inbound; pause ;; 5) run_mutation enable_inbound; pause ;; 6) run_mutation delete_inbound; pause ;;
      0) return ;; *) yellow "无效选择。"; pause ;;
    esac
  done
}

export_menu() {
  local choice node_id cdn_address
  while :; do
    printf '\n'
    ui_box_title '连接与导出'
    ui_menu_item '1) 查看入站列表'
    ui_menu_item '2) 输出全部启用链接'
    ui_menu_item '3) 输出指定入站链接'
    ui_menu_item '4) 使用 Cloudflare/CDN 域名输出链接'
    ui_menu_item '5) 子链接用户管理（增删改查）'
    ui_menu_item '6) 导出 Xray 客户端 JSON'
    ui_menu_item '7) Cloudflare 优选 IP（独立分支）'
    ui_box_divider
    ui_menu_item '0) 返回主菜单'
    ui_box_bottom
    read -r -p '请选择 [0-7]:' choice
    case "$choice" in
      1) list_inbounds; pause ;;
      2) show_all_links; pause ;;
      3)
        list_inbounds
        read -r -p '请输入启用的入站 ID：' node_id
        show_connection "$node_id"; pause
        ;;
      4)
        list_inbounds
        read -r -p '请输入 TLS XHTTP/WS 入站 ID：' node_id
        read -r -p '请输入 Cloudflare/CDN 入口域名：' cdn_address
        show_connection "$node_id" "$cdn_address"; pause
        ;;
      5) sub_link_menu ;;
      6)
        list_inbounds
        read -r -p '请输入启用的入站 ID（回车使用默认入站）：' node_id
        export_client "$node_id"; pause
        ;;
      7) cloudflare_ip_menu ;;
      0) return ;;
      *) yellow "无效选择。"; pause ;;
    esac
  done
}

users_command() {
  local action=${1:-menu}
  case $action in
    menu) sub_link_menu ;;
    list) if [[ -n ${2:-} ]]; then list_sub_links "$2"; else list_inbounds; fi ;;
    show) [[ -n ${2:-} ]] || die '用法：v2ray users show <入站ID>'; show_connection "$2" ;;
    add) [[ -n ${2:-} ]] || die '用法：v2ray users add <入站ID> [数量]'; run_mutation add_sub_links "$2" "${3:-1}" ;;
    delete|del|remove) [[ -n ${2:-} && -n ${3:-} ]] || die '用法：v2ray users delete <入站ID> <序号>'; run_mutation delete_sub_link "$2" "$3" ;;
    replace|reset) [[ -n ${2:-} && -n ${3:-} ]] || die '用法：v2ray users replace <入站ID> <序号>'; run_mutation replace_sub_link "$2" "$3" ;;
    set) [[ -n ${2:-} && -n ${3:-} ]] || die '用法：v2ray users set <入站ID> <1-10>'; run_mutation set_sub_link_count "$2" "$3" ;;
    *)
      if [[ -n ${2:-} && $2 =~ ^([1-9]|10)$ ]]; then
        run_mutation set_sub_link_count "$1" "$2"
      else
        die '用法：v2ray users [list [入站ID]|show <入站ID>|add <入站ID> [数量]|delete <入站ID> <序号>|replace <入站ID> <序号>|set <入站ID> <1-10>]'
      fi
      ;;
  esac
}

rotate_reality_keys() {
  [[ -x "$XRAY_BIN" ]] || die "尚未安装。"
  load_edit_node "${1:-}"
  profile_uses_reality || die "当前 TLS 组合不使用 REALITY 密钥。"
  generate_reality_credentials
  write_config "$EDIT_NODE_FILE"
  restart_or_rollback
  green "REALITY 密钥和 Short ID 已轮换，旧客户端链接立即失效。"
  show_connection "$(basename "$EDIT_NODE_FILE" .env)"
}

service_action() {
  local action=$1
  systemctl "$action" "$SERVICE_NAME"
  if [[ $action == start || $action == restart ]]; then
    service_healthy || die "服务未通过健康检查，请运行 v2ray log。"
    sync_hysteria_services || die "Hysteria2 官方服务未通过健康检查，请运行 journalctl -u 'hysteria-v2ray-manager@*'。"
  elif [[ $action == stop ]]; then
    systemctl stop 'hysteria-v2ray-manager@*.service' >/dev/null 2>&1 || true
  fi
  green "已执行：${action}。"
}

show_status() { systemctl --no-pager --full status "$SERVICE_NAME" 'hysteria-v2ray-manager@*.service' || true; }
show_logs() { journalctl -u "$SERVICE_NAME" -u 'hysteria-v2ray-manager@*.service' -n 100 --no-pager; }

run_speedtest() {
  local version
  printf '%s\n' '===== 服务器网络测速 ====='
  yellow "测速会连接外部 Speedtest 服务器，并消耗服务器流量。"

  if command -v speedtest >/dev/null 2>&1; then
    version=$(speedtest --version 2>&1 | head -n 1 || true)
    if [[ $version == *Ookla* ]]; then
      speedtest --accept-license --accept-gdpr || {
        red "Speedtest 测速失败；请检查服务器出站网络和 DNS。" >&2
        return 1
      }
      return
    fi
  fi

  if ! command -v speedtest-cli >/dev/null 2>&1; then
    step "安装 speedtest-cli"
    if ! apt-get update || ! DEBIAN_FRONTEND=noninteractive apt-get install -y speedtest-cli; then
      red "无法安装 speedtest-cli。" >&2
      return 1
    fi
  fi
  speedtest-cli --secure || {
    red "Speedtest 测速失败；请检查服务器出站网络和 DNS。" >&2
    return 1
  }
}

install_route_tools() {
  if command -v mtr >/dev/null 2>&1 && command -v ping >/dev/null 2>&1; then return; fi
  step "安装路由测试工具"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y mtr-tiny iputils-ping traceroute
}

route_latency_test() {
  local target=$1
  valid_route_target "$target" || { red "目标只能是有效 IP 或域名，不能包含 URL、端口或空格。" >&2; return 1; }
  getent ahosts "$target" >/dev/null 2>&1 || { red "目标无法解析：$target" >&2; return 1; }
  install_route_tools || return 1
  printf '\n%s\n' "===== VPS → $target 回程路由与延迟 ====="
  yellow "该结果从服务器发起，表示 VPS 到目标的回程方向；逐跳星号可能只是路由器不响应探测。"
  printf '\n%s\n' '--- ICMP 延迟 ---'
  ping -c 5 -W 2 "$target" || yellow "目标未响应 ICMP；这不一定表示 TCP 服务不可用。"
  printf '\n%s\n' '--- MTR 路由、丢包与逐跳延迟（10 轮）---'
  mtr --report --report-wide --show-ips --report-cycles 10 "$target" || {
    red "MTR 测试失败。" >&2
    return 1
  }
}

show_forward_test_commands() (
  local address port
  load_connection_state || return 1
  address=$(server_address)
  port=$PORT
  [[ -n $address && $address != YOUR_SERVER_DOMAIN ]] || {
    red "无法确定客户端入口地址，请先在入站配置中设置服务器地址。" >&2
    return 1
  }
  address=${address#[}; address=${address%]}
  printf '\n%s\n' '===== 客户端 → VPS 去程测试 ====='
  printf '请在发生连接问题的客户端网络执行；目标为 %s，节点端口为 %s。\n\n' "$address" "$port"
  printf '%s\n' 'Windows PowerShell：'
  printf '  Test-NetConnection %s -Port %s\n' "$address" "$port"
  printf '  tracert -d %s\n\n' "$address"
  printf '%s\n' 'Linux/macOS：'
  printf '  ping -c 5 %s\n' "$address"
  printf '  traceroute -n %s\n' "$address"
  printf '  nc -vz -w 5 %s %s\n\n' "$address" "$port"
  yellow "去程必须从客户端所在网络发起；VPS 本机无法还原客户端运营商的真实去程。"
)

route_test_menu() {
  local choice target
  while :; do
    printf '\n'
    ui_box_title '路由与延迟测试'
    ui_menu_item '1) 测试 VPS → 目标的回程路由、丢包和延迟'
    ui_menu_item '2) 显示客户端 → VPS 去程测试命令'
    ui_menu_item '3) Speedtest 带宽测速'
    ui_box_divider
    ui_menu_item '0) 返回维护菜单'
    ui_box_bottom
    read -r -p '请选择 [0-3]:' choice
    case "$choice" in
      1)
        read -r -p '请输入客户端公网 IP 或目标域名：' target
        route_latency_test "$target" || true
        pause
        ;;
      2) show_forward_test_commands || true; pause ;;
      3) run_speedtest || true; pause ;;
      0) return ;;
      *) yellow "无效选择。"; pause ;;
    esac
  done
}

valid_caddy_upstream() {
  local port
  if [[ $1 =~ ^(127\.0\.0\.1|localhost):([0-9]+)$ ]]; then
    port=${BASH_REMATCH[2]}
  elif [[ $1 =~ ^\[::1\]:([0-9]+)$ ]]; then
    port=${BASH_REMATCH[1]}
  else
    return 1
  fi
  valid_port "$port"
}

render_caddy_site() {
  local mode=$1 domain=$2 upstream=${3:-} destination=$4 path=${5:-}
  valid_server_name "$domain" || return 1
  case "$mode" in
    static)
      cat > "$destination" <<EOF
$domain {
	root * $CADDY_WEB_ROOT/$domain
	encode zstd gzip
	file_server
}
EOF
      ;;
    reverse)
      valid_caddy_upstream "$upstream" || return 1
      cat > "$destination" <<EOF
$domain {
	encode zstd gzip
	reverse_proxy $upstream
}
EOF
      ;;
    xray)
      render_caddy_xray_site "$domain" "$upstream" "$destination" "$path"
      ;;
    *) return 1 ;;
  esac
}

# Render every eligible local XHTTP/WS inbound for this domain into one Caddy
# site. This avoids replacing an existing path route when a second inbound is
# added for the same HTTPS domain.
render_caddy_xray_site() {
  local domain=$1 upstream=$2 destination=$3 path=$4 node_dir=${CADDY_NODE_DIR_OVERRIDE:-$NODES_DIR}
  local node_file PROFILE SERVER_NAME PORT PATH_VALUE route_upstream route_path route_profile existing index=0
  local -a route_paths=() route_upstreams=() route_profiles=()
  declare -A seen_paths=()
  valid_caddy_upstream "$upstream" || return 1
  valid_transport_path "$path" || return 1

  route_paths+=("$path")
  route_upstreams+=("$upstream")
  route_profiles+=("")
  seen_paths["$path"]=$upstream

  if [[ -d $node_dir ]]; then
    for node_file in "$node_dir"/*.env; do
      [[ -f $node_file ]] || continue
      PROFILE=''; SERVER_NAME=''; PORT=''; PATH_VALUE=''
      # Node files are generated by this script with mode 0600.
      # shellcheck disable=SC1090
      load_state_file "$node_file"
      profile_supports_caddy_route "$PROFILE" || continue
      [[ $SERVER_NAME == "$domain" ]] || continue
      if ! valid_port "$PORT" || ! valid_transport_path "$PATH_VALUE"; then
        continue
      fi
      route_upstream="127.0.0.1:$PORT"
      route_path=$PATH_VALUE
      route_profile=$PROFILE
      existing=${seen_paths[$route_path]:-}
      if [[ -n $existing ]]; then
        [[ $existing == "$route_upstream" ]] || {
          red "同一 Caddy 路径 $route_path 对应多个 Xray 后端，拒绝覆盖。" >&2
          return 1
        }
        for index in "${!route_paths[@]}"; do
          if [[ ${route_paths[$index]} == "$route_path" && ${route_upstreams[$index]} == "$route_upstream" ]]; then
            route_profiles[index]=$route_profile
          fi
        done
        continue
      fi
      route_paths+=("$route_path")
      route_upstreams+=("$route_upstream")
      route_profiles+=("$route_profile")
      seen_paths["$route_path"]=$route_upstream
    done
  fi

  {
    printf '%s {\n' "$domain"
    for index in "${!route_paths[@]}"; do
      printf '\t@xray_%s path %s %s/*\n' "$index" "${route_paths[$index]}" "${route_paths[$index]}"
      if [[ ${route_profiles[$index]} == vless-tls-xhttp ]]; then
        printf '\treverse_proxy @xray_%s h2c://%s {\n' "$index" "${route_upstreams[$index]}"
        printf '\t\tflush_interval -1\n\t\ttransport http {\n\t\t\tversions h2c\n\t\t}\n\t}\n'
      else
        printf '\treverse_proxy @xray_%s https://%s {\n' "$index" "${route_upstreams[$index]}"
        # Xray WebSocket uses an HTTP/1.1 Upgrade handshake. Caddy's HTTPS
        # transport otherwise offers both HTTP/1.1 and HTTP/2 to the upstream;
        # pinning 1.1 prevents ALPN from selecting HTTP/2 for a WS backend.
        printf '\t\tflush_interval -1\n\t\ttransport http {\n\t\t\tversions 1.1\n\t\t\ttls_server_name %s\n\t\t}\n\t}\n' "$domain"
      fi
    done
    printf '\troot * %s/%s\n\tencode zstd gzip\n\tfile_server\n}\n' "$CADDY_WEB_ROOT" "$domain"
  } > "$destination"
}

caddy_ports_available() {
  local port listeners
  if [[ -r $CONFIG_FILE ]] && jq -e 'any(.inbounds[]?; .port == 80 or .port == 443)' "$CONFIG_FILE" >/dev/null; then
    red "Xray 当前占用 TCP 80 或 443；标准 Caddy 无法与其共享端口。请先修改对应入站端口。" >&2
    return 1
  fi
  for port in 80 443; do
    listeners=$(ss -H -lntp "sport = :$port" 2>/dev/null || true)
    [[ -z $listeners || $listeners == *caddy* ]] || {
      red "TCP $port 已被其他服务占用，不会停止或覆盖该服务：" >&2
      printf '%s\n' "$listeners" >&2
      return 1
    }
  done
}

install_cloudflare_ip_branch_command() {
  install_component cfip "$CFIP_BRANCH_BIN"
}

call_cloudflare_ip_branch() {
  install_cloudflare_ip_branch_command || return 1
  "$CFIP_BRANCH_BIN" "$@"
}

cloudflare_ip_menu() {
  local choice domain candidates ip node_id
  while :; do
    printf '\n'
    ui_box_title 'Cloudflare 优选 IP（独立分支项目）'
    ui_menu_item '用途：为 Cloudflare 橙云的 TLS XHTTP/WS 链接选择入口 IP。'
    ui_menu_item '链接只替换连接地址；TLS SNI、HTTP Host 和证书域名保持不变。'
    ui_menu_item '步骤：①安装/更新 → ②测试或手动设置 → ③验证 → ④生成链接。'
    ui_box_divider
    ui_menu_item '1) 安装/更新优选 IP 分支'
    ui_menu_item '2) 测试候选 IP 并保存最佳结果（候选用逗号分隔）'
    ui_menu_item '3) 手动保存已知优选 IP 与入站 TLS 域名'
    ui_menu_item '4) 验证当前 IP、HTTPS 和域名组合'
    ui_menu_item '5) 查看当前保存结果'
    ui_menu_item '6) 选择入站并生成优选 IP 分享链接'
    ui_menu_item '7) 清除当前保存结果'
    ui_menu_item '8) 卸载优选 IP 分支项目'
    ui_box_divider
    ui_menu_item '0) 返回连接与导出'
    ui_box_bottom
    read -r -p '请选择 [0-8]:' choice
    case "$choice" in
      1) run_mutation call_cloudflare_ip_branch install; pause ;;
      2) read -r -p 'Cloudflare TLS 域名：' domain; read -r -p '候选公网 IPv4（逗号分隔）：' candidates; run_mutation call_cloudflare_ip_branch test "$domain" "$candidates"; pause ;;
      3) read -r -p '优选公网 IPv4：' ip; read -r -p 'Cloudflare TLS 域名：' domain; run_mutation call_cloudflare_ip_branch set "$ip" "$domain"; pause ;;
      4) call_cloudflare_ip_branch verify || true; pause ;;
      5) call_cloudflare_ip_branch show || true; pause ;;
      6)
        call_cloudflare_ip_branch verify || { pause; continue; }
        list_inbounds
        printf '\n仅可选择 TLS XHTTP/WebSocket 入站；其域名必须与上方验证结果一致。\n'
        read -r -p '请输入启用的入站 ID：' node_id
        show_connection "$node_id" cfip
        pause
        ;;
      7) run_mutation call_cloudflare_ip_branch clear; pause ;;
      8) run_mutation call_cloudflare_ip_branch uninstall; pause ;;
      0) return ;;
      *) yellow '无效选择。'; pause ;;
    esac
  done
}

cloudflare_ip_command() {
  local action=${1:-menu}
  case "$action" in
    menu) cloudflare_ip_menu ;;
    install|test|set|clear|uninstall) run_mutation call_cloudflare_ip_branch "$@" ;;
    verify|show|status|get|domain|version) call_cloudflare_ip_branch "$@" ;;
    *) die '用法：v2ray cfip [install|test <域名> <IP,IP,...>|set <IP> <域名>|verify|show|get|clear|uninstall]' ;;
  esac
}

install_caddy_branch_command() {
  install_component caddy "$CADDY_BRANCH_BIN"
}

call_caddy_branch() (
  install_caddy_branch_command || return 1
  local bridge node_file
  bridge=$(mktemp -d) || return 1
  trap 'rm -rf -- "$bridge"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  # The locked external component still reads shell literals. Translate only
  # validated state into a private, disposable compatibility view.
  for node_file in "$NODES_DIR"/*.env; do
    [[ -f $node_file ]] || continue
    export_legacy_node "$node_file" > "$bridge/$(basename "$node_file")" || return 1
  done
  env V2M_NODES_DIR="$bridge" V2M_XRAY_CONFIG="$CONFIG_FILE" CADDY_CONFIG="$CADDY_CONFIG" CADDY_SITE_DIR="$CADDY_SITE_DIR" CADDY_WEB_ROOT="$CADDY_WEB_ROOT" "$CADDY_BRANCH_BIN" "$@"
)

export_legacy_node() (
  local key
  load_state_file "$1" || return 1
  for key in DATA_SCHEMA PORT UUID EXTRA_UUIDS ADDRESS PROFILE PATH_VALUE CERT_SOURCE KEY_SOURCE SERVER_NAME PRIVATE_KEY PUBLIC_KEY SHORT_ID REMARK XHTTP_MODE; do
    printf '%s=%q\n' "$key" "${!key:-}"
  done
)

install_caddy() {
  install_caddy_branch_command || return 1
  call_caddy_branch install
}

ensure_caddy_import() {
  local temporary backup
  install -d -m 755 "$CADDY_SITE_DIR"
  if [[ ! -e $CADDY_CONFIG ]]; then
    printf 'import %s/*.caddy\n' "$CADDY_SITE_DIR" > "$CADDY_CONFIG"
    chmod 644 "$CADDY_CONFIG"
    return
  fi
  grep -Fqx "import $CADDY_SITE_DIR/*.caddy" "$CADDY_CONFIG" && return
  install -d -m 700 "$BACKUP_DIR"
  backup="$BACKUP_DIR/Caddyfile.$(date -u +%Y%m%dT%H%M%SZ)"
  cp -p "$CADDY_CONFIG" "$backup" || return 1
  temporary=$(mktemp "${CADDY_CONFIG}.XXXXXX") || return 1
  if cp -p "$CADDY_CONFIG" "$temporary" &&
     printf '\nimport %s/*.caddy\n' "$CADDY_SITE_DIR" >> "$temporary" &&
     mv -f "$temporary" "$CADDY_CONFIG"; then
    return
  fi
  rm -f -- "$temporary"
  return 1
}

deploy_caddy_page() { call_caddy_branch page "$1" "${2:-portfolio}"; }

configure_caddy_site() {
  local mode=$1 domain=$2 upstream=${3:-} path=${4:-}
  call_caddy_branch "$mode" "$domain" "$upstream" "$path"
}

find_caddy_xray_defaults() {
  local wanted_domain=$1 node_dir=${CADDY_NODE_DIR_OVERRIDE:-$NODES_DIR} node_file
  local PROFILE SERVER_NAME PORT PATH_VALUE
  [[ -d $node_dir ]] || return 1
  for node_file in "$node_dir"/*.env; do
    [[ -f $node_file ]] || continue
    PROFILE=''; SERVER_NAME=''; PORT=''; PATH_VALUE=''
    # Node files are generated by this script with mode 0600.
    # shellcheck disable=SC1090
    load_state_file "$node_file"
    profile_supports_caddy_route "$PROFILE" || continue
    [[ $SERVER_NAME == "$wanted_domain" ]] || continue
    if ! valid_port "$PORT" || ! valid_transport_path "$PATH_VALUE"; then continue; fi
    printf '127.0.0.1:%s\t%s\n' "$PORT" "$PATH_VALUE"
    return 0
  done
  return 1
}

normalize_caddy_path() {
  local path=${1:-/xhttp}
  [[ $path == /* ]] || path="/$path"
  valid_transport_path "$path" || return 1
  printf '%s' "$path"
}

caddy_page_menu() {
  local domain choice template
  read -r -p '网站域名：' domain
  printf '\n'
  ui_box_title '选择可选网页'
  ui_menu_item '1) Portfolio 博客'
  ui_menu_item '2) Resume 博客'
  ui_menu_item '3) 通用占位页'
  ui_box_bottom
  read -r -p '选择网页 [1-3]：' choice
  case "$choice" in
    1) template=portfolio ;; 2) template=resume ;; 3) template=default ;;
    *) yellow '无效选择。'; pause; return ;;
  esac
  yellow '此操作会替换该域名当前网页文件，但不会修改 Caddy/Xray 路由。'
  read -r -p '确认部署？[y/N] ' choice
  if [[ ${choice,,} == y || ${choice,,} == yes ]]; then
    run_mutation deploy_caddy_page "$domain" "$template" || true
  fi
  pause
}

caddy_menu() {
  local choice domain upstream path suggested_upstream suggested_path
  while :; do
    printf '\n'
    ui_box_title 'Caddy 网站管理'
    ui_menu_item '1) 安装 Caddy'
    ui_menu_item '2) 创建静态伪装网站'
    ui_menu_item '3) 创建本机反向代理'
    ui_menu_item '4) 同步 Xray XHTTP/WS 路径反代'
    ui_menu_item '5) 安装/更新可选网页'
    ui_menu_item '6) 查看 Caddy 状态'
    ui_menu_item '7) 查看 Caddy 日志'
    ui_menu_item '8) 验证 Caddy 分支'
    ui_menu_item '9) 修复 Caddy 分支'
    ui_menu_item '10) 卸载 Caddy 软件（保留数据）'
    ui_box_divider
    ui_menu_item '0) 返回主菜单'
    ui_box_bottom
    read -r -p '请选择 [0-10]:' choice
    case "$choice" in
      1) caddy_ports_available && run_mutation install_caddy && green "Caddy 已安装。"; pause ;;
      2) read -r -p '网站域名：' domain; run_mutation configure_caddy_site static "$domain" || true; pause ;;
      3)
        read -r -p '网站域名：' domain
        read -r -p '本机后端 [127.0.0.1:8080]：' upstream
        run_mutation configure_caddy_site reverse "$domain" "${upstream:-127.0.0.1:8080}" || true; pause
        ;;
      4)
        read -r -p 'TLS 域名：' domain
        suggested_upstream='127.0.0.1:24443'; suggested_path='/xhttp'
        if IFS=$'\t' read -r suggested_upstream suggested_path < <(find_caddy_xray_defaults "$domain"); then
          green "已匹配该域名的 Xray 入站：${suggested_upstream}${suggested_path}"
        else
          yellow "未找到同域名的 TLS XHTTP/WS 入站，将使用可修改的默认值。"
        fi
        read -r -p "Xray 本机 TLS 后端 [${suggested_upstream}]：" upstream
        upstream=${upstream:-$suggested_upstream}
        read -r -p "XHTTP/WS 路径 [${suggested_path}]：" path
        if ! path=$(normalize_caddy_path "${path:-$suggested_path}"); then
          red "Xray 传输路径无效：不能包含空格或连续的 /。"
          pause
          continue
        fi
        run_mutation configure_caddy_site xray "$domain" "$upstream" "$path" || true
        pause
        ;;
      5) caddy_page_menu ;;
      6) systemctl --no-pager --full status caddy || true; pause ;;
      7) journalctl -u caddy -n 100 --no-pager || true; pause ;;
      8) call_caddy_branch verify || true; pause ;;
      9) run_mutation call_caddy_branch repair || true; pause ;;
      10)
        read -r -p '确认卸载 Caddy 软件并保留站点配置、证书和网页？[y/N] ' choice
        if [[ ${choice,,} == y || ${choice,,} == yes ]]; then run_mutation call_caddy_branch uninstall || true; fi
        pause
        ;;
      0) return ;;
      *) yellow "无效选择。"; pause ;;
    esac
  done
}
caddy_command() {
  local action=${1:-menu} domain=${2:-} upstream=${3:-} path=${4:-}
  case "$action" in
    menu) caddy_menu ;;
    install) caddy_ports_available && run_mutation install_caddy ;;
    static) [[ -n $domain ]] || die "用法：v2ray caddy static <域名>"; run_mutation configure_caddy_site static "$domain" ;;
    reverse) [[ -n $domain && -n $upstream ]] || die "用法：v2ray caddy reverse <域名> <本机地址:端口>"; run_mutation configure_caddy_site reverse "$domain" "$upstream" ;;
    xray) [[ -n $domain && -n $upstream && -n $path ]] || die "用法：v2ray caddy xray <域名> <本机TLS地址:端口> <路径>"; run_mutation configure_caddy_site xray "$domain" "$upstream" "$path" ;;
    page) [[ -n $domain ]] || die "用法：v2ray caddy page <域名> [portfolio|resume|default]"; run_mutation deploy_caddy_page "$domain" "${upstream:-portfolio}" ;;
    status) systemctl --no-pager --full status caddy || true ;;
    log) journalctl -u caddy -n 100 --no-pager ;;
    verify|test) call_caddy_branch verify ;;
    repair) run_mutation call_caddy_branch repair ;;
    uninstall) run_mutation call_caddy_branch uninstall ;;
    *) die "未知 Caddy 操作：$action" ;;
  esac
}

valid_warp_backend() {
  [[ $1 == wireguard || $1 == masque ]]
}

active_warp_backend() {
  local WARP_BACKEND=''
  if [[ -r $WARP_BACKEND_STATE_FILE ]]; then
    load_state_file "$WARP_BACKEND_STATE_FILE" || return 1
  fi
  if valid_warp_backend "${WARP_BACKEND:-}"; then
    printf '%s' "$WARP_BACKEND"
  else
    printf none
  fi
}

warp_backend_bin() {
  case $1 in
    wireguard) printf '%s' "$WARP_WIREGUARD_BIN" ;;
    masque) printf '%s' "$WARP_MASQUE_BIN" ;;
    *) return 1 ;;
  esac
}

install_warp_backend_command() {
  local backend=$1 destination
  valid_warp_backend "$backend" || die "未知 WARP 后端：$backend"
  destination=$(warp_backend_bin "$backend")
  install_component "$backend" "$destination"
}

stop_warp_backend() {
  local command
  command=$(warp_backend_bin "$1" 2>/dev/null || true)
  if [[ -x $command ]]; then
    verify_component "$1" "$command" || return 1
    "$command" stop >/dev/null 2>&1 || true
  fi
}

start_warp_backend() {
  local command
  command=$(warp_backend_bin "$1" 2>/dev/null || true)
  if [[ -x $command ]]; then
    verify_component "$1" "$command" || return 1
    "$command" start >/dev/null 2>&1 || true
  fi
}

save_warp_backend() {
  local backend=$1
  printf 'WARP_BACKEND=%q\n' "$backend" >"$WARP_BACKEND_STATE_FILE"
  chmod 600 "$WARP_BACKEND_STATE_FILE"
}

warp_proxy_ready() {
  ss -H -lnt "sport = :${WARP_PROXY_PORT}" 2>/dev/null | grep -q .
}

install_warp() {
  require_supported_os
  local backend=${1:-wireguard} previous command
  valid_warp_backend "$backend" || die 'WARP 后端必须是 wireguard 或 masque。'
  previous=$(active_warp_backend)
  install_warp_backend_command "$backend"
  command=$(warp_backend_bin "$backend")
  if [[ $previous != none && $previous != "$backend" ]]; then stop_warp_backend "$previous"; fi
  if ! "$command" install "$WARP_PROXY_PORT"; then
    [[ $previous == none || $previous == "$backend" ]] || start_warp_backend "$previous"
    red "WARP $backend 后端安装失败；已恢复先前后端：$previous" >&2
    return 1
  fi
  save_warp_backend "$backend"
  green "WARP 后端已切换为 $backend：127.0.0.1:${WARP_PROXY_PORT}。"
  yellow "尚未改变 Xray 出站；请在 WARP 菜单中选择分流策略。"
}

warp_trace() {
  local backend command trace
  backend=$(active_warp_backend)
  [[ $backend != none ]] || { red "WARP 后端尚未安装。" >&2; return 1; }
  command=$(warp_backend_bin "$backend")
  [[ -x $command ]] || { red "WARP 后端命令缺失：$backend" >&2; return 1; }
  verify_component "$backend" "$command" || return 1
  "$command" test "$WARP_PROXY_PORT" >/dev/null || return 1
  trace=$(curl --fail --silent --show-error --max-time 15 --proxy "socks5h://127.0.0.1:${WARP_PROXY_PORT}" \
    https://www.cloudflare.com/cdn-cgi/trace) || { red "无法通过 WARP 本机代理联网。" >&2; return 1; }
  grep -q '^warp=on$' <<<"$trace" || { red "Cloudflare 未确认 WARP 已连接。" >&2; return 1; }
  printf '%s\n' "$trace" | awk -F= '/^(ip|loc|warp)=/{printf "%s: %s\n", $1, $2}'
}

normalize_warp_domains() {
  local input=$1 token normalized='' prefix value
  local -a tokens
  IFS=',' read -r -a tokens <<<"$input"
  for token in "${tokens[@]}"; do
    token=${token//[[:space:]]/}
    [[ -n $token ]] || continue
    if [[ $token == *:* ]]; then prefix=${token%%:*}; value=${token#*:}; else prefix=domain; value=$token; fi
    [[ $prefix == domain || $prefix == full || $prefix == geosite ]] || die "不支持的 WARP 域名规则：$token"
    if [[ $prefix == geosite ]]; then
      [[ $value =~ ^[A-Za-z0-9_-]+$ ]] || die "无效的 geosite 规则：$token"
    else
      valid_server_name "$value" || die "无效的域名规则：$token"
    fi
    normalized+="${normalized:+,}${prefix}:${value}"
  done
  [[ -n $normalized ]] || die "至少需要一个有效域名。"
  printf '%s' "$normalized"
}

set_warp_policy() {
  local mode=$1 domains=${2:-} strategy=UseIPv4v6
  [[ -x $XRAY_BIN && -r $CONFIG_FILE ]] || die "请先安装 Xray。"
  warp_trace >/dev/null || return 1
  [[ $mode == selective || $mode == all ]] || die "WARP 策略模式无效。"
  [[ $mode == all ]] || domains=$(normalize_warp_domains "$domains")
  if [[ -r $WARP_STATE_FILE ]]; then
    WARP_IP_STRATEGY=UseIPv4v6
    # shellcheck disable=SC1090
    load_state_file "$WARP_STATE_FILE"
    strategy=${WARP_IP_STRATEGY:-UseIPv4v6}
  fi
  create_backup
  cat > "$WARP_STATE_FILE" <<EOF
WARP_MODE=${mode}
WARP_DOMAINS=$(printf %q "$domains")
WARP_IP_STRATEGY=${strategy}
EOF
  chmod 600 "$WARP_STATE_FILE"
  rebuild_or_restore
  restart_or_rollback
  if [[ $mode == all ]]; then
    green "全部协议的公网 TCP 流量已统一通过 WARP；UDP 使用直连；本机及私有目标默认拒绝。"
  else
    green "全部协议已统一应用 WARP 域名分流：$domains"
  fi
}

disable_warp_policy() {
  [[ -x $XRAY_BIN && -r $CONFIG_FILE ]] || die "请先安装 Xray。"
  [[ -f $WARP_STATE_FILE ]] || { yellow "Xray 当前没有启用 WARP 策略；此命令不停止已安装的 WARP 后端。"; return; }
  create_backup
  rm -f -- "$WARP_STATE_FILE"
  rebuild_or_restore
  restart_or_rollback
  green "全部协议已恢复使用服务器原生出口。"
  yellow '仅关闭 Xray WARP 分流；当前 WARP 后端仍可运行。'
}

show_warp_status() {
  local backend command
  backend=$(active_warp_backend)
  printf 'WARP 后端：%s\n' "$backend"
  if [[ $backend != none ]]; then
    command=$(warp_backend_bin "$backend")
    if [[ -x $command ]]; then
      verify_component "$backend" "$command" || return 1
      "$command" status || yellow "WARP 后端状态检查失败：$backend"
    else
      yellow "WARP 后端命令缺失：$backend"
    fi
  else
    yellow "WARP 后端尚未安装。"
  fi
  if [[ -r $WARP_STATE_FILE ]]; then
    WARP_MODE=off; WARP_DOMAINS=''; WARP_IP_STRATEGY=UseIPv4v6
    # shellcheck disable=SC1090
    load_state_file "$WARP_STATE_FILE"
    printf 'Xray WARP 策略：%s\n' "$WARP_MODE"
    printf '目标地址策略：%s\n' "${WARP_IP_STRATEGY:-UseIPv4v6}"
    [[ -z ${WARP_DOMAINS:-} ]] || printf '分流规则：%s\n' "$WARP_DOMAINS"
  else
    printf '%s\n' 'Xray WARP 策略：off'
  fi
}

set_warp_ip_strategy() {
  local strategy=$1
  [[ -r $WARP_STATE_FILE ]] || die "请先启用一种 Xray WARP 策略。"
  [[ $strategy == UseIPv4v6 || $strategy == UseIPv4 || $strategy == UseIPv6 ]] || die "WARP IP 策略无效。"
  WARP_MODE=off; WARP_DOMAINS=''
  # shellcheck disable=SC1090
  load_state_file "$WARP_STATE_FILE"
  create_backup
  cat > "$WARP_STATE_FILE" <<EOF
WARP_MODE=${WARP_MODE}
WARP_DOMAINS=$(printf %q "${WARP_DOMAINS:-}")
WARP_IP_STRATEGY=${strategy}
EOF
  chmod 600 "$WARP_STATE_FILE"
  rebuild_or_restore
  restart_or_rollback
  green "全部协议的 WARP 目标地址策略已设置为：$strategy"
}

warp_ip_strategy_menu() {
  local choice
  printf '\n'
  ui_box_title 'WARP IPv4 / IPv6 出站策略'
  ui_menu_item '1) 自动双栈（IPv4 优先，失败后尝试 IPv6）'
  ui_menu_item '2) 仅 IPv4'
  ui_menu_item '3) 仅 IPv6'
  ui_box_divider
  ui_menu_item '0) 返回'
  ui_box_bottom
  read -r -p '请选择 [0-3]：' choice
  case "$choice" in
    1) run_mutation set_warp_ip_strategy UseIPv4v6 ;;
    2) run_mutation set_warp_ip_strategy UseIPv4 ;;
    3) run_mutation set_warp_ip_strategy UseIPv6 ;;
    0) return ;;
    *) yellow "无效选择。" ;;
  esac
}

check_warp_endpoint() {
  local name=$1 url=$2 code
  code=$(curl --silent --show-error --max-time 15 --proxy "socks5h://127.0.0.1:${WARP_PROXY_PORT}" \
    --output /dev/null --write-out '%{http_code}' "$url" 2>/dev/null || true)
  if [[ $code =~ ^(200|204|301|302|307|308)$ ]]; then
    green "[可访问] $name（HTTP $code）"
  elif [[ -n $code && $code != 000 ]]; then
    yellow "[受限或需进一步确认] $name（HTTP $code）"
  else
    red "[连接失败] $name"
  fi
}

check_warp_services() {
  warp_trace
  check_warp_endpoint 'Netflix' 'https://www.netflix.com/title/81280792'
  check_warp_endpoint 'Disney+' 'https://www.disneyplus.com/'
  check_warp_endpoint 'ChatGPT' 'https://chatgpt.com/'
  yellow "HTTP 可访问不等于账号地区或完整流媒体版权解锁；检测结果只反映当前 WARP 出口。"
}

repair_warp() {
  local backend command
  backend=$(active_warp_backend)
  [[ $backend != none ]] || die "WARP 后端尚未安装。"
  install_warp_backend_command "$backend"
  command=$(warp_backend_bin "$backend")
  "$command" repair "$WARP_PROXY_PORT" || die "WARP $backend 后端修复失败。"
  if [[ -r $CONFIG_FILE ]]; then
    create_backup
    rebuild_or_restore
    restart_or_rollback
  fi
  green "WARP 本机代理和 Xray 出站配置已修复并重新校验。"
}

uninstall_warp() {
  local backend=${1:-} command
  [[ -n $backend ]] || backend=$(active_warp_backend)
  valid_warp_backend "$backend" || die '没有可卸载的 WARP 后端。'
  if [[ -f $WARP_STATE_FILE ]]; then
    disable_warp_policy
  fi
  command=$(warp_backend_bin "$backend")
  if [[ -x $command ]]; then
    verify_component "$backend" "$command" || return 1
    "$command" uninstall || true
  fi
  rm -f -- "$command" "$WARP_BACKEND_STATE_FILE"
  green "WARP $backend 后端及 Xray WARP 策略已移除。"
}

warp_backend_menu() {
  local choice
  printf '\n'
  ui_box_title '选择 WARP 后端'
  ui_menu_item '1) WireGuard / WireProxy（推荐，兼容受限机房）'
  ui_menu_item '2) MASQUE / Cloudflare 官方 Local Proxy'
  ui_box_divider
  ui_menu_item '0) 返回'
  ui_box_bottom
  read -r -p '请选择 [0-2]：' choice
  case "$choice" in
    1) run_mutation install_warp wireguard || true ;;
    2) run_mutation install_warp masque || true ;;
    0) return ;;
    *) yellow '无效选择。' ;;
  esac
}

warp_menu() {
  local choice domains answer
  while :; do
    printf '\n'
    ui_box_title 'WARP 出站管理（对全部协议生效）'
    ui_menu_item '1) 安装/切换 WARP 后端'
    ui_menu_item '2) 查看 WARP 状态与出口 IP'
    ui_menu_item '3) 全部协议的公网 TCP 使用 WARP'
    ui_menu_item '4) 指定域名使用 WARP（推荐）'
    ui_menu_item '5) IPv4 / IPv6 出站策略'
    ui_menu_item '6) 流媒体与 ChatGPT 可用性检测'
    ui_menu_item '7) 停用 WARP 策略'
    ui_menu_item '8) 修复/重新生成配置'
    ui_menu_item '9) 卸载 WARP'
    ui_box_divider
    ui_menu_item '0) 返回主菜单'
    ui_box_bottom
    read -r -p '请选择 [0-9]：' choice
    case "$choice" in
      1) warp_backend_menu; pause ;;
      2) show_warp_status; (warp_trace) || true; pause ;;
      3)
        read -r -p '确认让全部协议的公网 TCP 流量通过 WARP？[y/N] ' answer
        if [[ ${answer,,} == y || ${answer,,} == yes ]]; then (run_mutation set_warp_policy all) || true; fi
        pause
        ;;
      4)
        read -r -p '域名规则，逗号分隔 [geosite:netflix,domain:openai.com,domain:chatgpt.com]：' domains
        (run_mutation set_warp_policy selective "${domains:-geosite:netflix,domain:openai.com,domain:chatgpt.com}") || true
        pause
        ;;
      5) (warp_ip_strategy_menu) || true; pause ;;
      6) (check_warp_services) || true; pause ;;
      7) run_mutation disable_warp_policy || true; pause ;;
      8) run_mutation repair_warp || true; pause ;;
      9)
        read -r -p '确认卸载 WARP 并恢复原生出口？[y/N] ' answer
        if [[ ${answer,,} == y || ${answer,,} == yes ]]; then run_mutation uninstall_warp || true; fi
        pause
        ;;
      0) return ;;
      *) yellow "无效选择。"; pause ;;
    esac
  done
}

warp_command() {
  local action=${1:-menu} backend command
  case "$action" in
    menu) warp_menu ;;
    install|switch)
      [[ ${2:-} == wireguard || ${2:-} == masque ]] || die "用法：v2ray warp $action <wireguard|masque>"
      run_mutation install_warp "$2"
      ;;
    status) show_warp_status ;;
    test) warp_trace ;;
    diagnose)
      backend=$(active_warp_backend)
      command=$(warp_backend_bin "$backend" 2>/dev/null || true)
      if [[ -x $command ]]; then
        verify_component "$backend" "$command" || return 1
        "$command" diagnose 2>/dev/null || "$command" status || true
      else yellow 'WARP 后端尚未安装。'; fi
      ;;
    check) check_warp_services ;;
    repair) run_mutation repair_warp ;;
    ipv4) run_mutation set_warp_ip_strategy UseIPv4 ;;
    ipv6) run_mutation set_warp_ip_strategy UseIPv6 ;;
    dual) run_mutation set_warp_ip_strategy UseIPv4v6 ;;
    selective) [[ -n ${2:-} ]] || die "用法：v2ray warp selective <逗号分隔的域名规则>"; run_mutation set_warp_policy selective "$2" ;;
    all) run_mutation set_warp_policy all ;;
    off) run_mutation disable_warp_policy ;;
    uninstall) run_mutation uninstall_warp "${2:-}" ;;
    *) die "未知 WARP 操作：$action" ;;
  esac
}

# Machine-readable local checks deliberately do not probe third-party websites.
# Configuration/key contents and raw process output never enter this report.
doctor_report() (
  local core=missing config=invalid service=unknown state=invalid transaction=clear listeners='[]'
  local port transport listening result output failures
  command -v jq >/dev/null || { red '结构化诊断需要 jq。' >&2; return 2; }
  [[ ! -x $XRAY_BIN ]] || core=present
  if [[ -r $CONFIG_FILE ]] && jq -e 'type == "object" and (.inbounds | type == "array")' "$CONFIG_FILE" >/dev/null 2>&1; then
    if [[ $core == present ]] && XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_BIN" run -test -config "$CONFIG_FILE" >/dev/null 2>&1; then config=valid; fi
  fi
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then service=active; else service=inactive; fi
  fi
  if check_state_schema >/dev/null 2>&1; then
    if [[ -r $STATE_FILE ]]; then state=valid; else state=missing; fi
  fi
  [[ ! -e $BACKUP_DIR/manager.pending ]] || transaction=pending
  if [[ $config == valid ]]; then
    while IFS=$'\t' read -r port transport; do
      listening=unknown
      if command -v ss >/dev/null 2>&1; then
        if [[ $transport == udp ]]; then output=$(ss -H -lnu "sport = :$port" 2>/dev/null) && listening=absent
        else output=$(ss -H -lnt "sport = :$port" 2>/dev/null) && listening=absent; fi
        if [[ $listening != unknown && -n $output ]]; then listening=present; fi
      fi
      listeners=$(jq -cn --argjson current "$listeners" --argjson port "$port" --arg transport "$transport" --arg status "$listening" \
        '$current + [{port:$port,transport:$transport,status:$status}]') || return 2
    done < <(jq -r '.inbounds[] | [.port, (if .protocol == "hysteria" then "udp" else "tcp" end)] | @tsv' "$CONFIG_FILE")
  fi
  for node_file in "$NODES_DIR"/*.env; do
    [[ -f $node_file ]] || continue
    EXTRA_UUIDS=''; load_state_file "$node_file" || return 2
    [[ $PROFILE == hysteria-tls-quic ]] || continue
    listening=unknown
    if command -v ss >/dev/null 2>&1; then
      output=$(ss -H -lnu "sport = :$PORT" 2>/dev/null) && listening=absent
      [[ $listening == unknown || -z $output ]] || listening=present
    fi
    listeners=$(jq -cn --argjson current "$listeners" --argjson port "$PORT" --arg status "$listening" \
      '$current + [{port:$port,transport:"udp",status:$status}]') || return 2
  done
  result=$(jq -n --arg core "$core" --arg config "$config" --arg service "$service" --arg state "$state" \
    --arg transaction "$transaction" --argjson listeners "$listeners" '{
      schema_version:1, scope:"local", checks:{core:$core,config:$config,service:$service,state:$state,transaction:$transaction},
      listeners:$listeners, local_handshake:"not_checked", public_reachability:"not_checked",
      failures: (([$core != "present", $config != "valid", $service == "inactive", $state != "valid", $transaction == "pending"] | map(select(.)) | length)
        + ([$listeners[] | select(.status == "absent")] | length)),
      unknowns: (([$service == "unknown"] | map(select(.)) | length) + ([$listeners[] | select(.status == "unknown")] | length))
    } | .status = (if .failures > 0 then "failed" elif .unknowns > 0 then "incomplete" else "passed" end)') || return 2
  printf '%s\n' "$result"
  failures=$(jq -r '.failures' <<< "$result")
  (( failures == 0 )) || return 1
  [[ $(jq -r '.status' <<< "$result") != incomplete ]] || return 2
)

doctor_metrics() {
  local report status=0
  report=$(doctor_report) || status=$?
  [[ -n $report ]] || return "$status"
  jq -r '"# HELP v2ray_manager_local_check_success Local checks passed; does not establish public connectivity.",
    "# TYPE v2ray_manager_local_check_success gauge",
    ("v2ray_manager_local_check_success " + (if .status == "passed" then "1" else "0" end)),
    "# TYPE v2ray_manager_check_failures gauge", ("v2ray_manager_check_failures " + (.failures|tostring)),
    "# TYPE v2ray_manager_checks_unknown gauge", ("v2ray_manager_checks_unknown " + (.unknowns|tostring))' <<< "$report"
  return "$status"
}

doctor_command() {
  case "${1:-}" in
    '') doctor ;;
    --json) doctor_report ;;
    --prometheus) doctor_metrics ;;
    *) die '用法：v2ray doctor [--json|--prometheus]' ;;
  esac
}

set_xhttp_mode() {
  local node=${1:-} mode=${2:-}
  valid_xhttp_mode "$mode" || die 'XHTTP 模式必须为 auto、packet-up 或 stream-up。'
  load_edit_node "$node"
  [[ $PROFILE == *-xhttp ]] || die '该入站没有使用 XHTTP。'
  XHTTP_MODE=$mode
  write_config "$EDIT_NODE_FILE"
  restart_or_rollback
  green 'XHTTP 客户端预设已更新，请重新导出客户端配置。'
}

plan_desired() (
  local file=${1:-} spec id source current next changes='[]' address mode
  local ADDRESS='' PROFILE='' REMARK='' XHTTP_MODE=auto
  [[ -r $file ]] || { red '需要可读的声明式 JSON 文件。' >&2; return 1; }
  jq -e 'type == "object" and .schema_version == 1 and ((keys - ["schema_version","nodes"]) | length == 0)
    and (.nodes | type == "array" and length > 0 and length <= 1000)
    and (([.nodes[].id] | unique | length) == (.nodes|length))
    and all(.nodes[]; type == "object" and ((keys - ["id","enabled","address","remark","xhttp_mode"])|length == 0)
      and (.id|type == "string") and (.enabled|type == "boolean")
      and (if has("address") then (.address|type == "string") else true end)
      and (if has("remark") then (.remark|type == "string" and length <= 128) else true end)
      and (if has("xhttp_mode") then (.xhttp_mode|type == "string") else true end))' "$file" >/dev/null || return 1
  while IFS= read -r spec; do
    id=$(jq -r '.id' <<< "$spec") || return 1
    valid_node_id "$id" || return 1
    source="$NODES_DIR/$id.env"
    [[ -f $source ]] || source="$NODES_DIR/$id.disabled"
    [[ -f $source ]] || { red "未知入站：$id" >&2; return 1; }
    load_state_file "$source" || return 1
    address=$(jq -r --arg current "${ADDRESS:-}" '.address // $current' <<< "$spec")
    valid_server_name "$address" || return 1
    mode=$(jq -r --arg current "${XHTTP_MODE:-auto}" '.xhttp_mode // $current' <<< "$spec")
    valid_xhttp_mode "$mode" || return 1
    if jq -e 'has("xhttp_mode")' <<< "$spec" >/dev/null; then [[ $PROFILE == *-xhttp ]] || return 1; fi
    current=$(jq -cn --arg address "${ADDRESS:-}" --arg remark "${REMARK:-}" --arg mode "${XHTTP_MODE:-auto}" \
      --argjson enabled "$(if [[ $source == *.disabled ]]; then printf false; else printf true; fi)" \
      '{enabled:$enabled,address:$address,remark:$remark,xhttp_mode:$mode}') || return 1
    next=$(jq -cn --argjson current "$current" --argjson spec "$spec" '$current + ($spec | del(.id))') || return 1
    changes=$(jq -cn --argjson changes "$changes" --arg id "$id" --argjson before "$current" --argjson after "$next" \
      '$changes + [{id:$id,before:$before,after:$after,changed:($before != $after)}]') || return 1
  done < <(jq -c '.nodes[]' "$file")
  jq -n --argjson changes "$changes" '{schema_version:1,scope:"existing_nodes",changes:$changes,restart_required:any($changes[];.changed)}'
)

apply_desired() (
  umask 077
  local file=${1:-} staged report spec id source destination
  staged=$(mktemp) || return 1
  trap 'rm -f -- "$staged"' EXIT
  cp -- "$file" "$staged" || return 1
  report=$(plan_desired "$staged") || return 1
  if ! jq -e '.restart_required' <<< "$report" >/dev/null; then printf '%s\n' "$report"; return 0; fi
  create_backup
  while IFS= read -r spec; do
    id=$(jq -r '.id' <<< "$spec")
    source="$NODES_DIR/$id.env"; [[ -f $source ]] || source="$NODES_DIR/$id.disabled"
    load_state_file "$source" || return 1
    ADDRESS=$(jq -r '.after.address' <<< "$spec")
    REMARK=$(jq -r '.after.remark' <<< "$spec")
    XHTTP_MODE=$(jq -r '.after.xhttp_mode' <<< "$spec")
    if jq -e '.after.enabled' <<< "$spec" >/dev/null; then destination="$NODES_DIR/$id.env"; else destination="$NODES_DIR/$id.disabled"; fi
    save_current_node "$destination" || return 1
    [[ $source == "$destination" ]] || rm -f -- "$source" || return 1
  done < <(jq -c '.changes[] | select(.changed)' <<< "$report")
  rebuild_config_from_nodes || return 1
  restart_or_rollback || return 1
  printf '%s\n' "$report"
)

doctor() {
  local failures=0 port security target transport flags node_file node_count=0 fallback route_status
  printf '%s\n' "===== v2ray-manager 诊断 ====="

  if [[ -x "$XRAY_BIN" ]]; then green "[通过] Xray Core 可执行文件"; else red "[失败] 缺少 Xray Core"; ((failures+=1)); fi
  if [[ -r "$CONFIG_FILE" ]]; then green "[通过] 配置文件可读"; else red "[失败] 配置文件不可读"; ((failures+=1)); fi
  if [[ -r "$STATE_FILE" ]]; then green "[通过] 管理状态可读"; else red "[失败] 管理状态不可读"; ((failures+=1)); fi

  if [[ -x "$XRAY_BIN" && -r "$CONFIG_FILE" ]] && XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_BIN" run -test -config "$CONFIG_FILE" >/dev/null 2>&1; then
    green "[通过] Xray 配置校验"
  else
    red "[失败] Xray 配置校验"
    ((failures+=1))
  fi
  if systemctl is-active --quiet "$SERVICE_NAME"; then green "[通过] xray.service 正在运行"; else red "[失败] xray.service 未运行"; ((failures+=1)); fi

  if systemctl is-active --quiet caddy; then
    if check_caddy_renewal_compatibility; then
      green "[通过] 未发现 Caddy 与 Certbot standalone 的端口冲突配置"
    else
      ((failures+=1))
    fi
  fi

  if [[ -r $WARP_STATE_FILE ]]; then
    if warp_proxy_ready; then
      green "[通过] Xray WARP 策略所需的本机 SOCKS 代理正在监听 127.0.0.1:${WARP_PROXY_PORT}"
    else
      red "[失败] Xray 已启用 WARP 策略，但当前后端或 127.0.0.1:${WARP_PROXY_PORT} 不可用"
      yellow "运行 v2ray warp repair 检查 WARP 上游；若不再需要 WARP，请运行 v2ray warp off。"
      ((failures+=1))
    fi
  fi

  if [[ -r $CONFIG_FILE ]]; then
    while IFS=$'\t' read -r port security target transport; do
      flags=-lnt; [[ $transport != udp ]] || flags=-lnu
      if ss -H "$flags" "sport = :$port" | grep -q .; then
        green "[通过] ${transport^^} $port 正在监听"
      else
        red "[失败] ${transport^^} $port 未监听"; ((failures+=1))
      fi
      if [[ $security == reality ]]; then
        if getent ahosts "$target" >/dev/null 2>&1; then
          green "[通过] TCP $port 的 REALITY 目标可解析"
        else
          red "[失败] TCP $port 的 REALITY 目标无法解析"; ((failures+=1)); continue
        fi
        if command -v openssl >/dev/null && command -v timeout >/dev/null; then
          if check_reality_target "$target"; then
            green "[通过] TCP $port 的 REALITY 目标满足 TLS 1.3、H2、证书和 SNI 条件"
          else
            red "[失败] TCP $port 的 REALITY 目标不满足 TLS 1.3/H2/证书/SNI 条件"; ((failures+=1))
          fi
          fallback=$(timeout 12 openssl s_client -connect "127.0.0.1:$port" -servername "$target" \
            -verify_hostname "$target" -tls1_3 -groups X25519 -alpn h2 </dev/null 2>&1 || true)
          if [[ $fallback == *'ALPN protocol: h2'* && $fallback == *'Verify return code: 0 (ok)'* ]]; then
            green "[通过] TCP $port 的 REALITY 未认证回落链路可用"
          else
            red "[失败] TCP $port 的 REALITY 回落链路无法完成目标站 TLS 握手"; ((failures+=1))
          fi
        else
          yellow "[未检查] 缺少 openssl/timeout，无法验证 REALITY 目标握手。"
        fi
      fi
    done < <(jq -r '.inbounds[] | [(.port|tostring), (.streamSettings.security // "none"), (.streamSettings.realitySettings.serverNames[0] // "-"), (if .protocol == "hysteria" then "udp" else "tcp" end)] | @tsv' "$CONFIG_FILE")
  fi

  for node_file in "$NODES_DIR"/*.env; do
    [[ -f $node_file ]] || continue
    EXTRA_UUIDS=''; load_state_file "$node_file" || continue
    [[ $PROFILE == hysteria-tls-quic ]] || continue
    if systemctl is-active --quiet "hysteria-v2ray-manager@$(basename "$node_file" .env).service" && \
      ss -H -lnu "sport = :$PORT" | grep -q .; then
      green "[通过] 官方 Hysteria2 服务正在监听 UDP $PORT"
    else
      red "[失败] 官方 Hysteria2 服务未运行或 UDP $PORT 未监听"; ((failures+=1))
    fi
  done

  for node_file in "$NODES_DIR"/*.env; do
    [[ -f $node_file ]] || continue
    ((node_count+=1))
    if (
      # shellcheck disable=SC1090
      EXTRA_UUIDS=''
      # shellcheck disable=SC1090
      load_state_file "$node_file"
      show_connection_loaded "$CONFIG_FILE" >/dev/null || exit 1
      if profile_requires_xray_tls && ! tls_chain_valid "$(tls_cert_path)"; then
        red "TLS 证书链未通过本机系统 CA 信任校验；检查完整链或客户端自建 CA 配置。" >&2
        exit 1
      fi
    ); then
      green "[通过] 入站 $(basename "$node_file" .env) 的导出参数与配置一致"
    else
      red "[失败] 入站 $(basename "$node_file" .env) 的链接参数或入口地址"; ((failures+=1))
    fi
    if (
      # shellcheck disable=SC1090
      load_state_file "$node_file"
      profile_supports_caddy_route || exit 3
      if profile_uses_managed_caddy_route; then
        systemctl is-active --quiet caddy || exit 4
        exit 0
      fi
      [[ $PROFILE != vless-tls-xhttp ]] && exit 2
      exit 1
    ); then
      green "[通过] 入站 $(basename "$node_file" .env) 的公网入口为 Caddy TCP 443，域名、Path 与后端端口匹配"
    else
      route_status=$?
      case "$route_status" in
        1) red "[失败] 入站 $(basename "$node_file" .env) 必须通过 Caddy 公开，但未找到匹配的域名、Path 和后端端口"; ((failures+=1)) ;;
        2) yellow "[提示] 入站 $(basename "$node_file" .env) 未使用受管 Caddy 路由，客户端将直连其监听端口。" ;;
        3) : ;;
        4) red "[失败] 入站 $(basename "$node_file" .env) 使用 Caddy TCP 443，但 caddy.service 未运行"; ((failures+=1)) ;;
      esac
    fi
  done
  if (( node_count == 0 )); then
    yellow "[未检查] 没有启用的入站状态文件。"
  fi
  yellow "本机检查不能验证云安全组、NAT 端口映射或客户端兼容性；请从客户端网络测试相应的 TCP/UDP 端口。"

  if (( failures == 0 )); then
    green "诊断完成：已执行的本机检查未发现问题。"
    return 0
  fi
  red "诊断完成：发现 ${failures} 项问题。可运行 v2ray log 查看服务日志。"
  return 1
}

show_info() {
  load_state
  printf '作者：%s\n' "$AUTHOR"
  printf '管理器版本：%s\n' "$MANAGER_VERSION"
  printf '内核版本：%s\n' "$(command_version_line "$XRAY_BIN" '不可用')"
  show_connection
}

command_version_line() {
  local executable=$1 fallback=${2:-不可用} output
  [[ -x $executable ]] || { printf '%s\n' "$fallback"; return 0; }
  if ! output=$("$executable" version 2>/dev/null) || [[ -z $output ]]; then
    printf '%s\n' "$fallback"
    return 0
  fi
  printf '%s\n' "${output%%$'\n'*}"
}

xray_version_short() {
  local executable=$1 fallback=${2:-未安装} line
  line=$(command_version_line "$executable" "$fallback")
  if [[ $line =~ ^Xray[[:space:]]+([^[:space:]]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    printf '%s\n' "$line"
  fi
}

update_core() (
  set -Eeuo pipefail
  [[ -x "$XRAY_BIN" && -r "$CONFIG_FILE" ]] || die "尚未安装。"
  local transaction version_output changed=0 committed=0 was_active=0
  install_dependencies
  install -d -m 700 "$BACKUP_DIR"
  transaction=$(mktemp -d "$BACKUP_DIR/core-update.XXXXXX")
  # The EXIT trap covers failed copies and signals as well as failed restarts.
  trap 'finish_core_update "$?" "$transaction" "$changed" "$committed" "$was_active"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  systemctl is-active --quiet "$SERVICE_NAME" && was_active=1
  mkdir "$transaction/previous"
  cp -p "$XRAY_BIN" "$transaction/previous/xray"
  cp -p "$ASSET_DIR/geoip.dat" "$ASSET_DIR/geosite.dat" "$transaction/previous/"
  if [[ -n ${2:-} ]]; then
    mkdir "$transaction/core"
    cp -p -- "$2/xray" "$2/geoip.dat" "$2/geosite.dat" "$transaction/core/"
  else
    fetch_core "$transaction" "${1:-}"
  fi
  XRAY_LOCATION_ASSET="$transaction/core" "$transaction/core/xray" run -test -config "$CONFIG_FILE"
  changed=1
  install_core_files "$transaction/core"
  if (( was_active )); then
    restart_checked || die "新内核未通过健康检查，正在回退。"
  fi
  publish_manager_pointer "$BACKUP_DIR/core.rollback" "$transaction"
  committed=1
  green "Xray Core 已更新；原先停止的服务会保持停止。"
  version_output=$("$XRAY_BIN" version)
  printf '%s\n' "${version_output%%$'\n'*}"
)

# Called only by update_core's EXIT trap.
finish_core_update() {
  local status=$1 transaction_dir=$2 files_changed=$3 update_committed=$4 service_was_active=$5
  trap - EXIT INT TERM
  if (( files_changed && ! update_committed )); then
    if install_core_files "$transaction_dir/previous" && \
       { (( ! service_was_active )) || restart_checked; }; then
      yellow "已恢复升级前的 Xray Core 和 GeoData。"
    else
      red "自动回退未完成；旧文件保留在 $transaction_dir/previous，请运行 v2ray log。"
      exit 1
    fi
    status=1
  fi
  # Keep successful generations for an explicit rollback discovered after the
  # short startup observation. Failed candidates are disposable after recovery.
  if (( ! update_committed )); then rm -rf -- "$transaction_dir"; fi
  exit "$status"
}

rollback_core() {
  local id
  [[ -f $BACKUP_DIR/core.rollback ]] || die '没有可恢复的内核版本。'
  IFS= read -r id < "$BACKUP_DIR/core.rollback" || return 1
  [[ $id =~ ^core-update\.[A-Za-z0-9]+$ && -d $BACKUP_DIR/$id/previous && ! -L $BACKUP_DIR/$id ]] || die '内核回退记录无效。'
  update_core '' "$BACKUP_DIR/$id/previous"
}

validate_manager() {
  local script=$1
  bash -n "$script" &&
    grep -qx 'readonly APP_NAME="v2ray-manager"' "$script" &&
    grep -Eq '^readonly MANAGER_VERSION="[0-9]+\.[0-9]+\.[0-9]+"$' "$script"
}

write_data_schema_marker() (
  umask 077
  local state_file=$1 temporary
  temporary=$(mktemp "${state_file}.XXXXXX") || return 1
  trap 'rm -f -- "$temporary"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if [[ -f $state_file ]]; then
    state_to_json "$state_file" | jq --argjson schema "$DATA_SCHEMA_VERSION" '.DATA_SCHEMA=$schema' > "$temporary" || return 1
  else
    jq -n --argjson schema "$DATA_SCHEMA_VERSION" '{DATA_SCHEMA:$schema}' > "$temporary" || return 1
  fi
  mv -f -- "$temporary" "$state_file"
)
migrate_project_state() (
  local before after node_file credential domain upstream path has_tls_xhttp=0 was_active=0
  local migration_dir
  migration_dir=$(mktemp -d) || return 1
  trap 'rm -rf -- "$migration_dir"' EXIT
  local -a extra_credentials
  check_state_schema || return 1
  [[ -d $NODES_DIR ]] || { green "项目脚本已更新；当前没有需要迁移的入站状态。"; return 0; }
  if ! compgen -G "$NODES_DIR/*.env" >/dev/null && ! compgen -G "$NODES_DIR/*.disabled" >/dev/null; then
    green "项目脚本已更新；当前没有需要迁移的入站。"
    return 0
  fi
  [[ -r $CONFIG_FILE && -x $XRAY_BIN ]] || die "更新后迁移需要现有 Xray 配置和内核。"
  systemctl is-active --quiet "$SERVICE_NAME" && was_active=1
  cp "$CONFIG_FILE" "$migration_dir/before.json" || return 1
  before=$(migration_connection_fingerprint "$CONFIG_FILE")
  create_backup
  [[ -n ${LAST_BACKUP:-} ]] || die "无法创建更新前配置备份，已停止迁移。"

  for node_file in "$NODES_DIR"/*.env "$NODES_DIR"/*.disabled; do
    [[ -e $node_file ]] || continue
    DATA_SCHEMA=1
    EXTRA_UUIDS=''
    # Node files are generated by this script with mode 0600.
    # shellcheck disable=SC1090
    load_state_file "$node_file" || { restore_archive "$LAST_BACKUP"; die "无法读取入站状态，已恢复更新前配置。"; }
    [[ ${DATA_SCHEMA:-1} =~ ^[0-9]+$ ]] || {
      restore_archive "$LAST_BACKUP"
      die "入站数据版本无效，已恢复更新前配置。"
    }
    if ! valid_profile "$PROFILE" || ! valid_port "$PORT" || ! valid_uuid "$UUID"; then
      restore_archive "$LAST_BACKUP"
      die "入站状态未通过迁移校验，已恢复更新前配置。"
    fi
    [[ $PROFILE != vless-tls-xhttp ]] || has_tls_xhttp=1
    if [[ -n ${EXTRA_UUIDS:-} ]]; then
      IFS=',' read -r -a extra_credentials <<<"$EXTRA_UUIDS"
      (( ${#extra_credentials[@]} <= 9 )) || {
        restore_archive "$LAST_BACKUP"; die "入站链接数量超过上限，已恢复更新前配置。"
      }
      for credential in "${extra_credentials[@]}"; do
        valid_uuid "$credential" || {
          restore_archive "$LAST_BACKUP"; die "子链接凭据未通过迁移校验，已恢复更新前配置。"
        }
      done
    fi
    save_current_node "$node_file"
  done
  write_data_schema_marker "$STATE_FILE" || {
    restore_archive "$LAST_BACKUP"; die "状态版本写入失败，已恢复更新前配置。"
  }
  rebuild_config_from_nodes || {
    restore_archive "$LAST_BACKUP"; die "更新后配置重建失败，已恢复更新前配置。"
  }
  after=$(migration_connection_fingerprint "$CONFIG_FILE")
  if [[ $before != "$after" ]]; then
    restore_archive "$LAST_BACKUP"
    die "迁移导致连接参数发生非预期变化，已恢复原配置和原链接。"
  fi
  if (( was_active )); then
    restart_checked || {
      restore_archive "$LAST_BACKUP"
      restart_checked || true
      die "迁移后 Xray 启动失败，已恢复旧配置。"
    }
  fi
  if (( has_tls_xhttp )); then
    while IFS= read -r domain; do
      [[ -n $domain ]] || continue
      if command -v caddy >/dev/null 2>&1 && [[ -f $CADDY_SITE_DIR/$domain.caddy ]]; then
        IFS=$'\t' read -r upstream path < <(find_caddy_xray_defaults "$domain")
        if ! configure_caddy_site xray "$domain" "$upstream" "$path"; then
          die "迁移失败：$domain 的 Caddy 路由同步失败，正在恢复升级前配置。"
        fi
      else
        if jq -e 'any(.inbounds[]; .protocol == "vless" and .streamSettings.network == "xhttp" and .streamSettings.security == "tls")' "$migration_dir/before.json" >/dev/null; then
          die "迁移失败：$domain 缺少 Caddy 入口，不能移除现有 TLS 监听。"
        fi
        yellow "$domain 尚未配置 Caddy 入口；本次不改变其客户端参数。"
      fi
    done < <(for node_file in "$NODES_DIR"/*.env; do
      [[ -f $node_file ]] || continue
      PROFILE=''; SERVER_NAME=''
      # shellcheck disable=SC1090
      load_state_file "$node_file"
      [[ $PROFILE == vless-tls-xhttp ]] && printf '%s\n' "$SERVER_NAME"
    done | sort -u)
  fi
  rm -rf -- "$migration_dir"
  green "项目数据已迁移到版本 $DATA_SCHEMA_VERSION；已核验各入站连接参数。"
)

check_state_schema() {
  local state schema supported=${1:-$DATA_SCHEMA_VERSION}
  [[ $supported =~ ^[1-9][0-9]{0,5}$ ]] || { red '候选脚本未声明有效的数据结构版本。' >&2; return 1; }
  for state in "$STATE_FILE" "$NODES_DIR"/*.env "$NODES_DIR"/*.disabled; do
    [[ -f $state ]] || continue
    schema=$(state_schema "$state") || return 1
    schema=${schema:-1}
    [[ $schema =~ ^[1-9][0-9]{0,5}$ ]] || { red "数据版本无效：$state" >&2; return 1; }
    (( schema <= supported )) || { red "数据版本 $schema 高于目标脚本支持的 $supported，拒绝降级迁移。" >&2; return 1; }
  done
}

ensure_project_state_current() {
  local command_name=${1:-menu} node_file schema needs_migration=0
  [[ $command_name != migrate && $command_name != uninstall ]] || return 0
  check_state_schema || return 1
  for node_file in "$NODES_DIR"/*.env "$NODES_DIR"/*.disabled; do
    [[ -f $node_file ]] || continue
    schema=$(state_schema "$node_file")
    [[ ${schema:-1} == "$DATA_SCHEMA_VERSION" ]] || needs_migration=1
  done
  (( needs_migration )) || return 0
  yellow "检测到旧版项目数据，正在自动迁移并保护现有链接…"
  run_mutation migrate_project_state
}

manager_bundle_path() {
  case "$1" in
    manager) printf '%s\n' "$MANAGER_BIN" ;;
    config) printf '%s\n' "$CONFIG_DIR" ;;
    caddy-main) printf '%s\n' "$CADDY_CONFIG" ;;
    caddy-sites) printf '%s\n' "$CADDY_SITE_DIR" ;;
    service) printf '%s\n' "$SERVICE_FILE" ;;
    components) printf '%s\n' "$WARP_BACKEND_BIN_DIR" ;;
    hysteria-bin) printf '%s\n' "$HYSTERIA_BIN" ;;
    hysteria-config) printf '%s\n' "$HYSTERIA_CONFIG_DIR" ;;
    hysteria-service) printf '%s\n' "$HYSTERIA_SERVICE_TEMPLATE" ;;
    *) return 1 ;;
  esac
}

capture_manager_bundle() (
  set -Eeuo pipefail
  umask 077
  local bundle=$1 name path links xray_active=false caddy_active=false
  mkdir "$bundle/files" || return 1
  for name in manager config caddy-main caddy-sites service components hysteria-bin hysteria-config hysteria-service; do
    path=$(manager_bundle_path "$name") || return 1
    if [[ -e $path || -L $path ]]; then
      # cp -a would preserve references to mutable external files rather than
      # their state. Refuse that layout before journaling or replacing anything.
      links=$(find "$path" -type l -print -quit) || return 1
      [[ -z $links ]] || { red "关联快照暂不支持符号链接：$links；未修改现有安装。" >&2; return 1; }
      cp -a -- "$path" "$bundle/files/$name" || return 1
    fi
  done
  [[ -f $bundle/files/manager ]] || return 1
  systemctl is-active --quiet "$SERVICE_NAME" && xray_active=true
  systemctl is-active --quiet caddy && caddy_active=true
  jq -n --arg version "$MANAGER_VERSION" --argjson schema "$DATA_SCHEMA_VERSION" \
    --argjson xray "$xray_active" --argjson caddy "$caddy_active" \
    '{format:1,manager_version:$version,data_schema:$schema,xray_active:$xray,caddy_active:$caddy}' > "$bundle/metadata.json" || return 1
  # A saved coordinator remains usable even if the installed manager is older
  # and does not yet implement the recover command.
  cp -- "${BASH_SOURCE[0]}" "$bundle/recovery.sh" || return 1
  (cd "$bundle" && find files -type f -exec sha256sum {} + > checksums && sha256sum metadata.json recovery.sh >> checksums) || return 1
)

read_manager_pointer() {
  local id
  [[ -f $1 ]] || return 1
  IFS= read -r id < "$1" || return 1
  [[ $id =~ ^manager-transaction\.[A-Za-z0-9]+$ ]] || return 1
  [[ -d $BACKUP_DIR/$id && ! -L $BACKUP_DIR/$id ]] || return 1
  printf '%s\n' "$BACKUP_DIR/$id"
}

publish_manager_pointer() (
  local destination=$1 bundle=$2 temporary
  temporary=$(mktemp "$BACKUP_DIR/pointer.XXXXXX") || return 1
  trap 'rm -f -- "$temporary"' EXIT
  printf '%s\n' "${bundle##*/}" > "$temporary" || return 1
  atomic_install "$temporary" "$destination" 600
)

require_no_pending_manager() {
  [[ ! -e $BACKUP_DIR/manager.pending ]] || {
    red "存在未完成的管理脚本事务。先运行 v2ray recover；恢复入口位于 $BACKUP_DIR/manager-transaction.*/recovery.sh。" >&2
    return 1
  }
}

restore_manager_bundle() {
  local bundle=$1 name path xray_active caddy_active
  [[ -f $bundle/checksums && -f $bundle/metadata.json && -f $bundle/files/manager ]] || return 1
  (cd "$bundle" && sha256sum -c checksums >/dev/null) || return 1
  jq -e '.format == 1 and (.xray_active | type == "boolean") and (.caddy_active | type == "boolean")' "$bundle/metadata.json" >/dev/null || return 1
  validate_manager "$bundle/files/manager" || return 1
  xray_active=$(jq -r '.xray_active' "$bundle/metadata.json") || return 1
  caddy_active=$(jq -r '.caddy_active' "$bundle/metadata.json") || return 1
  # Restore directories exactly, including removal of post-upgrade nodes.
  # Manager replacement is last; the saved recovery entry survives partial I/O.
  systemctl stop 'hysteria-v2ray-manager@*.service' >/dev/null 2>&1 || true
  for name in config caddy-main caddy-sites service components hysteria-bin hysteria-config hysteria-service; do
    path=$(manager_bundle_path "$name") || return 1
    rm -rf -- "$path" || return 1
    if [[ -e $bundle/files/$name ]]; then
      mkdir -p -- "$(dirname "$path")" || return 1
      cp -a -- "$bundle/files/$name" "$path" || return 1
    fi
  done
  atomic_install "$bundle/files/manager" "$MANAGER_BIN" 755 || return 1
  systemctl daemon-reload || return 1
  if [[ -f $CONFIG_FILE ]]; then
    XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_BIN" run -test -config "$CONFIG_FILE" >/dev/null || return 1
  fi
  if [[ $xray_active == true ]]; then
    systemctl restart "$SERVICE_NAME" && service_healthy || return 1
  elif systemctl is-active --quiet "$SERVICE_NAME"; then systemctl stop "$SERVICE_NAME" || return 1; fi
  if [[ $xray_active == true && -d $bundle/files/hysteria-config ]]; then
    sync_hysteria_services || return 1
  fi
  if [[ $caddy_active == true ]]; then
    caddy validate --config "$CADDY_CONFIG" >/dev/null || return 1
    systemctl restart caddy || return 1
    systemctl is-active --quiet caddy || return 1
  elif systemctl is-active --quiet caddy; then systemctl stop caddy || return 1; fi
}

finish_manager_transaction() {
  local status=$1 bundle=$2 armed=$3 committed=$4
  trap - EXIT INT TERM
  if (( armed && ! committed )); then
    if restore_manager_bundle "$bundle"; then
      rm -f -- "$BACKUP_DIR/manager.pending" || exit 1
      yellow '操作失败，已恢复关联的管理脚本、数据、组件脚本和服务状态。' >&2
    else
      red "自动恢复未完成；保留现场。运行：bash $bundle/recovery.sh recover" >&2
    fi
    exit 1
  fi
  exit "$status"
}

recover_manager() {
  local bundle
  bundle=$(read_manager_pointer "$BACKUP_DIR/manager.pending") || die '没有有效的待恢复事务。'
  restore_manager_bundle "$bundle" || die "恢复未完成，快照保留在 $bundle。"
  rm -f -- "$BACKUP_DIR/manager.pending" || return 1
  green '已恢复中断操作之前的管理脚本与关联数据。'
}

update_manager() (
  set -Eeuo pipefail
  local temporary revision url candidate_schema bundle='' armed=0 committed=0
  temporary=$(mktemp)
  trap 'status=$?; rm -f -- "$temporary"; finish_manager_transaction "$status" "$bundle" "$armed" "$committed"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  require_no_pending_manager
  revision=${V2M_MANAGER_REF:-}
  if [[ -z $revision ]]; then
    revision=$(curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 \
      --max-time 60 "$MANAGER_API" | jq -r '.sha') || {
      red '无法取得 GitHub 提交，管理脚本尚未替换。若 curl 报 Could not resolve host，请先检查 DNS 和 IP 出站；此错误不能单独证明 WARP 故障。' >&2
      return 1
    }
  fi
  [[ $revision =~ ^[0-9a-f]{40}$ ]] || die "管理脚本版本必须是完整的 Git 提交 SHA。"
  url="${MANAGER_URL%/main/v2ray.sh}/$revision/v2ray.sh"
  green "下载管理脚本提交：$revision"
  download_file "$url" "$temporary"
  validate_manager "$temporary" || die "下载的管理脚本未通过语法或项目标识检查，未更新。"
  candidate_schema=$(awk -F '"' '/^readonly DATA_SCHEMA_VERSION="/{print $2; exit}' "$temporary")
  [[ -n $candidate_schema ]] || die '候选脚本缺少数据结构版本，拒绝覆盖现有安装。'
  check_state_schema "$candidate_schema"
  [[ -f $MANAGER_BIN ]] || die "找不到当前管理脚本。"
  install -d -m 700 "$BACKUP_DIR"
  bundle=$(mktemp -d "$BACKUP_DIR/manager-transaction.XXXXXX")
  capture_manager_bundle "$bundle"
  publish_manager_pointer "$BACKUP_DIR/manager.pending" "$bundle"
  armed=1
  # Kept for manual inspection only. Automated rollback requires the bundle.
  atomic_install "$MANAGER_BIN" "$BACKUP_DIR/manager.previous.sh" 700
  atomic_install "$temporary" "$MANAGER_BIN" 755
  V2M_INTERNAL_MIGRATION=1 "$MANAGER_BIN" migrate
  publish_manager_pointer "$BACKUP_DIR/manager.rollback" "$bundle"
  committed=1
  rm -f -- "$BACKUP_DIR/manager.pending"
  green "项目脚本与数据结构已更新。关联快照：$bundle；v2ray rollback.sh 将恢复该快照中的数据和服务状态。"
)

rollback_manager() (
  set -Eeuo pipefail
  local previous bundle='' armed=0 committed=0
  require_no_pending_manager
  previous=$(read_manager_pointer "$BACKUP_DIR/manager.rollback") || die '没有关联数据快照；拒绝仅恢复旧脚本。请保留当前数据并使用匹配版本。'
  bundle=$(mktemp -d "$BACKUP_DIR/manager-transaction.XXXXXX")
  trap 'finish_manager_transaction "$?" "$bundle" "$armed" "$committed"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  capture_manager_bundle "$bundle"
  publish_manager_pointer "$BACKUP_DIR/manager.pending" "$bundle"
  armed=1
  restore_manager_bundle "$previous"
  publish_manager_pointer "$BACKUP_DIR/manager.rollback" "$bundle"
  committed=1
  rm -f -- "$BACKUP_DIR/manager.pending"
  green "已恢复关联的脚本与数据。回退前状态保留在 $bundle。"
)

uninstall_xray() {
  read -r -p "将停止服务并删除 Xray 程序与 /etc/xray 配置。继续？[y/N] " answer
  [[ ${answer,,} == y || ${answer,,} == yes ]] || return
  systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
  systemctl disable --now 'hysteria-v2ray-manager@*.service' 2>/dev/null || true
  rm -f "$SERVICE_FILE" "$XRAY_BIN" "$MANAGER_BIN" "$HYSTERIA_BIN" "$HYSTERIA_SERVICE_TEMPLATE"
  rm -rf "$CONFIG_DIR" "$ASSET_DIR" "$HYSTERIA_CONFIG_DIR"
  if [[ -e "$LEGACY_MANAGER_BACKUP" ]]; then
    install -m 755 "$LEGACY_MANAGER_BACKUP" "$MANAGER_BIN"
    green "已恢复安装前的 v2ray 管理命令。"
  fi
  systemctl daemon-reload
  green "已卸载本脚本创建的 Xray 程序与配置。xray 系统账户和 $BACKUP_DIR 中的备份已保留。"
}

runtime_menu() {
  local choice
  while :; do
    printf '\n'
    ui_box_title 'Xray 服务管理'
    ui_menu_item '1) 启动服务'
    ui_menu_item '2) 停止服务'
    ui_menu_item '3) 重启服务'
    ui_menu_item '4) 查看状态'
    ui_menu_item '5) 查看日志'
    ui_box_divider
    ui_menu_item '0) 返回主菜单'
    ui_box_bottom
    read -r -p '请选择 [0-5]:' choice
    case "$choice" in
      1) run_mutation service_action start; pause ;; 2) run_mutation service_action stop; pause ;; 3) run_mutation service_action restart; pause ;;
      4) show_status; pause ;; 5) show_logs; pause ;; 0) return ;; *) yellow "无效选择。"; pause ;;
    esac
  done
}

maintenance_menu() {
  local choice
  while :; do
    printf '\n'
    ui_box_title '维护与诊断'
    ui_menu_item '1) 更新 Xray Core'
    ui_menu_item '2) 一键更新项目脚本并迁移数据'
    ui_menu_item '3) 运行综合诊断'
    ui_menu_item '4) 检查并放行本机防火墙'
    ui_menu_item '5) 备份配置'
    ui_menu_item '6) 恢复最近备份'
    ui_menu_item '7) 轮换 REALITY 密钥'
    ui_menu_item '8) 恢复上一版管理脚本及关联数据（撤销快照后修改）'
    ui_menu_item '9) 路由、丢包与延迟测试'
    ui_menu_item '10) 查看项目信息'
    ui_box_divider
    ui_menu_item '0) 返回主菜单'
    ui_box_bottom
    read -r -p '请选择 [0-10]:' choice
    case "$choice" in
      1) run_mutation update_core; pause ;; 2) run_mutation update_manager; pause ;; 3) doctor || true; pause ;;
      4) run_mutation open_enabled_inbound_ports; pause ;; 5) run_mutation manual_backup; pause ;; 6) run_mutation restore_latest; pause ;;
      7) run_mutation rotate_reality_keys; pause ;; 8) run_mutation rollback_manager; pause ;; 9) route_test_menu ;;
      10) show_about; pause ;; 0) return ;; *) yellow "无效选择。"; pause ;;
    esac
  done
}
show_help() {
  printf '%s\n' \
    '直接运行 v2ray 打开主菜单。' \
    'v2ray add      添加新入站' \
    'v2ray inbounds 查看入站列表' \
    'v2ray links    输出全部启用入站链接' \
    'v2ray users    打开子链接用户管理（查看、新增、删除、重新生成）' \
    'v2ray users list [入站ID] 查看协议分组或指定入站的链接用户' \
    'v2ray users add/delete/replace 管理指定入站的链接用户' \
    'v2ray link <入站ID> <CDN域名|cfip> 以 443 导出 TLS XHTTP/WS 链接' \
    'v2ray firewall 自动放行已启用入站的本机 UFW/firewalld 端口' \
    'v2ray speedtest 运行服务器网络测速' \
    'v2ray route [目标IP/域名] 测试回程路由、丢包和延迟' \
    'v2ray caddy    管理 Caddy 伪装网站和本机反向代理' \
    'v2ray cfip     管理独立 Cloudflare 优选 IP 分支项目' \
    'v2ray warp     管理全部协议共用的 WARP 出站策略' \
    'v2ray upgrade  一键更新项目脚本、迁移数据并保留现有链接' \
    'v2ray update.core [--version <vX.Y.Z> | --latest] [--check] 默认固定基线，可指定版本' \
    'v2ray versions 查看当前内核与上游最新版本' \
    'v2ray rollback.core 恢复上次内核和 GeoData（先校验当前配置）' \
    'v2ray rollback.sh 恢复上一关联快照（包含数据，会撤销快照后的配置修改）' \
    'v2ray recover 恢复中断的管理脚本事务' \
    'v2ray doctor [--json|--prometheus] 本机诊断或导出监控指标' \
    'v2ray plan <文件.json> 预览已有入站的声明式变更' \
    'v2ray apply <文件.json> 在事务中应用声明式变更' \
    'v2ray xhttp-mode <入站ID> <auto|packet-up|stream-up> 设置客户端模式' \
    'v2ray help     查看完整命令用法'
}

show_about() {
  printf '\n%s\n' "----------- ${APP_NAME} -----------"
  printf '作者: %s\n版本: %s\n内核: %s\n协议: VLESS + REALITY/TLS + RAW/XHTTP/gRPC/WebSocket\n仓库: https://github.com/0157Martin/v2ray-manager\n\n' \
    "$AUTHOR" "$MANAGER_VERSION" "$(command_version_line "$XRAY_BIN" '未安装')"
}

menu() {
  while :; do
    clear || true
    local core_version service_state caddy_state active_nodes disabled_nodes install_label
    core_version=$(xray_version_short "$XRAY_BIN" '未安装')
    if systemctl is-active --quiet "$SERVICE_NAME"; then service_state='running'; else service_state='stopped'; fi
    if systemctl is-active --quiet caddy; then caddy_state='running'; else caddy_state='stopped'; fi
    if [[ -d $NODES_DIR ]]; then
      active_nodes=$(find "$NODES_DIR" -maxdepth 1 -type f -name '*.env' | wc -l)
      disabled_nodes=$(find "$NODES_DIR" -maxdepth 1 -type f -name '*.disabled' | wc -l)
    else
      active_nodes=0
      disabled_nodes=0
    fi
    if [[ -x $XRAY_BIN ]]; then install_label='检查/修复 Xray（保留现有入站）'; else install_label='安装 Xray Core（稍后手动添加协议）'; fi
    ui_box_title "${APP_NAME}  v${MANAGER_VERSION}  ·  通用 Xray 管理器  ·  by ${AUTHOR}"
    printf '\033[38;5;39m│\033[0m  Xray: %s\n' "$core_version"
    printf '\033[38;5;39m│\033[0m  服务状态: '
    if [[ $service_state == running ]]; then green "$service_state"; else red "$service_state"; fi
    printf '\033[38;5;39m│\033[0m  Caddy: %s  ·  入站：%s 启用 / %s 停用\n' "$caddy_state" "$active_nodes" "$disabled_nodes"
    ui_box_divider
    ui_menu_item "1) $install_label"
    ui_menu_item '2) 入站管理'
    ui_menu_item '3) 连接与导出'
    ui_menu_item '4) Xray 服务管理'
    ui_menu_item '5) Caddy 网站管理'
    ui_menu_item '6) WARP 出站管理（全部协议）'
    ui_menu_item '7) 维护与诊断'
    ui_menu_item '8) 卸载项目'
    ui_box_divider
    ui_menu_item '0) 退出'
    ui_box_bottom
    read -r -p '请选择 [0-8]：' choice
    case "$choice" in
      1) run_mutation install_xray; pause ;;
      2) manage_inbounds_menu ;;
      3) export_menu ;;
      4) runtime_menu ;;
      5) caddy_menu ;;
      6) warp_menu ;;
      7) maintenance_menu ;;
      8) run_mutation uninstall_xray; pause ;;
      0) exit 0 ;;
      *) yellow "无效选择。"; pause ;;
    esac
  done
}

main() {
  require_root
  if [[ ${1:-} == __mutation ]]; then shift; mutation_entry "$@"; return; fi
  # Read-only commands must not trigger migration. All mutations validate state
  # after taking the lock; rollback/recovery must remain usable with newer data.
  case "${1:-menu}" in
    menu) menu ;;
    install) run_mutation install_xray ;;
    add) run_mutation add_inbound ;;
    inbounds) list_inbounds ;;
    links) show_all_links ;;
    firewall) run_mutation open_enabled_inbound_ports ;;
    info) show_info ;;
    config|change) run_mutation change_menu "${2:-}" ;;
    link) show_connection "${2:-}" "${3:-}" ;;
    users) users_command "${@:2}" ;;
    client) export_client "${2:-}" ;;
    cert-refresh) run_mutation refresh_tls_certificates "${2:-}" ;;
    status) show_status ;;
    start|stop|restart) run_mutation service_action "$1" ;;
    log) show_logs ;;
    speedtest) run_speedtest ;;
    route) if [[ -n ${2:-} ]]; then route_latency_test "$2"; else route_test_menu; fi ;;
    caddy) caddy_command "${2:-menu}" "${3:-}" "${4:-}" "${5:-}" ;;
    cfip|cloudflare-ip) cloudflare_ip_command "${@:2}" ;;
    warp) warp_command "${2:-menu}" "${3:-}" ;;
    update|update.core) core_update_command "${@:2}" ;;
    versions) check_core_update latest ;;
    rollback.core) run_mutation rollback_core ;;
    upgrade|update.sh) run_mutation update_manager ;;
    migrate) run_mutation migrate_project_state ;;
    rollback.sh) run_mutation rollback_manager ;;
    recover) run_mutation recover_manager ;;
    rotate) run_mutation rotate_reality_keys "${2:-}" ;;
    backup) run_mutation manual_backup ;;
    restore) run_mutation restore_latest ;;
    doctor) doctor_command "${2:-}" ;;
    plan) plan_desired "${2:-}" ;;
    apply) run_mutation apply_desired "${2:-}" ;;
    xhttp-mode) run_mutation set_xhttp_mode "${2:-}" "${3:-}" ;;
    uninstall) run_mutation uninstall_xray ;;
    version) printf '%s %s by %s\n' "$APP_NAME" "$MANAGER_VERSION" "$AUTHOR" ;;
    about) show_about ;;
    help|-h|--help) show_help; printf '%s\n' "用法：v2ray [install|add|inbounds|links|users [list|show|add|delete|replace|set]|info|change|config|link [入站ID] [CDN域名|cfip]|client [入站ID]|status|start|stop|restart|log|speedtest|route [目标]|caddy [install|verify|static|reverse|xray|page <域名> [portfolio|resume|default]|status|log|repair|uninstall]|cfip [install|test|set|verify|show|get|clear|uninstall]|warp [install|switch <wireguard|masque>|status|test|diagnose|check|selective|all|ipv4|ipv6|dual|off|repair|uninstall]|update|upgrade|update.sh|rollback.sh|rotate|backup|restore|doctor|firewall|about|uninstall]" ;;
    *) die "未知命令：$1。输入 v2ray help 查看可用命令。" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
