#!/usr/bin/env bash
# Modern Xray/VLESS installer and manager, exposed through the v2ray command.
# Supported hosts: Debian and Ubuntu with systemd. Run as root.
# Author: 0157Martin (https://github.com/0157Martin)
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

readonly APP_NAME="v2ray-manager"
readonly AUTHOR="0157Martin"
readonly MANAGER_VERSION="5.5.12"
readonly DATA_SCHEMA_VERSION="2"
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
readonly WARP_PROXY_PORT="40000"
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

# A short ANSI half-block animation sampled from the supplied bamboo scenes.
# It deliberately avoids terminal image protocols so SSH and ordinary terminals
# remain usable. Set V2M_NO_ANIMATION=1 or V2M_ANIMATION=off to suppress it.
# V2M_ANIMATION=on is useful when a terminal multiplexer does not expose its TTY.
menu_image_frame() {
  local frame=$1 encoded
  case "$frame" in
    guardians) encoded='H4sIAH0wv2oC/8VXwW3DMAz8d4UsIeIECEFH6QzZoVN0wE5Sp2ls0jmKlGsnP4KgdRKPR9Knj3N5l1Iu31+fp6tdcTMhs6kjAO2u7TEidqMtEW2KeHRvNFd4L7GnBDnJynyqc/tnlsubG6bBhi+6R7prO+CwgyhyynkPdn85wgSh0EKC3Xu2fYnDMSQ/U12jKrqbCw1rhrQplKxE+i1ZQZoUFf6LgoiQZH6ErYIj2lwcLzT1fYKEi07YhCJlHmdOs3YFuR+ndBqZHtswIFgetczXGU9jjyY2oY4UPxq2T5B+APtahsaT0xN1WmFJ4pXQvbs24UoZDG8OAAvYMnT7UgXbwLTXVpPE7Q1ee9taN50GRwgR4+1q92y5STWV/rqaGaeINrAUPRJOn9XN2SuG5oy/XTtd1wi8kYsU167hBlM5b1S5VgRDW1BYs80QJMmucNOPlTjJIRxV6WEg0cxNPCHTR7j/H7vt6Kh3xeJp1RQUehLu7XBWa8ibFL5QzLH/Nq/+2i5U5wb/CBIfQn7vk/wK9wNtX46lTxAAAA==' ;;
    dash) encoded='H4sIAH0wv2oC/7VXwXHEMAj8p4VrQgye0XiulKvhekgVKTCVxI7j84JAIJ/z2+QQlmF3wbcH851KeX5/fd4ecxF44g1iSCfcTVP/jlY7ZPn/HjJXjE7D5EUuwZkCLDF77ZIpIRyqvsPy/Fj+hp/oPu1nywuuZ+nUxfhc2WPIbrfYwS1tJLT4KaHJ4GrTTZWmhu3GRxZoDtReqWWo3hgRXliFUPdkJ3lIc4ETZzN5BuWyhpBFc5DEEWxb10tFEEatS3FoK3FXHc7CQaVbQw4d5vGABIbd+lxG0WdycI2qsrWIsRnO3TwSxq4R9At7dJAOHHcGKgIRGIyMVRcts5Mxzgv7pTbSr3e8ZmJHk3yzvHq8vJjgVNBzzo1zqx4uLkJVrcBwXLKAex9JtJQaj3eMJls2CokY7k4ZG63K65xHczXn4izxZDTxN0sdUI8hJKkpaqzYNuiOXZYLl0TP2dlUln48NfVV6xy5g8j0y4QFp2TFXad03EcPVDIFVCKxUW/FvXBUtcuBaxfkca2oIdT6gL1422+v7MMQH4uFngcmwJBtEnqis+8mZqWNzY0G+ULBtw1ej7xknQ3un2G8HWUWbo4+UN76Iq3xkhRVFkShyFq6zROr2w/E6sKmTRAAAA==' ;;
    *) return 1 ;;
  esac
  printf '%s' "$encoded" | base64 -d 2>/dev/null | gzip -dc 2>/dev/null
}

menu_animation() (
  [[ ${V2M_NO_ANIMATION:-0} != 1 ]] || return 0
  case "${V2M_ANIMATION:-auto}" in
    off) return 0 ;;
    on) ;;
    auto) [[ -t 0 && -t 1 && ${TERM:-dumb} != dumb ]] || return 0 ;;
    *) return 0 ;;
  esac
  if command -v base64 >/dev/null 2>&1 && command -v gzip >/dev/null 2>&1 && menu_image_frame guardians; then
    sleep 0.35
    printf '\033[10A'
    menu_image_frame dash
    sleep 0.35
    clear || true
  else
    printf '\033[38;5;108m\n  │  │  │     竹 影 守 护\n\033[38;5;222m      ◉      ──╲    ╱──\n\033[0m'
    sleep 0.12
    printf '\033[2A\033[38;5;108m  │  │  │     竹 影 守 护\n\033[38;5;220m  ────────╲  剑 光 突 进  ╱────────\n\033[0m'
    sleep 0.12
  fi
)

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
  apt-get install -y ca-certificates curl unzip jq coreutils iproute2 tar openssl gnupg
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
valid_node_id() { [[ $1 =~ ^[A-Za-z0-9._-]+$ ]]; }
valid_server_name() { [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && $1 == *.* && $1 != *..* ]]; }
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
valid_profile() { [[ $1 == vless-reality-raw || $1 == vless-reality-xhttp || $1 == vless-reality-grpc || $1 == vless-tls-raw || $1 == vless-tls-xhttp || $1 == vless-tls-ws || $1 == vless-tls-grpc || $1 == trojan-reality-raw || $1 == vmess-tcp || $1 == vmess-tls-ws || $1 == vmess-tls-grpc || $1 == trojan-tls-ws ]]; }
profile_uses_tls() { [[ ${PROFILE:-} == *-tls-* ]]; }
profile_uses_reality() { [[ ${PROFILE:-vless-reality-raw} == *-reality-* ]]; }

profile_group() {
  case ${PROFILE:-vless-reality-raw} in
    *-reality-*) printf 'reality' ;;
    *-tls-xhttp|*-tls-ws|*-tls-grpc) printf 'http-tls' ;;
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
  esac
}

choose_profile() {
  local choice default_path
  printf '%s\n' \
    '--- 直连 / Cloudflare 灰云 DNS（不能经过普通橙云）---' \
    '1) VLESS-REALITY-Vision-RAW  [高级：目标站/客户端兼容性通过检测后使用]' \
    '2) VLESS-REALITY-XHTTP       [新式 HTTP 传输；REALITY 仍须直连]' \
    '3) VLESS-REALITY-gRPC        [HTTP/2 传输；REALITY 仍须直连]' \
    '--- HTTP/CDN / Cloudflare 橙云（需要自有域名）---' \
    '4) VLESS-XHTTP-TLS           [优先推荐：适合 Caddy/CDN]' \
    '5) VLESS-WebSocket-TLS       [客户端兼容广，适合 Caddy/CDN]' \
    '6) VLESS-gRPC-TLS            [适合现有 HTTP/2 反向代理]' \
    '--- 其他直连协议 ---' \
    '7) Trojan-REALITY-RAW        [Trojan 兼容；REALITY 仍须直连]' \
    '--- 旧版兼容（非默认推荐）---' \
    '8) VMess-TCP                 [无 TLS，仅限兼容或可信链路]' \
    '9) VMess-WebSocket-TLS       [老客户端及 CDN 兼容]' \
    '10) VMess-gRPC-TLS           [兼容既有 HTTP/2 反向代理]' \
    '11) Trojan-WebSocket-TLS     [传统 Trojan + WS + TLS]' \
    '12) VLESS-TLS-Vision-RAW     [自有证书、直连；RAW 不走橙云]'
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
    --arg extraIds "${EXTRA_UUIDS:-}" \
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
        settings: (if ($profile | startswith("trojan-")) then {clients: (([$id] + ($extraIds | split(",") | map(select(length > 0)))) | map({password: .}))}
        elif ($profile | startswith("vmess-")) then {clients: (([$id] + ($extraIds | split(",") | map(select(length > 0)))) | map({id: ., alterId: 0}))}
        else {
          clients: (([$id] + ($extraIds | split(",") | map(select(length > 0)))) | map({id: .} + (if ($profile == "vless-reality-raw" or $profile == "vless-tls-raw") then {flow: "xtls-rprx-vision"} else {} end))),
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

apply_warp_config() {
  local config_file=$1 mode domains strategy
  [[ -r $WARP_STATE_FILE ]] || return 0
  WARP_MODE=off
  WARP_DOMAINS=''
  WARP_IP_STRATEGY=UseIPv4v6
  # This file is generated by this script with mode 0600.
  # shellcheck disable=SC1090
  . "$WARP_STATE_FILE"
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
  temporary=$(mktemp)
  jq --arg mode "$mode" --arg domains "$domains" --arg strategy "$strategy" --argjson port "$WARP_PROXY_PORT" '
    .outbounds += [{protocol:"socks",tag:"warp",targetStrategy:$strategy,settings:{servers:[{address:"127.0.0.1",port:$port}]}}]
    | .routing = {
        domainStrategy:"AsIs",
        rules: ([{type:"field",ip:["geoip:private"],outboundTag:"direct"}]
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
    install -m 640 -o root -g xray "$temporary" "$CONFIG_FILE" || return 1
  fi
)

write_empty_config() {
  ensure_service_user
  install -d -m 755 "$CONFIG_DIR"
  install -d -m 700 "$NODES_DIR"
  validate_pending_config empty
  write_data_schema_marker "$STATE_FILE"
}

save_current_node() (
  umask 077
  local destination=$1 temporary
  temporary=$(mktemp "${destination}.XXXXXX") || return 1
  trap 'rm -f -- "$temporary"' EXIT
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
EOF
  mv -f -- "$temporary" "$destination"
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
    . "$node_file" || return 1
    node_id=$(basename "$node_file" .env)
    rendered="$work_dir/${node_id}.json"
    render_config "$rendered" || return 1
    jq --arg tag "$node_id" '.inbounds[0].tag=$tag | .inbounds[0]' "$rendered" > "$work_dir/inbound.json" || return 1
    jq --slurpfile inbound "$work_dir/inbound.json" '. + $inbound' "$combined" > "$work_dir/next.json" || return 1
    mv "$work_dir/next.json" "$combined" || return 1
  done
  jq -n --slurpfile inbounds "$combined" '{log:{loglevel:"warning"},inbounds:$inbounds[0],outbounds:[{protocol:"freedom",tag:"direct"},{protocol:"blackhole",tag:"block"}]}' > "$work_dir/config.json" || return 1
  apply_warp_config "$work_dir/config.json" || return 1
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
  . "$STATE_FILE"
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
  install -m 640 -o root -g xray "$temp_dir/config.json" "$CONFIG_FILE" || return 1
  install -m 600 -o root -g root "$temp_dir/manager.env" "$STATE_FILE" || return 1
  if [[ -f $temp_dir/warp.env ]]; then
    install -m 600 -o root -g root "$temp_dir/warp.env" "$WARP_STATE_FILE" || return 1
  else
    rm -f -- "$WARP_STATE_FILE" || return 1
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
    . "$node_file"
  else
    load_state
  fi
}

show_connection() (
  local node_id=${1:-} address_override=${2:-}
  if [[ -n $node_id ]]; then
    if ! valid_node_id "$node_id" || [[ ! -f $NODES_DIR/$node_id.env ]]; then
      red "找不到启用的入站：$node_id" >&2
      return 1
    fi
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
    valid_server_name "$address_override" || { red "CDN 入口必须填写域名；为避免暴露 IP，链接不接受优选 IP 地址。" >&2; return 1; }
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
    if ! valid_node_id "$1" || [[ ! -f $NODES_DIR/$1.env ]]; then
      red "找不到启用的入站：$1" >&2
      return 1
    fi
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
  local credential link_name index=0
  local -a credentials extra_credentials
  local cdn_address=${2:-}
  address=${cdn_address:-$(server_address)}
  client_port=$PORT
  [[ -z $cdn_address ]] || client_port=443
  if ! valid_server_name "$address"; then
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
  if profile_uses_tls && ! tls_pair_valid "${TLS_CERT_PATH_OVERRIDE:-$(tls_cert_path)}" "${TLS_KEY_PATH_OVERRIDE:-$(tls_key_path)}"; then
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
    else
      link="${protocol}://${credential}@${uri_address}:${client_port}?${query}#${encoded_name}"
    fi
    (( ${#credentials[@]} == 1 )) || printf '[%s/%s] ' "$index" "${#credentials[@]}"
    cyan_value "$link"; printf '\n'
  done
  printf '%s\n\n' '---------------------- END ----------------------'
  yellow "请确认云服务商安全组已放行 TCP ${PORT}；可执行 v2ray firewall 放行已启用入站的本机 UFW/firewalld 规则。私钥仅保存在服务器，不要公开。"
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
  . "$EDIT_NODE_FILE"
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
  local candidate=${1:-24443}
  while ss -H -lnt "sport = :${candidate}" 2>/dev/null | grep -q .; do ((candidate+=1)); done
  printf '%s' "$candidate"
}

list_inbounds() (
  install -d -m 700 "$NODES_DIR"
  local node_file state node_id group wanted_group heading link_count
  printf '\n%-22s %-7s %-30s %-8s %s\n' '入站 ID' '状态' '协议组合' '链接数' '端口'
  printf '%s\n' '--------------------------------------------------------------------------------'
  for wanted_group in reality http-tls other; do
    case $wanted_group in
      reality) heading='REALITY 直连（灰云 / DNS only）' ;;
      http-tls) heading='TLS HTTP/CDN（XHTTP / WebSocket / gRPC）' ;;
      other) heading='其他直连与旧版兼容' ;;
    esac
    printf '\n[%s]\n' "$heading"
    for node_file in "$NODES_DIR"/*.env "$NODES_DIR"/*.disabled; do
      [[ -e $node_file ]] || continue
      # Node files are generated by this script with mode 0600.
      EXTRA_UUIDS=''
      # shellcheck disable=SC1090
      . "$node_file"
      group=$(profile_group)
      [[ $group == "$wanted_group" ]] || continue
      node_id=$(basename "$node_file"); node_id=${node_id%.env}; node_id=${node_id%.disabled}
      [[ $node_file == *.env ]] && state='启用' || state='停用'
      link_count=1
      [[ -z ${EXTRA_UUIDS:-} ]] || link_count=$(( $(tr -cd ',' <<<"$EXTRA_UUIDS" | wc -c) + 2 ))
      printf '%-22s %-7s %-30s %-8s %s\n' "$node_id" "$state" "$(profile_name)" "$link_count" "$PORT"
    done
  done
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
  green "已添加入站：$node_id"
  open_enabled_inbound_ports
  show_connection_loaded "$CONFIG_FILE"
}

show_all_links() (
  local node_file node_id failures=0 count=0
  for node_file in "$NODES_DIR"/*.env; do
    [[ -e $node_file ]] || continue
    # shellcheck disable=SC1090
    EXTRA_UUIDS=''
    # shellcheck disable=SC1090
    . "$node_file"
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
  . "$node_file"
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
  (( index <= ${#SUB_LINK_CREDENTIALS[@]} )) || die "链接序号不存在：$index"
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
    printf '\n%s\n' '----- 子链接用户管理 -----'
    list_inbounds
    printf '%s\n' '1) 查看指定入站的链接用户' '2) 新增链接用户' '3) 删除指定链接用户' \
      '4) 重新生成指定链接凭据' '5) 输出指定入站全部链接' '6) 兼容模式：设置链接总数' \
      '0) 返回连接与导出'
    read -r -p '请选择 [0-6]:' choice
    case "$choice" in
      1) read -r -p '请输入启用的入站 ID：' node_id; list_sub_links "$node_id"; pause ;;
      2) read -r -p '请输入启用的入站 ID：' node_id; read -r -p '新增数量 [1]：' count; add_sub_links "$node_id" "${count:-1}"; pause ;;
      3)
        read -r -p '请输入启用的入站 ID：' node_id; list_sub_links "$node_id"
        read -r -p '请输入要删除的链接序号：' index
        read -r -p "确认删除第 $index 条链接？[y/N] " answer
        [[ ${answer,,} == y || ${answer,,} == yes ]] && delete_sub_link "$node_id" "$index"
        pause
        ;;
      4)
        read -r -p '请输入启用的入站 ID：' node_id; list_sub_links "$node_id"
        read -r -p '请输入要重新生成的链接序号：' index
        read -r -p "确认使第 $index 条旧链接失效并重新生成？[y/N] " answer
        [[ ${answer,,} == y || ${answer,,} == yes ]] && replace_sub_link "$node_id" "$index"
        pause
        ;;
      5) read -r -p '请输入启用的入站 ID：' node_id; show_connection "$node_id"; pause ;;
      6) read -r -p '请输入启用的入站 ID：' node_id; read -r -p '请输入链接总数 [1-10]：' count; set_sub_link_count "$node_id" "$count"; pause ;;
      0) return ;;
      *) yellow '无效选择。'; pause ;;
    esac
  done
}

SELECTED_NODE_FILES=()
select_node_files() {
  local wanted_state=${1:-any} input node_id candidate
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
  (( ${#SELECTED_NODE_FILES[@]} > 0 )) || die '没有符合条件的入站。'
}

selected_node_names() {
  local file
  for file in "${SELECTED_NODE_FILES[@]}"; do basename "$file" | sed -E 's/\.(env|disabled)$//'; done
}

disable_inbound() {
  local node_file
  select_node_files enabled
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
          . "$node_file"
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
          . "$node_file"
          profile_uses_reality || die "$(basename "$node_file") 不是 REALITY 入站，批量操作已取消。"
        done
        for node_file in "${SELECTED_NODE_FILES[@]}"; do
          # shellcheck disable=SC1090
          . "$node_file"
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
          . "$node_file"
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
    . "$node_file"
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
  select_node_files disabled
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
    printf '\n%s\n' '----- 入站管理 -----'
    printf '%s\n' '1) 查看入站列表' '2) 添加新入站' '3) 修改入站（支持批量）' '4) 停用入站（支持批量）' \
      '5) 启用入站（支持批量）' '6) 删除入站（支持批量）' '0) 返回主菜单'
    read -r -p '请选择 [0-6]:' choice
    case "$choice" in
      1) list_inbounds; pause ;; 2) add_inbound; pause ;; 3) modify_inbound; pause ;;
      4) disable_inbound; pause ;; 5) enable_inbound; pause ;; 6) delete_inbound; pause ;;
      0) return ;; *) yellow "无效选择。"; pause ;;
    esac
  done
}

export_menu() {
  local choice node_id cdn_address
  while :; do
    printf '\n%s\n' '----- 连接与导出 -----'
    printf '%s\n' '1) 查看入站列表' '2) 输出全部启用链接' '3) 输出指定入站链接' \
      '4) 使用 Cloudflare/CDN 域名输出链接' '5) 子链接用户管理（增删改查）' \
      '6) 导出 Xray 客户端 JSON' '0) 返回主菜单'
    read -r -p '请选择 [0-6]:' choice
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
    add) [[ -n ${2:-} ]] || die '用法：v2ray users add <入站ID> [数量]'; add_sub_links "$2" "${3:-1}" ;;
    delete|del|remove) [[ -n ${2:-} && -n ${3:-} ]] || die '用法：v2ray users delete <入站ID> <序号>'; delete_sub_link "$2" "$3" ;;
    replace|reset) [[ -n ${2:-} && -n ${3:-} ]] || die '用法：v2ray users replace <入站ID> <序号>'; replace_sub_link "$2" "$3" ;;
    set) [[ -n ${2:-} && -n ${3:-} ]] || die '用法：v2ray users set <入站ID> <1-10>'; set_sub_link_count "$2" "$3" ;;
    *)
      if [[ -n ${2:-} && $2 =~ ^([1-9]|10)$ ]]; then
        set_sub_link_count "$1" "$2"
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
    printf '\n%s\n' '----- 路由与延迟测试 -----'
    printf '%s\n' '1) 测试 VPS → 目标的回程路由、丢包和延迟' \
      '2) 显示客户端 → VPS 去程测试命令' '3) Speedtest 带宽测速' '0) 返回维护菜单'
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

find_caddy_xray_defaults() {
  local wanted_domain=$1 node_dir=${CADDY_NODE_DIR_OVERRIDE:-$NODES_DIR} node_file
  local PROFILE SERVER_NAME PORT PATH_VALUE
  [[ -d $node_dir ]] || return 1
  for node_file in "$node_dir"/*.env; do
    [[ -f $node_file ]] || continue
    PROFILE=''; SERVER_NAME=''; PORT=''; PATH_VALUE=''
    # Node files are generated by this script with mode 0600.
    # shellcheck disable=SC1090
    . "$node_file"
    case "$PROFILE" in
      vless-tls-xhttp|vless-tls-ws|vmess-tls-ws|trojan-tls-ws) ;;
      *) continue ;;
    esac
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

caddy_menu() {
  local choice domain upstream path suggested_upstream suggested_path
  while :; do
    printf '\n%s\n' '----- Caddy 网站管理 -----'
    printf '%s\n' '1) 安装 Caddy' '2) 创建静态伪装网站' '3) 创建本机反向代理' \
      '4) 创建 Xray XHTTP/WS 路径反代' '5) 查看 Caddy 状态' '6) 查看 Caddy 日志' '0) 返回主菜单'
    read -r -p '请选择 [0-6]:' choice
    case "$choice" in
      1) caddy_ports_available && install_caddy && green "Caddy 已安装。"; pause ;;
      2) read -r -p '网站域名：' domain; configure_caddy_site static "$domain" || true; pause ;;
      3)
        read -r -p '网站域名：' domain
        read -r -p '本机后端 [127.0.0.1:8080]：' upstream
        configure_caddy_site reverse "$domain" "${upstream:-127.0.0.1:8080}" || true; pause
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
        configure_caddy_site xray "$domain" "$upstream" "$path" || true
        pause
        ;;
      5) systemctl --no-pager --full status caddy || true; pause ;;
      6) journalctl -u caddy -n 100 --no-pager || true; pause ;;
      0) return ;;
      *) yellow "无效选择。"; pause ;;
    esac
  done
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

warp_cli() {
  warp-cli --accept-tos "$@"
}

wait_for_warp_proxy() {
  local attempt
  for ((attempt=0; attempt<30; attempt++)); do
    if systemctl is-active --quiet warp-svc &&
      ss -H -lnt "sport = :${WARP_PROXY_PORT}" 2>/dev/null | grep -q .; then
      return 0
    fi
    sleep 1
  done
  return 1
}

configure_warp_proxy() {
  systemctl enable --now warp-svc || return 1
  warp_cli tunnel protocol set MASQUE || return 1
  warp_cli mode proxy || return 1
  warp_cli proxy port "$WARP_PROXY_PORT" || return 1
  warp_cli connect || return 1
  if ! wait_for_warp_proxy; then
    red "WARP 已发送连接命令，但 127.0.0.1:${WARP_PROXY_PORT} 在 30 秒内没有开始监听。" >&2
    warp_cli status >&2 || true
    return 1
  fi
  warp_trace >/dev/null
}

warp_is_connecting() {
  warp_cli status 2>/dev/null | grep -qi 'Connecting'
}

redact_warp_log() {
  sed -E \
    -e 's/(license|token|secret|private_key)[[:space:]]*[:=][[:space:]]*("[^"]*"|[^,}[:space:]]+)/\1=[REDACTED]/Ig' \
    -e 's/(public_key)[[:space:]]*[:=][[:space:]]*\[[^]]*\]/\1=[REDACTED]/Ig' \
    -e 's/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/[REDACTED-ID]/g'
}

warp_connectivity_diagnostics() {
  local log_output
  printf '%s\n' '----- WARP 上游连通性诊断 -----'
  printf '系统时间同步：'
  timedatectl show -p NTPSynchronized --value 2>/dev/null || printf '未知\n'
  printf '%s\n' 'IPv4 路由：'
  ip route get 162.159.198.2 2>&1 || true
  printf '%s\n' 'IPv6 路由：'
  ip -6 route get 2606:4700:103::2 2>&1 || true
  if command -v ufw >/dev/null 2>&1; then
    printf '%s\n' 'UFW 状态：'
    ufw status verbose 2>&1 || true
  fi
  printf '%s\n' 'WARP 状态：'
  warp_cli status 2>&1 || true
  printf '%s\n' 'warp-svc 最近日志：'
  log_output=$(journalctl -u warp-svc -n 300 --no-pager 2>&1 | \
    grep -Ei 'Connecting|HappyEyeballs|ERROR|WARN|failed|failure|timeout|unreachable|refused' | tail -n 30 || true)
  if [[ -n $log_output ]]; then
    redact_warp_log <<<"$log_output"
  else
    yellow "最近日志中没有匹配的连接错误。"
  fi
  yellow "Local Proxy 使用 MASQUE。服务器和服务商出站防火墙需允许 Cloudflare WARP 的 UDP 443、500、1701、4500、4443、8443、8095；并允许 TCP 443 回退。"
  yellow "状态卡在 Connecting/Happy Eyeballs 表示上游隧道未建立，不是 127.0.0.1:${WARP_PROXY_PORT} 本身的防火墙问题。"
}

reregister_warp() {
  warp_cli disconnect >/dev/null 2>&1 || true
  warp_cli registration delete >/dev/null 2>&1 || true
  timeout 45 warp-cli --accept-tos registration new || return 1
}

install_warp() {
  require_supported_os
  local codename key_file
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg
  # shellcheck disable=SC1091
  . /etc/os-release
  codename=${VERSION_CODENAME:-}
  [[ -n $codename ]] || die "无法识别系统发行版代号。"
  key_file=$(mktemp)
  curl --fail --show-error --location --retry 3 https://pkg.cloudflareclient.com/pubkey.gpg -o "$key_file"
  gpg --batch --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg "$key_file"
  rm -f -- "$key_file"
  printf 'deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ %s main\n' "$codename" \
    > /etc/apt/sources.list.d/cloudflare-client.list
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y cloudflare-warp
  systemctl enable --now warp-svc
  if ! warp_cli registration show >/dev/null 2>&1; then
    timeout 45 warp-cli --accept-tos registration new || die "WARP 注册失败。"
  fi
  configure_warp_proxy || {
    if warp_is_connecting; then
      warp_connectivity_diagnostics
      red "WARP 注册有效，但 MASQUE 上游连接被网络阻断或不可达；未重复注册设备。" >&2
      return 1
    fi
    yellow "首次连接失败且状态并非 Connecting，正在重新注册 WARP 设备…"
    reregister_warp || { red "WARP 重新注册失败。" >&2; return 1; }
    configure_warp_proxy || { red "重新注册后 WARP 本机代理仍未启动。" >&2; return 1; }
  }
  green "WARP 本机代理已安装：127.0.0.1:${WARP_PROXY_PORT}。"
  yellow "尚未改变 Xray 出站；请在 WARP 菜单中选择分流策略。"
}

warp_trace() {
  command -v warp-cli >/dev/null 2>&1 || { red "WARP 尚未安装。" >&2; return 1; }
  local trace
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
  warp_trace >/dev/null
  [[ $mode == selective || $mode == all ]] || die "WARP 策略模式无效。"
  [[ $mode == all ]] || domains=$(normalize_warp_domains "$domains")
  if [[ -r $WARP_STATE_FILE ]]; then
    WARP_IP_STRATEGY=UseIPv4v6
    # shellcheck disable=SC1090
    . "$WARP_STATE_FILE"
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
    green "全部协议的公网 TCP 流量已统一通过 WARP；UDP 和私有地址仍使用直连。"
  else
    green "全部协议已统一应用 WARP 域名分流：$domains"
  fi
}

disable_warp_policy() {
  [[ -x $XRAY_BIN && -r $CONFIG_FILE ]] || die "请先安装 Xray。"
  [[ -f $WARP_STATE_FILE ]] || { yellow "Xray 当前没有启用 WARP 策略。"; return; }
  create_backup
  rm -f -- "$WARP_STATE_FILE"
  rebuild_or_restore
  restart_or_rollback
  green "全部协议已恢复使用服务器原生出口。"
}

show_warp_status() {
  if command -v warp-cli >/dev/null 2>&1; then
    warp_cli status || true
  else
    yellow "WARP 客户端未安装。"
  fi
  if [[ -r $WARP_STATE_FILE ]]; then
    WARP_MODE=off; WARP_DOMAINS=''; WARP_IP_STRATEGY=UseIPv4v6
    # shellcheck disable=SC1090
    . "$WARP_STATE_FILE"
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
  . "$WARP_STATE_FILE"
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
  printf '%s\n' '1) 自动双栈（IPv4 优先，失败后尝试 IPv6）' '2) 仅 IPv4' '3) 仅 IPv6' '0) 返回'
  read -r -p '请选择 [0-3]：' choice
  case "$choice" in
    1) set_warp_ip_strategy UseIPv4v6 ;;
    2) set_warp_ip_strategy UseIPv4 ;;
    3) set_warp_ip_strategy UseIPv6 ;;
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
  command -v warp-cli >/dev/null 2>&1 || die "WARP 尚未安装，请先选择安装。"
  if ! warp_cli registration show >/dev/null 2>&1; then
    timeout 45 warp-cli --accept-tos registration new || die "WARP 重新注册失败。"
  fi
  if ! configure_warp_proxy; then
    if warp_is_connecting; then
      warp_connectivity_diagnostics
      die "MASQUE 上游连接仍停留在 Connecting；请先放行所列出站端口或联系 VPS 服务商。"
    fi
    yellow "现有 WARP 注册无法启动本机代理，正在重新注册免费 WARP 设备…"
    reregister_warp || die "WARP 重新注册失败。"
    configure_warp_proxy || die "重新注册后本机代理仍未启动；请运行 warp-cli status 和 journalctl -u warp-svc。"
  fi
  if [[ -r $CONFIG_FILE ]]; then
    create_backup
    rebuild_or_restore
    restart_or_rollback
  fi
  green "WARP 本机代理和 Xray 出站配置已修复并重新校验。"
}

uninstall_warp() {
  [[ -f $WARP_STATE_FILE ]] && disable_warp_policy
  if command -v warp-cli >/dev/null 2>&1; then
    warp_cli disconnect >/dev/null 2>&1 || true
    warp_cli registration delete >/dev/null 2>&1 || true
  fi
  apt-get remove -y cloudflare-warp
  rm -f -- /etc/apt/sources.list.d/cloudflare-client.list /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  green "WARP 客户端及 Xray WARP 策略已移除。"
}

warp_menu() {
  local choice domains answer
  while :; do
    printf '\n%s\n' '----- WARP 出站管理（对全部协议生效）-----'
    printf '%s\n' '1) 安装/初始化 WARP' '2) 查看 WARP 状态与出口 IP' \
      '3) 全部协议的公网 TCP 使用 WARP' '4) 指定域名使用 WARP（推荐）' \
      '5) IPv4 / IPv6 出站策略' '6) 流媒体与 ChatGPT 可用性检测' \
      '7) 停用 WARP 策略' '8) 修复/重新生成配置' '9) 卸载 WARP' '0) 返回主菜单'
    read -r -p '请选择 [0-9]：' choice
    case "$choice" in
      1) (install_warp) || true; pause ;;
      2) show_warp_status; (warp_trace) || true; pause ;;
      3)
        read -r -p '确认让全部协议的公网 TCP 流量通过 WARP？[y/N] ' answer
        if [[ ${answer,,} == y || ${answer,,} == yes ]]; then (set_warp_policy all) || true; fi
        pause
        ;;
      4)
        read -r -p '域名规则，逗号分隔 [geosite:netflix,domain:openai.com,domain:chatgpt.com]：' domains
        (set_warp_policy selective "${domains:-geosite:netflix,domain:openai.com,domain:chatgpt.com}") || true
        pause
        ;;
      5) (warp_ip_strategy_menu) || true; pause ;;
      6) (check_warp_services) || true; pause ;;
      7) (disable_warp_policy) || true; pause ;;
      8) (repair_warp) || true; pause ;;
      9)
        read -r -p '确认卸载 WARP 并恢复原生出口？[y/N] ' answer
        if [[ ${answer,,} == y || ${answer,,} == yes ]]; then (uninstall_warp) || true; fi
        pause
        ;;
      0) return ;;
      *) yellow "无效选择。"; pause ;;
    esac
  done
}

warp_command() {
  local action=${1:-menu}
  case "$action" in
    menu) warp_menu ;;
    install) install_warp ;;
    status) show_warp_status ;;
    test) warp_trace ;;
    diagnose) warp_connectivity_diagnostics ;;
    check) check_warp_services ;;
    repair) repair_warp ;;
    ipv4) set_warp_ip_strategy UseIPv4 ;;
    ipv6) set_warp_ip_strategy UseIPv6 ;;
    dual) set_warp_ip_strategy UseIPv4v6 ;;
    selective) [[ -n ${2:-} ]] || die "用法：v2ray warp selective <逗号分隔的域名规则>"; set_warp_policy selective "$2" ;;
    all) set_warp_policy all ;;
    off) disable_warp_policy ;;
    uninstall) uninstall_warp ;;
    *) die "未知 WARP 操作：$action" ;;
  esac
}

doctor() {
  local failures=0 port security target node_file node_count=0 fallback
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
    done < <(jq -r '.inbounds[] | [(.port|tostring), (.streamSettings.security // "none"), (.streamSettings.realitySettings.serverNames[0] // "-")] | @tsv' "$CONFIG_FILE")
  fi

  for node_file in "$NODES_DIR"/*.env; do
    [[ -f $node_file ]] || continue
    ((node_count+=1))
    if (
      # shellcheck disable=SC1090
      EXTRA_UUIDS=''
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

config_connection_fingerprint() {
  local config_file=$1
  jq -cS '[.inbounds[] | {
    tag, listen, port, protocol, settings, streamSettings
  }]' "$config_file" | sha256sum | awk '{print $1}'
}

write_data_schema_marker() (
  umask 077
  local state_file=$1 temporary
  temporary=$(mktemp "${state_file}.XXXXXX") || return 1
  trap 'rm -f -- "$temporary"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  {
    printf 'DATA_SCHEMA=%s\n' "$DATA_SCHEMA_VERSION"
    if [[ -f $state_file ]]; then awk '!/^DATA_SCHEMA=/' "$state_file" || return 1; fi
  } > "$temporary"
  mv -f -- "$temporary" "$state_file"
)

migrate_project_state() {
  local before after node_file credential
  local -a extra_credentials
  [[ -d $NODES_DIR ]] || { green "项目脚本已更新；当前没有需要迁移的入站状态。"; return 0; }
  compgen -G "$NODES_DIR/*.env" >/dev/null || {
    green "项目脚本已更新；当前没有启用的入站需要迁移。"
    return 0
  }
  [[ -r $CONFIG_FILE && -x $XRAY_BIN ]] || die "更新后迁移需要现有 Xray 配置和内核。"
  before=$(config_connection_fingerprint "$CONFIG_FILE")
  create_backup
  [[ -n ${LAST_BACKUP:-} ]] || die "无法创建更新前配置备份，已停止迁移。"

  for node_file in "$NODES_DIR"/*.env "$NODES_DIR"/*.disabled; do
    [[ -e $node_file ]] || continue
    DATA_SCHEMA=1
    EXTRA_UUIDS=''
    # Node files are generated by this script with mode 0600.
    # shellcheck disable=SC1090
    . "$node_file" || { restore_archive "$LAST_BACKUP"; die "无法读取入站状态，已恢复更新前配置。"; }
    [[ ${DATA_SCHEMA:-1} =~ ^[0-9]+$ ]] || {
      restore_archive "$LAST_BACKUP"
      die "入站数据版本无效，已恢复更新前配置。"
    }
    if ! valid_profile "$PROFILE" || ! valid_port "$PORT" || ! valid_uuid "$UUID"; then
      restore_archive "$LAST_BACKUP"
      die "入站状态未通过迁移校验，已恢复更新前配置。"
    fi
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
  after=$(config_connection_fingerprint "$CONFIG_FILE")
  if [[ $before != "$after" ]]; then
    restore_archive "$LAST_BACKUP"
    die "迁移导致连接参数发生非预期变化，已恢复原配置和原链接。"
  fi
  green "项目数据已迁移到版本 $DATA_SCHEMA_VERSION；现有链接参数保持不变。"
}

ensure_project_state_current() {
  local command_name=${1:-menu} node_file schema
  [[ $command_name != migrate && $command_name != uninstall ]] || return 0
  [[ -d $NODES_DIR ]] || return 0
  for node_file in "$NODES_DIR"/*.env; do [[ -f $node_file ]] && break; done
  [[ -f ${node_file:-} ]] || return 0
  schema=$(awk -F= '/^DATA_SCHEMA=/{print $2; exit}' "$node_file")
  [[ $schema == "$DATA_SCHEMA_VERSION" ]] && return 0
  yellow "检测到旧版项目数据，正在自动迁移并保护现有链接…"
  migrate_project_state
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
  if ! V2M_INTERNAL_MIGRATION=1 "$MANAGER_BIN" migrate; then
    atomic_install "$BACKUP_DIR/manager.previous.sh" "$MANAGER_BIN" 755 || true
    die "项目数据迁移失败，管理脚本已恢复到更新前版本。"
  fi
  green "项目脚本与数据结构已一键更新。旧版本：$BACKUP_DIR/manager.previous.sh；可运行 v2ray rollback.sh 恢复。"
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
  local choice
  while :; do
    printf '\n%s\n' '----- Xray 服务管理 -----'
    printf '%s\n' '1) 启动服务' '2) 停止服务' '3) 重启服务' '4) 查看状态' '5) 查看日志' '0) 返回主菜单'
    read -r -p '请选择 [0-5]:' choice
    case "$choice" in
      1) service_action start; pause ;; 2) service_action stop; pause ;; 3) service_action restart; pause ;;
      4) show_status; pause ;; 5) show_logs; pause ;; 0) return ;; *) yellow "无效选择。"; pause ;;
    esac
  done
}

maintenance_menu() {
  local choice
  while :; do
    printf '\n%s\n' '----- 维护与诊断 -----'
    printf '%s\n' '1) 更新 Xray Core' '2) 一键更新项目脚本并迁移数据' '3) 运行综合诊断' \
      '4) 检查并放行本机防火墙' '5) 备份配置' '6) 恢复最近备份' \
      '7) 轮换 REALITY 密钥' '8) 恢复上一版管理脚本' '9) 路由、丢包与延迟测试' \
      '10) 查看项目信息' '0) 返回主菜单'
    read -r -p '请选择 [0-10]:' choice
    case "$choice" in
      1) update_core; pause ;; 2) update_manager; pause ;; 3) doctor || true; pause ;;
      4) open_enabled_inbound_ports; pause ;; 5) manual_backup; pause ;; 6) restore_latest; pause ;;
      7) rotate_reality_keys; pause ;; 8) rollback_manager; pause ;; 9) route_test_menu ;;
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
    'v2ray link <入站ID> <CDN域名> 以 443 导出 TLS XHTTP/WS 链接' \
    'v2ray firewall 自动放行已启用入站的本机 UFW/firewalld 端口' \
    'v2ray speedtest 运行服务器网络测速' \
    'v2ray route [目标IP/域名] 测试回程路由、丢包和延迟' \
    'v2ray caddy    管理 Caddy 伪装网站和本机反向代理' \
    'v2ray warp     管理全部协议共用的 WARP 出站策略' \
    'v2ray upgrade  一键更新项目脚本、迁移数据并保留现有链接' \
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
    menu_animation
    local core_version service_state caddy_state active_nodes disabled_nodes install_label
    core_version=$("$XRAY_BIN" version 2>/dev/null | head -n 1 || printf '未安装')
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
    printf '%s\n' "---------- ${APP_NAME} v${MANAGER_VERSION} by ${AUTHOR} ----------"
    printf 'Xray: %s\n服务状态: ' "$core_version"
    if [[ $service_state == running ]]; then green "$service_state"; else red "$service_state"; fi
    printf 'Caddy: %s  入站: %s 启用 / %s 停用\n' "$caddy_state" "$active_nodes" "$disabled_nodes"
    printf '\n%s\n' \
      "1) $install_label" '2) 入站管理' '3) 连接与导出' '4) Xray 服务管理' \
      '5) Caddy 网站管理' '6) WARP 出站管理（全部协议）' '7) 维护与诊断' '8) 卸载项目' '0) 退出'
    read -r -p '请选择 [0-8]：' choice
    case "$choice" in
      1) install_xray; pause ;;
      2) manage_inbounds_menu ;;
      3) export_menu ;;
      4) runtime_menu ;;
      5) caddy_menu ;;
      6) warp_menu ;;
      7) maintenance_menu ;;
      8) uninstall_xray; pause ;;
      0) exit 0 ;;
      *) yellow "无效选择。"; pause ;;
    esac
  done
}

main() {
  if [[ ${1:-} != migrate || ${V2M_INTERNAL_MIGRATION:-0} != 1 ]]; then require_root; fi
  ensure_project_state_current "${1:-menu}"
  case "${1:-menu}" in
    menu) menu ;;
    install) install_xray ;;
    add) add_inbound ;;
    inbounds) list_inbounds ;;
    links) show_all_links ;;
    firewall) open_enabled_inbound_ports ;;
    info) show_info ;;
    config|change) change_menu "${2:-}" ;;
    link) show_connection "${2:-}" "${3:-}" ;;
    users) users_command "${@:2}" ;;
    client) export_client "${2:-}" ;;
    cert-refresh) refresh_tls_certificates "${2:-}" ;;
    status) show_status ;;
    start|stop|restart) service_action "$1" ;;
    log) show_logs ;;
    speedtest|speettest) run_speedtest ;;
    route) if [[ -n ${2:-} ]]; then route_latency_test "$2"; else route_test_menu; fi ;;
    caddy) caddy_command "${2:-menu}" "${3:-}" "${4:-}" "${5:-}" ;;
    warp) warp_command "${2:-menu}" "${3:-}" ;;
    update) update_core ;;
    upgrade|update.sh) update_manager ;;
    migrate) migrate_project_state ;;
    rollback.sh) rollback_manager ;;
    rotate) rotate_reality_keys "${2:-}" ;;
    backup) manual_backup ;;
    restore) restore_latest ;;
    doctor) doctor ;;
    uninstall) uninstall_xray ;;
    version) printf '%s %s by %s\n' "$APP_NAME" "$MANAGER_VERSION" "$AUTHOR" ;;
    about) show_about ;;
    help|-h|--help) show_help; printf '%s\n' "用法：v2ray [install|add|inbounds|links|users [list|show|add|delete|replace|set]|info|change|config|link [入站ID] [CDN域名]|client [入站ID]|status|start|stop|restart|log|speedtest|route [目标]|caddy [install|static|reverse|xray|status|log]|warp [install|status|test|diagnose|check|selective|all|ipv4|ipv6|dual|off|repair|uninstall]|update|upgrade|update.sh|rollback.sh|rotate|backup|restore|doctor|firewall|about|uninstall]" ;;
    *) die "未知命令：$1。输入 v2ray help 查看可用命令。" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
