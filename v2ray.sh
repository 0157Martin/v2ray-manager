#!/usr/bin/env bash
# Modern Xray/VLESS installer and manager, exposed through the v2ray command.
# Supported hosts: Debian and Ubuntu with systemd. Run as root.
# Author: 0157Martin (https://github.com/0157Martin)
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

readonly APP_NAME="v2ray-manager"
readonly AUTHOR="0157Martin"
readonly MANAGER_VERSION="4.6.0"
readonly DEFAULT_PORT="443"
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
readonly NODES_DIR="$CONFIG_DIR/nodes"
readonly RELEASE_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
readonly MANAGER_URL="https://raw.githubusercontent.com/0157Martin/v2ray-manager/main/v2ray.sh"
readonly MANAGER_API="https://api.github.com/repos/0157Martin/v2ray-manager/commits/main"
readonly SERVICE_NAME="xray"
readonly CADDY_CONFIG="/etc/caddy/Caddyfile"
readonly CADDY_SITE_DIR="/etc/caddy/conf.d"
readonly CADDY_WEB_ROOT="/var/www/v2ray-manager"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
cyan_value() { printf '\033[36m%s\033[0m' "$*"; }
step() { printf '\033[33m%s\033[0m  %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { red "错误：$*"; exit 1; }
pause() { read -r -p "按 Enter 键返回菜单…" _; }

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行：sudo bash $0"
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
  apt-get install -y ca-certificates curl unzip jq coreutils iproute2 tar openssl
}

# Only modify a firewall that is already explicitly active.  We deliberately do
# not insert raw iptables/nftables rules: their persistence and policy are owned
# by the server administrator.
open_local_firewall_port() {
  local port=${1:?missing port}
  valid_port "$port" || die "端口无效：$port"

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${port}/tcp" >/dev/null
    green "本机 UFW 已放行 TCP ${port}。"
    return
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null
    firewall-cmd --reload >/dev/null
    green "本机 firewalld 已放行 TCP ${port}。"
    return
  fi

  yellow "未检测到已启用的 UFW/firewalld；未修改本机防火墙规则。"
}

open_enabled_inbound_ports() (
  local node_file node_port seen=' '
  [[ -d $NODES_DIR ]] || { yellow "尚无入站配置可放行。"; return; }
  for node_file in "$NODES_DIR"/*.env; do
    [[ -e $node_file ]] || continue
    # shellcheck disable=SC1090
    . "$node_file"
    node_port=$PORT
    [[ $seen == *" ${node_port} "* ]] && continue
    seen+="${node_port} "
    open_local_firewall_port "$node_port"
  done
  yellow "云服务商安全组不会由脚本自动修改；请确认已放行上述 TCP 端口。"
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

fetch_core() {
  local temp_dir=$1 arch tag url expected actual
  arch=$(arch_name) || return 1
  tag=$(curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 \
    --max-time 60 -H 'Accept: application/vnd.github+json' "$RELEASE_API" | jq -r '.tag_name') || return 1
  [[ -n "$tag" && "$tag" != "null" ]] || die "无法读取 Xray Core 最新稳定版本。"
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
valid_server_name() { [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && $1 == *.* && $1 != *..* ]]; }
valid_transport_path() { [[ $1 =~ ^/[A-Za-z0-9._~/-]+$ && $1 != *//* ]]; }
valid_profile() { [[ $1 == vless-reality-raw || $1 == vless-reality-xhttp || $1 == vless-reality-grpc || $1 == vless-tls-raw || $1 == vless-tls-xhttp || $1 == vless-tls-ws || $1 == vless-tls-grpc || $1 == trojan-reality-raw || $1 == vmess-tcp || $1 == vmess-tls-ws || $1 == vmess-tls-grpc || $1 == trojan-tls-ws ]]; }
profile_uses_tls() { [[ ${PROFILE:-} == *-tls-* ]]; }
profile_uses_reality() { [[ ${PROFILE:-vless-reality-raw} == *-reality-* ]]; }

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
  esac
}

choose_profile() {
  local choice default_path
  printf '%s\n' \
    '1) VLESS-REALITY-Vision-RAW  [推荐：高性能、无需自有证书]' \
    '2) VLESS-REALITY-XHTTP       [新式 HTTP 传输、内置多路复用]' \
    '3) VLESS-REALITY-gRPC        [HTTP/2 兼容，新部署更建议 XHTTP]' \
    '4) VLESS-XHTTP-TLS           [自动匹配/申请证书，适合 HTTP/CDN 链路]' \
    '5) VLESS-WebSocket-TLS       [自动匹配/申请证书，客户端/CDN 兼容广]' \
    '6) VLESS-gRPC-TLS            [自动匹配/申请证书，适合现有 HTTP/2 反代]' \
    '7) Trojan-REALITY-RAW        [Trojan 客户端兼容，无需自有证书]' \
    '--- 旧版兼容（非默认推荐）---' \
    '8) VMess-TCP                 [无 TLS/REALITY，仅兼容或可信链路]' \
    '9) VMess-WebSocket-TLS       [老客户端和 CDN 兼容广]' \
    '10) VMess-gRPC-TLS           [兼容既有 HTTP/2 反代]' \
    '11) Trojan-WebSocket-TLS     [传统 Trojan + WS 兼容]' \
    '12) VLESS-TLS-Vision-RAW      [官方教程组合，需要自有域名及证书]'
  read -r -p '请选择协议组合 [1-12]:' choice
  case "$choice" in
    1) PROFILE=vless-reality-raw; PATH_VALUE='' ;;
    2)
      PROFILE=vless-reality-xhttp
      default_path=${PATH_VALUE:-/$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')}
      [[ $default_path == /* ]] || default_path="/$default_path"
      read -r -p "XHTTP 路径 [${default_path}]:" PATH_VALUE
      PATH_VALUE=${PATH_VALUE:-$default_path}
      [[ $PATH_VALUE == /* ]] || PATH_VALUE="/$PATH_VALUE"
      ;;
    3)
      PROFILE=vless-reality-grpc
      default_path=${PATH_VALUE:-grpc-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')}
      default_path=${default_path#/}
      read -r -p "gRPC serviceName [${default_path}]:" PATH_VALUE
      PATH_VALUE=${PATH_VALUE:-$default_path}
      PATH_VALUE=${PATH_VALUE#/}
      ;;
    4|5|6|9|10|11)
      case "$choice" in
        4) PROFILE=vless-tls-xhttp ;; 5) PROFILE=vless-tls-ws ;; 6) PROFILE=vless-tls-grpc ;;
        9) PROFILE=vmess-tls-ws ;; 10) PROFILE=vmess-tls-grpc ;; 11) PROFILE=trojan-tls-ws ;;
      esac
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
    7) PROFILE=trojan-reality-raw; PATH_VALUE='' ;;
    8) PROFILE=vmess-tcp; PATH_VALUE='' ;;
    12) PROFILE=vless-tls-raw; PATH_VALUE=''; CERT_SOURCE=''; KEY_SOURCE='' ;;
    *) die "协议组合选择无效。" ;;
  esac
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
  default_port=${PORT:-$DEFAULT_PORT}
  default_uuid=${UUID:-$("$XRAY_BIN" uuid)}
  default_name=${REMARK:-xray-reality}
  default_server=${SERVER_NAME:-www.microsoft.com}
  local previous_profile=${PROFILE:-vless-reality-raw}

  if [[ ${V2M_NONINTERACTIVE:-0} == 1 ]]; then
    PROFILE=${V2M_PROFILE:-${PROFILE:-vless-reality-raw}}
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
      PORT=$(find_free_port "$DEFAULT_PORT")
    fi
    UUID=${V2M_UUID:-$default_uuid}
    SERVER_NAME=${V2M_SERVER_NAME:-$default_server}
    REMARK=${V2M_REMARK:-$default_name}
    ADDRESS=${V2M_ADDRESS:-${ADDRESS:-}}
    valid_port "$PORT" || die "V2M_PORT 必须是 1 到 65535 的端口。"
    valid_uuid "$UUID" || die "V2M_UUID 格式无效。"
    valid_server_name "$SERVER_NAME" || die "V2M_SERVER_NAME 必须是有效完整域名。"
    if profile_uses_reality && [[ -z ${PRIVATE_KEY:-} || -z ${PUBLIC_KEY:-} || -z ${SHORT_ID:-} ]]; then
      generate_reality_credentials
    fi
    return
  fi

  choose_profile
  if profile_uses_tls && [[ $previous_profile != *-tls-* ]]; then default_server=; fi

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
    valid_server_name "$SERVER_NAME" && break
    yellow "请输入有效的完整域名，例如 www.microsoft.com。"
  done
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
  local -a challenge_args=(--standalone)
  if [[ -n ${V2M_ACME_WEBROOT:-} ]]; then
    [[ $V2M_ACME_WEBROOT == /* && -d $V2M_ACME_WEBROOT ]] || die "V2M_ACME_WEBROOT 必须是已有网站根目录的绝对路径。"
    challenge_args=(--webroot --webroot-path "$V2M_ACME_WEBROOT")
  else
    [[ -z $(ss -H -lnt 'sport = :80') ]] || die "TCP 80 已占用；设置 V2M_ACME_WEBROOT 使用现有网站根目录申请证书，或提供已有证书。"
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

prepare_tls_material() {
  profile_uses_tls || return 0
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
  [[ $(readlink -f "$CERT_SOURCE") == "$(readlink -f "$target/cert.pem" 2>/dev/null || true)" ]] || install -m 640 -o root -g xray "$CERT_SOURCE" "$target/cert.pem"
  [[ $(readlink -f "$KEY_SOURCE") == "$(readlink -f "$target/key.pem" 2>/dev/null || true)" ]] || install -m 640 -o root -g xray "$KEY_SOURCE" "$target/key.pem"
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
  local listeners
  listeners=$(ss -H -lntp "sport = :${PORT}" 2>/dev/null || true)
  [[ -z $listeners ]] && return 0
  if grep -q 'xray-core' <<<"$listeners"; then
    return 0
  fi
  red "错误：TCP 端口 ${PORT} 已被其他服务占用："
  printf '%s\n' "$listeners"
  die "请选择其他端口，不会停止现有服务。"
}

render_config() {
  local destination=$1
  jq -n \
    --argjson port "$PORT" \
    --arg id "$UUID" \
    --arg server "$SERVER_NAME" \
    --arg private "${PRIVATE_KEY:-}" \
    --arg short "${SHORT_ID:-}" \
    --arg profile "${PROFILE:-vless-reality-raw}" \
    --arg path "${PATH_VALUE:-}" \
    --arg listen "$(if [[ ${ADDRESS:-} == *:* ]]; then printf '::'; else printf '0.0.0.0'; fi)" \
    --arg cert "${TLS_CERT_PATH_OVERRIDE:-$(tls_cert_path)}" \
    --arg key "${TLS_KEY_PATH_OVERRIDE:-$(tls_key_path)}" '{
      log: {loglevel: "warning"},
      inbounds: [{
        tag: "vless-reality",
        listen: $listen,
        port: $port,
        protocol: (if ($profile | startswith("trojan-")) then "trojan" elif ($profile | startswith("vmess-")) then "vmess" else "vless" end),
        settings: (if ($profile | startswith("trojan-")) then {clients: [{password: $id}]}
        elif ($profile | startswith("vmess-")) then {clients: [{id: $id, alterId: 0}]}
        else {
          clients: [({id: $id} + (if ($profile == "vless-reality-raw" or $profile == "vless-tls-raw") then {flow: "xtls-rprx-vision"} else {} end))],
          decryption: "none"
        } end),
        streamSettings: ({
          network: (if ($profile == "vless-reality-xhttp" or $profile == "vless-tls-xhttp") then "xhttp" elif ($profile | endswith("-grpc")) then "grpc" elif ($profile | endswith("-ws")) then "ws" else "raw" end),
          security: (if ($profile | contains("-tls-")) then "tls" elif ($profile | contains("-reality-")) then "reality" else "none" end)
        } + (if ($profile | contains("-reality-")) then {realitySettings: {
            show: false,
            target: ($server + ":443"),
            xver: 0,
            serverNames: [$server],
            privateKey: $private,
            shortIds: [$short]
          }} elif ($profile | contains("-tls-")) then {tlsSettings: {certificates: [{certificateFile: $cert, keyFile: $key}]}} else {} end)
          + (if ($profile == "vless-reality-xhttp" or $profile == "vless-tls-xhttp") then {xhttpSettings: {path: $path}}
            elif ($profile | endswith("-grpc")) then {grpcSettings: {serviceName: $path, multiMode: false}}
            elif ($profile | endswith("-ws")) then {wsSettings: {path: $path}}
            else {} end)),
        sniffing: {enabled: true, destOverride: ["http", "tls", "quic"]}
      }],
      outbounds: [
        {protocol: "freedom", tag: "direct"},
        {protocol: "blackhole", tag: "block"}
      ]
    }' > "$destination"
}

write_config() {
  ensure_service_user
  install -d -m 755 "$CONFIG_DIR"
  create_backup
  prepare_tls_material
  # Xray determines the configuration format from the final file extension.
  local temporary="$CONFIG_DIR/config.pending.json"
  render_config "$temporary"
  if ! XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_BIN" run -test -config "$temporary"; then
    red "Xray 配置校验输出如上。"
    rm -f "$temporary"
    die "新配置未通过 Xray 校验。"
  fi
  install -m 640 -o root -g xray "$temporary" "$CONFIG_FILE"
  rm -f "$temporary"
  cat > "$STATE_FILE" <<EOF
PORT=${PORT}
UUID=${UUID}
ADDRESS=$(printf %q "${ADDRESS:-}")
PROFILE=$(printf %q "${PROFILE:-vless-reality-raw}")
PATH_VALUE=$(printf %q "${PATH_VALUE:-}")
CERT_SOURCE=$(printf %q "${CERT_SOURCE:-}")
KEY_SOURCE=$(printf %q "${KEY_SOURCE:-}")
SERVER_NAME=$(printf %q "$SERVER_NAME")
PRIVATE_KEY=$(printf %q "$PRIVATE_KEY")
PUBLIC_KEY=$(printf %q "$PUBLIC_KEY")
SHORT_ID=$(printf %q "$SHORT_ID")
REMARK=$(printf %q "$REMARK")
EOF
  chmod 600 "$STATE_FILE"
  install -d -m 700 "$NODES_DIR"
  save_current_node "$NODES_DIR/primary.env"
  rebuild_or_restore
}

save_current_node() {
  local destination=$1
  cat > "$destination" <<EOF
PORT=${PORT}
UUID=${UUID}
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
EOF
  chmod 600 "$destination"
}

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
    . "$node_file" || return 1
    node_id=$(basename "$node_file" .env)
    rendered="$work_dir/${node_id}.json"
    render_config "$rendered" || return 1
    jq --arg tag "$node_id" '.inbounds[0].tag=$tag | .inbounds[0]' "$rendered" > "$work_dir/inbound.json" || return 1
    jq --slurpfile inbound "$work_dir/inbound.json" '. + $inbound' "$combined" > "$work_dir/next.json" || return 1
    mv "$work_dir/next.json" "$combined" || return 1
  done
  [[ $(jq 'length' "$combined") -gt 0 ]] || { rm -rf "$work_dir"; red "至少需要一个启用的入站。"; return 1; }
  jq -n --slurpfile inbounds "$combined" '{log:{loglevel:"warning"},inbounds:$inbounds[0],outbounds:[{protocol:"freedom",tag:"direct"},{protocol:"blackhole",tag:"block"}]}' > "$work_dir/config.json" || return 1
  XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_BIN" run -test -config "$work_dir/config.json" >/dev/null || { rm -rf "$work_dir"; red "多入站配置未通过 Xray 校验。"; return 1; }
  install -m 640 -o root -g xray "$work_dir/config.json" "$CONFIG_FILE"
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
  ask_server_values
  ensure_port_available
  step "生成并校验配置文件"
  write_config
  step "安装 systemd 服务"
  write_service
  stop_legacy_service
  systemctl enable "$SERVICE_NAME"
  restart_or_rollback
  green "Xray、VLESS + REALITY 安装完成。"
  open_enabled_inbound_ports
  green "安装完成后不会自动显示节点凭据；需要时运行 v2ray links 或 v2ray link。"
}

load_state() {
  [[ -r "$STATE_FILE" ]] || die "找不到管理状态，请先安装或重新运行安装以迁移到 2.x。"
  # This file is created by this script with mode 0600.
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  PROFILE=${PROFILE:-vless-reality-raw}
  PATH_VALUE=${PATH_VALUE:-}
}

create_backup() {
  LAST_BACKUP=""
  [[ -r "$CONFIG_FILE" && -r "$STATE_FILE" ]] || return 0
  install -d -m 700 "$BACKUP_DIR"
  local timestamp archive
  timestamp=$(date -u +%Y%m%dT%H%M%SZ)
  archive=$(mktemp "$BACKUP_DIR/config-${timestamp}-XXXXXX.tar.gz")
  local -a backup_items=(config.json manager.env)
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
  temp_dir=$(mktemp -d)
  trap 'rm -rf -- "$temp_dir"' EXIT
  tar -xzf "$archive" -C "$temp_dir"
  [[ -r "$temp_dir/config.json" && -r "$temp_dir/manager.env" ]] || die "备份内容不完整。"
  # Validate against the archived certificates, not the possibly broken live ones.
  jq --arg live "$TLS_DIR/" --arg staged "$temp_dir/tls/" \
    'walk(if type == "string" then if startswith($live) then $staged + .[($live|length):] else . end else . end)' \
    "$temp_dir/config.json" > "$temp_dir/validation.json"
  XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_BIN" run -test -config "$temp_dir/validation.json" >/dev/null || die "备份配置未通过 Xray 校验。"
  if [[ -d $temp_dir/tls ]]; then
    # Retain both legacy shared certificates and all per-domain directories.
    chown -R root:xray "$temp_dir/tls"
    find "$temp_dir/tls" -type d -exec chmod 750 {} +
    find "$temp_dir/tls" -type f -exec chmod 640 {} +
    find "$temp_dir/tls" -type f -name source -exec chmod 600 {} +
    install -d -m 750 -o root -g xray "$TLS_DIR"
    cp -a "$temp_dir/tls/." "$TLS_DIR/"
  fi
  install -m 640 -o root -g xray "$temp_dir/config.json" "$CONFIG_FILE"
  install -m 600 -o root -g root "$temp_dir/manager.env" "$STATE_FILE"
  if [[ -d $temp_dir/nodes ]]; then
    rm -rf "$NODES_DIR"
    install -d -m 700 "$NODES_DIR"
    cp -a "$temp_dir/nodes/." "$NODES_DIR/"
  fi
)

restore_latest() {
  [[ -d "$BACKUP_DIR" ]] || die "没有可恢复的配置备份。"
  local archive
  archive=$(list_backups | sed -n '1p')
  [[ -n "$archive" ]] || die "没有可恢复的配置备份。"
  restore_archive "$archive"
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
  systemctl restart "$SERVICE_NAME" && service_healthy
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
  local addr first second
  if [[ -n ${ADDRESS:-} ]]; then
    printf '%s' "$ADDRESS"
    return
  fi
  addr=$(curl --fail --silent --max-time 4 https://api.ipify.org 2>/dev/null || true)
  IFS=. read -r first second _ <<<"$addr"
  if [[ $first == 104 && $second =~ ^(1[6-9]|2[0-9]|3[01])$ ]] || \
     [[ $first == 172 && $second =~ ^(6[4-9]|7[01])$ ]] || [[ $first == 188 && $second == 114 ]]; then
    printf '%s' 'YOUR_SERVER_IP'
    return
  fi
  printf '%s' "${addr:-YOUR_SERVER_IP}"
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
    . "$node_file"
  else
    load_state
  fi
}

show_connection() (
  local node_id=${1:-} address_override=${2:-}
  if [[ -n $node_id ]]; then
    [[ $node_id =~ ^[A-Za-z0-9_-]+$ && -f $NODES_DIR/$node_id.env ]] || {
      red "找不到启用的入站：$node_id" >&2
      return 1
    }
    # shellcheck disable=SC1090
    . "$NODES_DIR/$node_id.env"
  else
    load_connection_state || return 1
  fi
  if [[ -n $address_override ]]; then
    [[ $PROFILE == *-tls-xhttp || $PROFILE == *-tls-ws ]] || {
      red "自定义 CDN/优选 IP 仅适用于 TLS XHTTP/WebSocket 入站。" >&2
      return 1
    }
    [[ $address_override != *[[:space:]/\?#@]* ]] || { red "CDN/优选 IP 地址格式无效。" >&2; return 1; }
  fi
  show_connection_loaded "$CONFIG_FILE" "$address_override"
)

# Build client transport from the same profile as the server; never export
# server certificates, private keys or REALITY target settings.
render_client_config() {
  render_config /dev/stdout | jq --arg address "$(server_address)" \
    --arg server "$SERVER_NAME" --arg public "${PUBLIC_KEY:-}" --arg short "${SHORT_ID:-}" '
    .inbounds[0] as $in |
    $in.settings.clients[0] as $user |
    ($in.streamSettings | del(.tlsSettings, .realitySettings) |
      if .security == "reality" then .realitySettings = {
        serverName: $server, fingerprint: "chrome", password: $public, shortId: $short
      } elif .security == "tls" then .tlsSettings = {
        serverName: $server, fingerprint: "chrome"
      } else . end |
      if .network == "xhttp" and .security == "tls" then .xhttpSettings.host = $server
      elif .network == "ws" and .security == "tls" then .wsSettings.headers.Host = $server
      else . end) as $stream |
    {
      log: {loglevel: "warning"},
      inbounds: [
        {tag: "socks", listen: "127.0.0.1", port: 10800, protocol: "socks", settings: {auth: "noauth", udp: true}},
        {tag: "http", listen: "127.0.0.1", port: 10801, protocol: "http", settings: {}}
      ],
      outbounds: [{tag: "proxy", protocol: $in.protocol,
        settings: (if $in.protocol == "trojan" then {
          servers: [{address: ($address | ltrimstr("[") | rtrimstr("]")), port: $in.port, password: $user.password}]
        } else {vnext: [{address: ($address | ltrimstr("[") | rtrimstr("]")), port: $in.port,
          users: [($user + (if $in.protocol == "vless" then {encryption: "none"} else {security: "auto"} end))]}]} end),
        streamSettings: $stream
      }]
    }'
}

export_client() (
  if [[ -n ${1:-} ]]; then
    [[ $1 =~ ^[A-Za-z0-9_-]+$ && -f $NODES_DIR/$1.env ]] || { red "找不到启用的入站：$1" >&2; return 1; }
    # shellcheck disable=SC1090
    source "$NODES_DIR/$1.env"
  else
    load_connection_state || return 1
  fi
  show_connection_loaded "$CONFIG_FILE" >/dev/null || return 1
  render_client_config
)

connection_matches_config() {
  local config_file=${1:-$CONFIG_FILE}
  [[ -r $config_file ]] || return 1
  render_config /dev/stdout | jq -e --slurpfile live "$config_file" '
    def signature: {
      port, protocol, clients: .settings.clients,
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

show_connection_loaded() (
  local address uri_address encoded_name encoded_path link transport security flow query display_name protocol vmess_payload client_port
  local cdn_address=${2:-}
  address=${cdn_address:-$(server_address)}
  client_port=$PORT
  [[ -z $cdn_address ]] || client_port=443
  if [[ -z $address || $address == YOUR_SERVER_IP || $address == *[[:space:]/\?#@]* ]]; then
    red "无法导出链接：客户端入口地址未知或格式无效。请填写服务器真实公网 IP 或直连域名（不要填写 http:// 或端口）。" >&2
    return 1
  fi
  address=${address#[}; address=${address%]}
  uri_address=$address
  [[ $address != *:* ]] || uri_address="[$address]"
  valid_uuid "$UUID" || { red "无法导出链接：UUID 格式无效。" >&2; return 1; }
  if profile_uses_reality && ! reality_pair_valid; then
    red "无法导出链接：REALITY 密钥对或 Short ID 无效，请从对应入站菜单修复或重新生成。" >&2
    return 1
  fi
  if profile_uses_tls && ! tls_pair_valid "${TLS_CERT_PATH_OVERRIDE:-$(tls_cert_path)}" "${TLS_KEY_PATH_OVERRIDE:-$(tls_key_path)}"; then
    red "无法导出链接：TLS 证书无效、过期、域名不符或私钥不匹配。" >&2
    return 1
  fi
  if ! connection_matches_config "${1:-$CONFIG_FILE}"; then
    red "无法导出链接：入站状态与当前 config.json 不一致。请运行 v2ray doctor，并从入站管理菜单检查对应节点。" >&2
    return 1
  fi
  encoded_name=$(jq -rn --arg value "$REMARK" '$value|@uri')
  encoded_path=$(jq -rn --arg value "${PATH_VALUE:-}" '$value|@uri')
  display_name=$(profile_name)
  protocol=vless
  link=''
  case "$PROFILE" in
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
      query="encryption=none&security=reality&sni=${SERVER_NAME}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=xhttp&path=${encoded_path}&mode=auto"
      ;;
    vless-reality-grpc)
      transport=grpc; security=reality; flow=none
      query="encryption=none&security=reality&sni=${SERVER_NAME}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=grpc&serviceName=${encoded_path}"
      ;;
    vless-tls-xhttp)
      transport=xhttp; security=tls; flow=none
      query="encryption=none&security=tls&sni=${SERVER_NAME}&fp=chrome&type=xhttp&host=${SERVER_NAME}&path=${encoded_path}&mode=auto"
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
      vmess_payload=$(jq -cn --arg ps "$REMARK" --arg add "$address" --arg port "$client_port" --arg id "$UUID" \
        --arg net "$transport" --arg host "$SERVER_NAME" --arg path "${PATH_VALUE:-}" --arg tls "${security/none/}" \
        '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:$net,type:"none",host:$host,path:$path,tls:$tls,sni:$host}')
      link="vmess://$(printf '%s' "$vmess_payload" | base64 -w 0)"
      ;;
  esac
  if [[ -z $link ]]; then link="${protocol}://${UUID}@${uri_address}:${client_port}?${query}#${encoded_name}"; fi
  printf '\n使用协议: %s\n' "$display_name"
  printf '%s\n' "-------------- ${display_name} --------------"
  printf '协议 (protocol)       = '; cyan_value "$protocol"; printf '\n'
  printf '地址 (address)        = '; cyan_value "$address"; printf '\n'
  printf '端口 (port)           = '; cyan_value "$client_port"; printf '\n'
  if [[ $protocol == trojan ]]; then printf '密码 (password)        = '; else printf '用户ID (id)           = '; fi
  cyan_value "$UUID"; printf '\n'
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
  cyan_value "$link"; printf '\n'
  printf '%s\n\n' '---------------------- END ----------------------'
  yellow "请确认云服务商安全组已放行 TCP ${PORT}；可执行 v2ray firewall 放行已启用入站的本机 UFW/firewalld 规则。私钥仅保存在服务器，不要公开。"
)

change_config() {
  [[ -x "$XRAY_BIN" ]] || die "尚未安装。"
  load_state
  ask_server_values
  write_config
  restart_or_rollback
  green "配置已更新并重启服务。"
  open_enabled_inbound_ports
  show_connection
}

change_menu() {
  [[ -x "$XRAY_BIN" ]] || die "尚未安装。"
  load_state
  printf '\n当前选择: %s\n\n' "$(profile_name)"
  printf '%s\n' '请选择更改:' \
    '1) 更改协议组合' '2) 更改端口' '3) 更改服务器地址' '4) 更改目标域名 / SNI' \
    '5) 更改 UUID' '6) 更改备注' '7) 轮换 REALITY 密钥' \
    '8) 重新输入全部配置' '0) 返回'
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
      read -r -p "客户端连接的 IP/域名 [${ADDRESS:-自动检测}]:" value
      ADDRESS=$value
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
      rotate_reality_keys; return
      ;;
    8) change_config; return ;;
    0) return ;;
    *) die "无效选择。" ;;
  esac
  write_config
  restart_or_rollback
  green "配置已更新并重启服务。"
  open_enabled_inbound_ports
  show_connection
}

find_free_port() {
  local candidate=${1:-24443}
  while ss -H -lnt "sport = :${candidate}" 2>/dev/null | grep -q .; do ((candidate+=1)); done
  printf '%s' "$candidate"
}

list_inbounds() (
  install -d -m 700 "$NODES_DIR"
  local node_file state node_id
  printf '\n%-24s %-9s %-30s %s\n' '入站 ID' '状态' '协议组合' '端口'
  printf '%s\n' '----------------------------------------------------------------------------'
  for node_file in "$NODES_DIR"/*.env "$NODES_DIR"/*.disabled; do
    [[ -e $node_file ]] || continue
    # shellcheck disable=SC1090
    . "$node_file"
    node_id=$(basename "$node_file"); node_id=${node_id%.env}; node_id=${node_id%.disabled}
    [[ $node_file == *.env ]] && state='启用' || state='停用'
    printf '%-24s %-9s %-30s %s\n' "$node_id" "$state" "$(profile_name)" "$PORT"
  done
  printf '\n'
)

add_inbound() {
  [[ -x $XRAY_BIN ]] || die "请先安装 Xray。"
  load_state
  PORT=$(find_free_port 24443)
  UUID=''; PROFILE=''; PATH_VALUE=''; PRIVATE_KEY=''; PUBLIC_KEY=''; SHORT_ID=''; REMARK=''; CERT_SOURCE=''; KEY_SOURCE=''
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
  green "已添加入站：$node_id"
  open_enabled_inbound_ports
  show_connection_loaded "$CONFIG_FILE"
}

show_all_links() (
  local node_file node_id failures=0 count=0
  for node_file in "$NODES_DIR"/*.env; do
    [[ -e $node_file ]] || continue
    # shellcheck disable=SC1090
    . "$node_file"
    node_id=$(basename "$node_file" .env)
    ((count+=1))
    printf '\n================ %s ================\n' "$node_id"
    show_connection_loaded "$CONFIG_FILE" || ((failures+=1))
  done
  (( count > 0 && failures == 0 ))
)

select_node_file() {
  local include_disabled=${1:-0} node_id
  list_inbounds >&2
  read -r -p '请输入入站 ID:' node_id
  if [[ -e $NODES_DIR/$node_id.env ]]; then printf '%s' "$NODES_DIR/$node_id.env"; return; fi
  if [[ $include_disabled == 1 && -e $NODES_DIR/$node_id.disabled ]]; then printf '%s' "$NODES_DIR/$node_id.disabled"; return; fi
  die "找不到入站：$node_id"
}

disable_inbound() {
  local node_file active_count
  node_file=$(select_node_file 0)
  active_count=$(find "$NODES_DIR" -maxdepth 1 -type f -name '*.env' | wc -l)
  (( active_count > 1 )) || die "至少需保留一个启用的入站。"
  create_backup
  mv "$node_file" "${node_file%.env}.disabled"
  rebuild_or_restore
  restart_or_rollback
  green "入站已停用。"
}

modify_inbound() {
  local node_file
  node_file=$(select_node_file 0)
  # shellcheck disable=SC1090
  . "$node_file"
  ask_server_values
  ensure_port_available
  create_backup
  prepare_tls_material
  save_current_node "$node_file"
  rebuild_or_restore
  restart_or_rollback
  green "入站已更新。"
  open_enabled_inbound_ports
  show_connection_loaded "$CONFIG_FILE"
}

enable_inbound() {
  local node_file
  node_file=$(select_node_file 1)
  [[ $node_file == *.disabled ]] || die "该入站已经启用。"
  create_backup
  mv "$node_file" "${node_file%.disabled}.env"
  rebuild_or_restore
  restart_or_rollback
  green "入站已启用。"
}

delete_inbound() {
  local node_file active_count answer
  node_file=$(select_node_file 1)
  read -r -p "确认删除 $(basename "$node_file")？[y/N] " answer
  [[ ${answer,,} == y || ${answer,,} == yes ]] || return
  active_count=$(find "$NODES_DIR" -maxdepth 1 -type f -name '*.env' | wc -l)
  [[ $node_file == *.disabled || $active_count -gt 1 ]] || die "不能删除唯一启用的入站。"
  create_backup
  rm -f "$node_file"
  rebuild_or_restore
  restart_or_rollback
  green "入站已删除。"
}

manage_inbounds_menu() {
  printf '%s\n' '1) 查看入站列表' '2) 修改入站' '3) 停用入站' '4) 启用入站' '5) 删除入站' '6) 查看全部链接' '0) 返回'
  read -r -p '请选择 [0-6]:' choice
  case "$choice" in 1) list_inbounds ;; 2) modify_inbound ;; 3) disable_inbound ;; 4) enable_inbound ;; 5) delete_inbound ;; 6) show_all_links ;; 0) return ;; *) yellow "无效选择。" ;; esac
}

rotate_reality_keys() {
  [[ -x "$XRAY_BIN" ]] || die "尚未安装。"
  load_state
  profile_uses_reality || die "当前 TLS 组合不使用 REALITY 密钥。"
  generate_reality_credentials
  write_config
  restart_or_rollback
  green "REALITY 密钥和 Short ID 已轮换，旧客户端链接立即失效。"
  show_connection
}

service_action() {
  local action=$1
  systemctl "$action" "$SERVICE_NAME"
  if [[ $action == start || $action == restart ]]; then
    service_healthy || die "服务未通过健康检查，请运行 v2ray log。"
  fi
  green "已执行：${action}。"
}

show_status() { systemctl --no-pager --full status "$SERVICE_NAME" || true; }
show_logs() { journalctl -u "$SERVICE_NAME" -n 100 --no-pager; }

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
      valid_caddy_upstream "$upstream" || return 1
      valid_transport_path "$path" || return 1
      cat > "$destination" <<EOF
$domain {
	@xray path $path $path/*
	reverse_proxy @xray https://$upstream {
		flush_interval -1
		transport http {
			tls_server_name $domain
		}
	}
	root * $CADDY_WEB_ROOT/$domain
	encode zstd gzip
	file_server
}
EOF
      ;;
    *) return 1 ;;
  esac
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

install_caddy() (
  local temporary
  command -v caddy >/dev/null 2>&1 && return 0
  caddy_ports_available || return 1
  step "安装 Caddy"
  apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
    debian-keyring debian-archive-keyring apt-transport-https curl gnupg || return 1
  temporary=$(mktemp -d) || return 1
  trap 'rm -rf -- "$temporary"' EXIT
  curl --fail --show-error --location --retry 3 \
    https://dl.cloudsmith.io/public/caddy/stable/gpg.key -o "$temporary/caddy.gpg.key" || return 1
  curl --fail --show-error --location --retry 3 \
    https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt -o "$temporary/caddy-stable.list" || return 1
  grep -Eq '^deb ' "$temporary/caddy-stable.list" || { red "Caddy 软件源内容无效。" >&2; return 1; }
  gpg --batch --yes --dearmor --output "$temporary/caddy-stable-archive-keyring.gpg" \
    "$temporary/caddy.gpg.key" || return 1
  install -m 644 "$temporary/caddy-stable-archive-keyring.gpg" \
    /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  install -m 644 "$temporary/caddy-stable.list" /etc/apt/sources.list.d/caddy-stable.list
  apt-get update || return 1
  DEBIAN_FRONTEND=noninteractive apt-get install -y caddy || {
    red "无法从系统软件仓库安装 Caddy。" >&2
    return 1
  }
  command -v caddy >/dev/null 2>&1 || { red "Caddy 安装后仍不可执行。" >&2; return 1; }
)

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

write_caddy_landing_page() {
  local domain=$1 root="$CADDY_WEB_ROOT/$1"
  install -d -m 755 "$root"
  cat > "$root/index.html" <<EOF
<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>$domain</title><style>body{max-width:760px;margin:15vh auto;padding:0 24px;font:16px/1.7 system-ui;color:#243447}h1{font-size:2.2rem}</style></head>
<body><h1>Welcome</h1><p>This site is online.</p></body></html>
EOF
  chown -R caddy:caddy "$root"
}

configure_caddy_site() {
  local mode=$1 domain=$2 upstream=${3:-} path=${4:-} target temporary previous='' had_previous=0
  valid_server_name "$domain" || { red "请输入有效完整域名。" >&2; return 1; }
  [[ $mode != reverse ]] || valid_caddy_upstream "$upstream" || {
    red "反向代理后端仅支持本机地址，例如 127.0.0.1:8080、localhost:3000 或 [::1]:8080。" >&2
    return 1
  }
  if [[ $mode == xray ]]; then
    valid_caddy_upstream "$upstream" || { red "Xray 后端仅支持本机地址。" >&2; return 1; }
    valid_transport_path "$path" || { red "Xray 传输路径无效，必须以 / 开头且不能包含空格。" >&2; return 1; }
  fi
  caddy_ports_available || return 1
  install_caddy || return 1
  ensure_caddy_import || { red "无法安全更新 Caddyfile import。" >&2; return 1; }
  getent ahosts "$domain" >/dev/null 2>&1 || yellow "域名当前无法解析；Caddy 自动申请证书前请先配置 DNS。"
  target="$CADDY_SITE_DIR/$domain.caddy"
  temporary=$(mktemp "$CADDY_SITE_DIR/.${domain}.XXXXXX") || return 1
  render_caddy_site "$mode" "$domain" "$upstream" "$temporary" "$path" || { rm -f -- "$temporary"; return 1; }
  if [[ -e $target ]]; then
    previous=$(mktemp "$CADDY_SITE_DIR/.previous.XXXXXX") || return 1
    cp -p "$target" "$previous" || return 1
    had_previous=1
  fi
  install -m 644 -o root -g root "$temporary" "$target" || return 1
  rm -f -- "$temporary"
  if ! caddy validate --config "$CADDY_CONFIG" --adapter caddyfile; then
    if (( had_previous )); then mv -f "$previous" "$target"; else rm -f -- "$target"; fi
    red "Caddy 配置校验失败，已恢复旧站点配置。" >&2
    return 1
  fi
  if [[ $mode == static || $mode == xray ]]; then write_caddy_landing_page "$domain"; fi
  open_local_firewall_port 80
  open_local_firewall_port 443
  if systemctl is-active --quiet caddy; then
    if ! systemctl reload caddy; then
      if (( had_previous )); then mv -f "$previous" "$target"; else rm -f -- "$target"; fi
      systemctl reload caddy || true
      red "Caddy reload 失败，已恢复旧站点配置。" >&2
      return 1
    fi
  else
    if ! systemctl enable --now caddy; then
      if (( had_previous )); then mv -f "$previous" "$target"; else rm -f -- "$target"; fi
      red "Caddy 启动失败，已恢复旧站点配置。" >&2
      return 1
    fi
  fi
  [[ -z $previous ]] || rm -f -- "$previous"
  green "Caddy 站点已启用：https://$domain"
}

caddy_menu() {
  local choice domain upstream path
  printf '\n%s\n' '----- Caddy 网站管理 -----'
  printf '%s\n' '1) 安装 Caddy' '2) 创建静态伪装网站' '3) 创建本机反向代理' \
    '4) 创建 Xray XHTTP/WS 路径反代' '5) 查看 Caddy 状态' '6) 查看 Caddy 日志' '0) 返回'
  read -r -p '请选择 [0-6]:' choice
  case "$choice" in
    1) caddy_ports_available && install_caddy && green "Caddy 已安装。" ;;
    2) read -r -p '网站域名：' domain; configure_caddy_site static "$domain" ;;
    3)
      read -r -p '网站域名：' domain
      read -r -p '本机后端 [127.0.0.1:8080]：' upstream
      configure_caddy_site reverse "$domain" "${upstream:-127.0.0.1:8080}"
      ;;
    4)
      read -r -p 'TLS 域名：' domain
      read -r -p 'Xray 本机 TLS 后端 [127.0.0.1:24443]：' upstream
      read -r -p 'XHTTP/WS 路径（例如 /a1b2c3）：' path
      configure_caddy_site xray "$domain" "${upstream:-127.0.0.1:24443}" "$path"
      ;;
    5) systemctl --no-pager --full status caddy || true ;;
    6) journalctl -u caddy -n 100 --no-pager ;;
    0) return ;;
    *) yellow "无效选择。" ;;
  esac
}

caddy_command() {
  local action=${1:-menu} domain=${2:-} upstream=${3:-} path=${4:-}
  case "$action" in
    menu) caddy_menu ;;
    install) caddy_ports_available && install_caddy ;;
    static) [[ -n $domain ]] || die "用法：v2ray caddy static <域名>"; configure_caddy_site static "$domain" ;;
    reverse) [[ -n $domain && -n $upstream ]] || die "用法：v2ray caddy reverse <域名> <本机地址:端口>"; configure_caddy_site reverse "$domain" "$upstream" ;;
    xray) [[ -n $domain && -n $upstream && -n $path ]] || die "用法：v2ray caddy xray <域名> <本机TLS地址:端口> <路径>"; configure_caddy_site xray "$domain" "$upstream" "$path" ;;
    status) systemctl --no-pager --full status caddy || true ;;
    log) journalctl -u caddy -n 100 --no-pager ;;
    *) die "未知 Caddy 操作：$action" ;;
  esac
}

doctor() {
  local failures=0 port security target node_file node_count=0 handshake
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

  if [[ -r $CONFIG_FILE ]]; then
    while IFS=$'\t' read -r port security target; do
      if ss -H -lnt "sport = :$port" | grep -q .; then
        green "[通过] TCP $port 正在监听"
      else
        red "[失败] TCP $port 未监听"; ((failures+=1))
      fi
      if [[ $security == reality ]]; then
        if getent ahosts "$target" >/dev/null 2>&1; then
          green "[通过] TCP $port 的 REALITY 目标可解析"
        else
          red "[失败] TCP $port 的 REALITY 目标无法解析"; ((failures+=1)); continue
        fi
        if command -v openssl >/dev/null && command -v timeout >/dev/null; then
          handshake=$(timeout 8 openssl s_client -connect "$target:443" -servername "$target" \
            -tls1_3 -brief </dev/null 2>&1 || true)
          if [[ $handshake == *TLSv1.3* ]]; then
            green "[通过] TCP $port 的 REALITY 目标 TLS 1.3 握手"
          else
            red "[失败] TCP $port 的 REALITY 目标 TLS 1.3 握手失败"; ((failures+=1))
          fi
        else
          yellow "[未检查] 缺少 openssl/timeout，无法验证 REALITY 目标握手。"
        fi
      fi
    done < <(jq -r '.inbounds[] | [(.port|tostring), (.streamSettings.security // "none"), (.streamSettings.realitySettings.serverNames[0] // "-")] | @tsv' "$CONFIG_FILE")
  fi

  for node_file in "$NODES_DIR"/*.env; do
    [[ -f $node_file ]] || continue
    ((node_count+=1))
    if (
      # shellcheck disable=SC1090
      . "$node_file"
      show_connection_loaded "$CONFIG_FILE" >/dev/null || exit 1
      if profile_uses_tls && ! tls_chain_valid "$(tls_cert_path)"; then
        red "TLS 证书链未通过本机系统 CA 信任校验；检查完整链或客户端自建 CA 配置。" >&2
        exit 1
      fi
    ); then
      green "[通过] 入站 $(basename "$node_file" .env) 的导出参数与配置一致"
    else
      red "[失败] 入站 $(basename "$node_file" .env) 的链接参数或入口地址"; ((failures+=1))
    fi
  done
  if (( node_count == 0 )); then
    yellow "[未检查] 没有启用的入站状态文件。"
  fi
  yellow "本机检查不能验证云安全组、NAT 端口映射或客户端兼容性；请从客户端网络测试节点 TCP 端口。"

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
  printf '内核版本：%s\n' "$("$XRAY_BIN" version 2>/dev/null | head -n 1 || printf '不可用')"
  show_connection
}

update_core() (
  set -Eeuo pipefail
  [[ -x "$XRAY_BIN" && -r "$CONFIG_FILE" ]] || die "尚未安装。"
  local transaction changed=0 committed=0 was_active=0
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
  fetch_core "$transaction"
  XRAY_LOCATION_ASSET="$transaction/core" "$transaction/core/xray" run -test -config "$CONFIG_FILE"
  changed=1
  install_core_files "$transaction/core"
  if (( was_active )); then
    restart_checked || die "新内核未通过健康检查，正在回退。"
  fi
  committed=1
  green "Xray Core 已更新；原先停止的服务会保持停止。"
  "$XRAY_BIN" version | head -n 1
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
  rm -rf -- "$transaction_dir"
  exit "$status"
}

validate_manager() {
  local script=$1
  bash -n "$script" &&
    grep -qx 'readonly APP_NAME="v2ray-manager"' "$script" &&
    grep -Eq '^readonly MANAGER_VERSION="[0-9]+\.[0-9]+\.[0-9]+"$' "$script"
}

update_manager() (
  set -Eeuo pipefail
  local temporary revision url
  temporary=$(mktemp)
  trap 'rm -f -- "$temporary"' EXIT
  revision=${V2M_MANAGER_REF:-}
  if [[ -z $revision ]]; then
    revision=$(curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 \
      --max-time 60 "$MANAGER_API" | jq -r '.sha')
  fi
  [[ $revision =~ ^[0-9a-f]{40}$ ]] || die "管理脚本版本必须是完整的 Git 提交 SHA。"
  url="${MANAGER_URL%/main/v2ray.sh}/$revision/v2ray.sh"
  green "下载管理脚本提交：$revision"
  curl --fail --show-error --location --retry 3 --connect-timeout 15 --max-time 120 \
    --output "$temporary" "$url"
  validate_manager "$temporary" || die "下载的管理脚本未通过语法或项目标识检查，未更新。"
  [[ -f $MANAGER_BIN ]] || die "找不到当前管理脚本。"
  install -d -m 700 "$BACKUP_DIR"
  atomic_install "$MANAGER_BIN" "$BACKUP_DIR/manager.previous.sh" 700
  atomic_install "$temporary" "$MANAGER_BIN" 755
  green "管理脚本已更新。旧版本：$BACKUP_DIR/manager.previous.sh；可运行 v2ray rollback.sh 恢复。"
)

rollback_manager() {
  local previous="$BACKUP_DIR/manager.previous.sh"
  [[ -r $previous ]] || die "没有可恢复的管理脚本。"
  validate_manager "$previous" || die "备份管理脚本未通过校验。"
  atomic_install "$previous" "$MANAGER_BIN" 755 || die "管理脚本恢复失败。"
  green "已恢复上一版管理脚本，重新运行 v2ray 即可。"
}

uninstall_xray() {
  read -r -p "将停止服务并删除 Xray 程序与 /etc/xray 配置。继续？[y/N] " answer
  [[ ${answer,,} == y || ${answer,,} == yes ]] || return
  systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$SERVICE_FILE" "$XRAY_BIN" "$MANAGER_BIN"
  rm -rf "$CONFIG_DIR" "$ASSET_DIR"
  if [[ -e "$LEGACY_MANAGER_BACKUP" ]]; then
    install -m 755 "$LEGACY_MANAGER_BACKUP" "$MANAGER_BIN"
    green "已恢复安装前的 v2ray 管理命令。"
  fi
  systemctl daemon-reload
  green "已卸载本脚本创建的 Xray 程序与配置。xray 系统账户和 $BACKUP_DIR 中的备份已保留。"
}

runtime_menu() {
  printf '\n%s\n' '----- 运行管理 -----'
  printf '%s\n' '1) 启动服务' '2) 停止服务' '3) 重启服务' '4) 查看状态' '5) 查看日志' '0) 返回'
  read -r -p '请选择 [0-5]:' choice
  case "$choice" in
    1) service_action start ;; 2) service_action stop ;; 3) service_action restart ;;
    4) show_status ;; 5) show_logs ;; 0) return ;; *) yellow "无效选择。" ;;
  esac
}

maintenance_menu() {
  printf '\n%s\n' '----- 维护工具 -----'
  printf '%s\n' '1) 更新 Xray Core' '2) 更新管理脚本' '3) 运行综合诊断' \
    '4) 备份配置' '5) 恢复最近备份' '6) 轮换 REALITY 密钥' '7) 恢复上一版管理脚本' \
    '8) Speedtest 服务器测速' '0) 返回'
  read -r -p '请选择 [0-8]:' choice
  case "$choice" in
    1) update_core ;; 2) update_manager ;; 3) doctor || true ;; 4) manual_backup ;;
    5) restore_latest ;; 6) rotate_reality_keys ;; 7) rollback_manager ;;
    8) run_speedtest || true ;;
    0) return ;; *) yellow "无效选择。" ;;
  esac
}

show_help() {
  printf '%s\n' \
    '直接运行 v2ray 打开主菜单。' \
    'v2ray add      添加新入站' \
    'v2ray inbounds 查看入站列表' \
    'v2ray links    输出全部启用入站链接' \
    'v2ray link <入站ID> <CDN地址> 以 443 导出 TLS XHTTP/WS 优选地址链接' \
    'v2ray firewall 自动放行已启用入站的本机 UFW/firewalld 端口' \
    'v2ray speedtest 运行服务器网络测速' \
    'v2ray caddy    管理 Caddy 伪装网站和本机反向代理' \
    'v2ray doctor   运行综合诊断' \
    'v2ray help     查看完整命令用法'
}

show_about() {
  printf '\n%s\n' "----------- ${APP_NAME} -----------"
  printf '作者: %s\n版本: %s\n内核: %s\n协议: VLESS + REALITY/TLS + RAW/XHTTP/gRPC/WebSocket\n仓库: https://github.com/0157Martin/v2ray-manager\n\n' \
    "$AUTHOR" "$MANAGER_VERSION" "$("$XRAY_BIN" version 2>/dev/null | head -n 1 || printf '未安装')"
}

menu() {
  while :; do
    clear || true
    local core_version service_state
    core_version=$("$XRAY_BIN" version 2>/dev/null | head -n 1 || printf '未安装')
    if systemctl is-active --quiet "$SERVICE_NAME"; then service_state='running'; else service_state='stopped'; fi
    printf '%s\n' "---------- ${APP_NAME} v${MANAGER_VERSION} by ${AUTHOR} ----------"
    printf 'Xray: %s  状态: ' "$core_version"
    if [[ $service_state == running ]]; then green "$service_state"; else red "$service_state"; fi
    printf '\n%s\n' \
      '1) 安装 / 添加第一个入站' '2) 添加新入站' '3) 管理入站' \
      '4) 查看全部链接' '5) 服务管理' '6) 维护工具' '7) Caddy 网站管理' '8) 卸载' '0) 退出'
    read -r -p "请选择：" choice
    case "$choice" in
      1) install_xray; pause ;;
      2) add_inbound; pause ;;
      3) manage_inbounds_menu; pause ;;
      4) show_all_links; pause ;;
      5) runtime_menu; pause ;;
      6) maintenance_menu; pause ;;
      7) caddy_menu; pause ;;
      8) uninstall_xray; pause ;;
      0) exit 0 ;;
      *) yellow "无效选择。"; pause ;;
    esac
  done
}

main() {
  require_root
  case "${1:-menu}" in
    menu) menu ;;
    install) install_xray ;;
    add) add_inbound ;;
    inbounds) list_inbounds ;;
    links) show_all_links ;;
    firewall) open_enabled_inbound_ports ;;
    info) show_info ;;
    config|change) change_menu ;;
    link) show_connection "${2:-}" "${3:-}" ;;
    client) export_client "${2:-}" ;;
    cert-refresh) refresh_tls_certificates "${2:-}" ;;
    status) show_status ;;
    start|stop|restart) service_action "$1" ;;
    log) show_logs ;;
    speedtest|speettest) run_speedtest ;;
    caddy) caddy_command "${2:-menu}" "${3:-}" "${4:-}" "${5:-}" ;;
    update) update_core ;;
    update.sh) update_manager ;;
    rollback.sh) rollback_manager ;;
    rotate) rotate_reality_keys ;;
    backup) manual_backup ;;
    restore) restore_latest ;;
    doctor) doctor ;;
    uninstall) uninstall_xray ;;
    version) printf '%s %s by %s\n' "$APP_NAME" "$MANAGER_VERSION" "$AUTHOR" ;;
    about) show_about ;;
    help|-h|--help) show_help; printf '%s\n' "用法：v2ray [install|add|inbounds|links|info|change|config|link [入站ID] [CDN地址]|client [入站ID]|status|start|stop|restart|log|speedtest|caddy [install|static|reverse|xray|status|log]|update|update.sh|rollback.sh|rotate|backup|restore|doctor|firewall|about|uninstall]" ;;
    *) die "未知命令：$1。输入 v2ray help 查看可用命令。" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
