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
readonly MANAGER_VERSION="6.5.1"
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
  jq -cS '[.inbounds[] | {
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
profile_available_for_new_deployment() { [[ ${1:-${PROFILE:-}} != hysteria-tls-quic ]]; }
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
    hysteria-tls-quic) printf 'Hysteria-2-TLS-QUIC (Xray 入站已停用)' ;;
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
  ui_menu_item '12) Hysteria 2 TLS/QUIC      [暂不可新建：Xray 入站存在已知互通故障]'
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
  profile_available_for_new_deployment || die '当前 Xray Hysteria2 入站与标准 Hysteria2/sing-box 客户端存在已知互通故障，已停止新建。请按 docs/HYSTERIA2_MIGRATION.md 迁移到官方 Hysteria2 服务端。'
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
    profile_available_for_new_deployment "$PROFILE" || die '不再支持新建 Xray Hysteria2 入站；请迁移到官方 Hysteria2 服务端。'
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
