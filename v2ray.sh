#!/usr/bin/env bash
# Modern Xray/VLESS installer and manager, exposed through the v2ray command.
# Supported hosts: Debian and Ubuntu with systemd. Run as root.
# Author: 0157Martin (https://github.com/0157Martin)
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

readonly APP_NAME="v2ray-manager"
readonly AUTHOR="0157Martin"
readonly MANAGER_VERSION="2.2.0"
readonly BIN_DIR="/usr/local/bin"
readonly MANAGER_BIN="$BIN_DIR/v2ray"
readonly XRAY_BIN="$BIN_DIR/xray-core"
readonly ASSET_DIR="/usr/local/share/xray"
readonly CONFIG_DIR="/etc/xray"
readonly CONFIG_FILE="$CONFIG_DIR/config.json"
readonly BACKUP_DIR="/var/backups/v2ray-manager"
readonly LEGACY_MANAGER_BACKUP="$BACKUP_DIR/legacy-v2ray-command"
readonly SERVICE_FILE="/etc/systemd/system/xray.service"
readonly STATE_FILE="$CONFIG_DIR/manager.env"
readonly RELEASE_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
readonly MANAGER_URL="https://raw.githubusercontent.com/0157Martin/v2ray-manager/main/v2ray.sh"
readonly SERVICE_NAME="xray"

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
  apt-get install -y ca-certificates curl unzip jq coreutils iproute2 tar
}

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

download_core() {
  install_dependencies
  local arch tag url temp_dir expected actual
  arch=$(arch_name)
  tag=$(curl --fail --silent --show-error --location -H 'Accept: application/vnd.github+json' "$RELEASE_API" | jq -r '.tag_name')
  [[ -n "$tag" && "$tag" != "null" ]] || die "无法读取 Xray Core 最新稳定版本。"
  url="https://github.com/XTLS/Xray-core/releases/download/${tag}/Xray-linux-${arch}.zip"
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN

  step "下载 Xray Core > ${tag} (${arch})"
  curl --fail --show-error --location --retry 3 --output "$temp_dir/xray.zip" "$url"
  curl --fail --show-error --location --retry 3 --output "$temp_dir/xray.zip.dgst" "${url}.dgst"
  expected=$(awk -F '= ' '/256=/ {print $2; exit}' "$temp_dir/xray.zip.dgst")
  actual=$(sha256sum "$temp_dir/xray.zip" | awk '{print $1}')
  [[ -n "$expected" && "${expected,,}" == "$actual" ]] || die "Xray 发布包 SHA-256 校验失败。"

  unzip -q "$temp_dir/xray.zip" -d "$temp_dir/core"
  [[ -x "$temp_dir/core/xray" ]] || die "发布包内没有 xray 可执行文件。"
  install -d -m 755 "$BIN_DIR" "$ASSET_DIR" "$CONFIG_DIR"
  install -m 755 "$temp_dir/core/xray" "$XRAY_BIN"
  install -m 644 "$temp_dir/core/geoip.dat" "$ASSET_DIR/geoip.dat"
  install -m 644 "$temp_dir/core/geosite.dat" "$ASSET_DIR/geosite.dat"
  trap - RETURN
  rm -rf "$temp_dir"
}

valid_port() { [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
valid_server_name() { [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && $1 == *.* && $1 != *..* ]]; }

generate_reality_credentials() {
  local output
  output=$("$XRAY_BIN" x25519)
  parse_reality_credentials "$output"
  SHORT_ID=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
  [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" && ${#SHORT_ID} -eq 16 ]] || die "无法生成 REALITY 凭据。"
}

parse_reality_credentials() {
  local output=$1
  PRIVATE_KEY=$(awk -F ': *' '/^PrivateKey:|^Private key:/ {print $2; exit}' <<<"$output")
  PUBLIC_KEY=$(awk -F ': *' '/^Password \(PublicKey\):|^Password:|^Public key:/ {print $2; exit}' <<<"$output")
}

ask_server_values() {
  local default_port default_uuid default_name default_server
  default_port=${PORT:-443}
  default_uuid=${UUID:-$("$XRAY_BIN" uuid)}
  default_name=${REMARK:-xray-reality}
  default_server=${SERVER_NAME:-www.microsoft.com}

  if [[ ${V2M_NONINTERACTIVE:-0} == 1 ]]; then
    PORT=${V2M_PORT:-$default_port}
    UUID=${V2M_UUID:-$default_uuid}
    SERVER_NAME=${V2M_SERVER_NAME:-$default_server}
    REMARK=${V2M_REMARK:-$default_name}
    ADDRESS=${V2M_ADDRESS:-${ADDRESS:-}}
    valid_port "$PORT" || die "V2M_PORT 必须是 1 到 65535 的端口。"
    [[ $UUID =~ ^[0-9a-fA-F-]{36}$ ]] || die "V2M_UUID 格式无效。"
    valid_server_name "$SERVER_NAME" || die "V2M_SERVER_NAME 必须是有效完整域名。"
    if [[ -z ${PRIVATE_KEY:-} || -z ${PUBLIC_KEY:-} || -z ${SHORT_ID:-} ]]; then
      generate_reality_credentials
    fi
    return
  fi

  while :; do
    read -r -p "监听端口 [${default_port}]：" PORT
    PORT=${PORT:-$default_port}
    valid_port "$PORT" && break
    yellow "请输入 1 到 65535 的端口。"
  done
  read -r -p "客户端 UUID [${default_uuid}]：" UUID
  UUID=${UUID:-$default_uuid}
  [[ $UUID =~ ^[0-9a-fA-F-]{36}$ ]] || die "UUID 格式无效。"
  while :; do
    read -r -p "REALITY 目标域名 [${default_server}]：" SERVER_NAME
    SERVER_NAME=${SERVER_NAME:-$default_server}
    valid_server_name "$SERVER_NAME" && break
    yellow "请输入有效的完整域名，例如 www.microsoft.com。"
  done
  read -r -p "备注名称 [${default_name}]：" REMARK
  REMARK=${REMARK:-$default_name}

  if [[ -z ${PRIVATE_KEY:-} || -z ${PUBLIC_KEY:-} || -z ${SHORT_ID:-} ]]; then
    generate_reality_credentials
  fi
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
    --arg private "$PRIVATE_KEY" \
    --arg short "$SHORT_ID" '{
      log: {loglevel: "warning"},
      inbounds: [{
        tag: "vless-reality",
        listen: "0.0.0.0",
        port: $port,
        protocol: "vless",
        settings: {
          clients: [{id: $id, flow: "xtls-rprx-vision"}],
          decryption: "none"
        },
        streamSettings: {
          network: "raw",
          security: "reality",
          realitySettings: {
            show: false,
            target: ($server + ":443"),
            xver: 0,
            serverNames: [$server],
            privateKey: $private,
            shortIds: [$short]
          }
        },
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
  local temporary="$CONFIG_FILE.new"
  render_config "$temporary"
  XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_BIN" run -test -config "$temporary" >/dev/null || {
    rm -f "$temporary"
    die "新配置未通过 Xray 校验。"
  }
  install -m 640 -o root -g xray "$temporary" "$CONFIG_FILE"
  rm -f "$temporary"
  cat > "$STATE_FILE" <<EOF
PORT=${PORT}
UUID=${UUID}
ADDRESS=$(printf %q "${ADDRESS:-}")
SERVER_NAME=$(printf %q "$SERVER_NAME")
PRIVATE_KEY=$(printf %q "$PRIVATE_KEY")
PUBLIC_KEY=$(printf %q "$PUBLIC_KEY")
SHORT_ID=$(printf %q "$SHORT_ID")
REMARK=$(printf %q "$REMARK")
EOF
  chmod 600 "$STATE_FILE"
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
  [[ -x "$XRAY_BIN" ]] && yellow "检测到已有 Xray 安装，将更新内核并重新生成服务端配置。"
  step "安装依赖并准备 Xray Core"
  download_core
  ask_server_values
  ensure_port_available
  step "生成并校验配置文件"
  write_config
  step "安装 systemd 服务"
  write_service
  install_manager_command
  stop_legacy_service
  if ! systemctl enable --now "$SERVICE_NAME"; then
    if [[ -n ${LAST_BACKUP:-} ]]; then
      yellow "新安装配置启动失败，正在恢复上一份配置…"
      restore_archive "$LAST_BACKUP"
      systemctl enable --now "$SERVICE_NAME" || die "回滚后服务仍无法启动，请运行 v2ray log。"
      die "新配置已回滚，服务已恢复。"
    fi
    die "服务启动失败，请运行 journalctl -u xray 查看原因。"
  fi
  green "Xray、VLESS + REALITY 安装完成。"
  show_connection
}

load_state() {
  [[ -r "$STATE_FILE" ]] || die "找不到管理状态，请先安装或重新运行安装以迁移到 2.x。"
  # This file is created by this script with mode 0600.
  # shellcheck disable=SC1090
  . "$STATE_FILE"
}

create_backup() {
  LAST_BACKUP=""
  [[ -r "$CONFIG_FILE" && -r "$STATE_FILE" ]] || return 0
  install -d -m 700 "$BACKUP_DIR"
  local timestamp archive
  timestamp=$(date -u +%Y%m%dT%H%M%SZ)
  archive="$BACKUP_DIR/config-${timestamp}.tar.gz"
  tar -czf "$archive" -C "$CONFIG_DIR" config.json manager.env
  chmod 600 "$archive"
  LAST_BACKUP=$archive

  local -a archives
  mapfile -t archives < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'config-*.tar.gz' -print | sort -r)
  local index
  for ((index=10; index<${#archives[@]}; index++)); do
    rm -f -- "${archives[$index]}"
  done
}

restore_archive() {
  local archive=$1 temp_dir
  [[ -r "$archive" ]] || die "备份文件不可读：$archive"
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN
  tar -xzf "$archive" -C "$temp_dir"
  [[ -r "$temp_dir/config.json" && -r "$temp_dir/manager.env" ]] || die "备份内容不完整。"
  XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_BIN" run -test -config "$temp_dir/config.json" >/dev/null || die "备份配置未通过 Xray 校验。"
  install -m 640 -o root -g xray "$temp_dir/config.json" "$CONFIG_FILE"
  install -m 600 -o root -g root "$temp_dir/manager.env" "$STATE_FILE"
  trap - RETURN
  rm -rf "$temp_dir"
}

restore_latest() {
  [[ -d "$BACKUP_DIR" ]] || die "没有可恢复的配置备份。"
  local archive
  archive=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'config-*.tar.gz' -print | sort -r | head -n 1)
  [[ -n "$archive" ]] || die "没有可恢复的配置备份。"
  restore_archive "$archive"
  systemctl restart "$SERVICE_NAME"
  green "已恢复备份：$(basename "$archive")"
  show_connection
}

manual_backup() {
  create_backup
  [[ -n ${LAST_BACKUP:-} ]] || die "当前没有可备份的有效配置。"
  green "配置已备份：$LAST_BACKUP"
}

restart_or_rollback() {
  if systemctl restart "$SERVICE_NAME"; then
    return 0
  fi
  red "新配置启动失败。"
  if [[ -n ${LAST_BACKUP:-} ]]; then
    yellow "正在恢复上一份配置…"
    restore_archive "$LAST_BACKUP"
    systemctl restart "$SERVICE_NAME" || die "回滚后服务仍无法启动，请运行 v2ray log。"
    die "新配置已回滚，服务已恢复。"
  fi
  die "服务启动失败，请运行 v2ray log 查看原因。"
}

server_address() {
  local addr
  if [[ -n ${ADDRESS:-} ]]; then
    printf '%s' "$ADDRESS"
    return
  fi
  addr=$(curl --fail --silent --max-time 4 https://api.ipify.org 2>/dev/null || true)
  printf '%s' "${addr:-YOUR_SERVER_IP}"
}

show_connection() {
  load_state
  local address encoded_name link
  address=$(server_address)
  encoded_name=$(jq -rn --arg value "$REMARK" '$value|@uri')
  link="vless://${UUID}@${address}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SERVER_NAME}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${encoded_name}"
  printf '\n使用协议: VLESS-REALITY-Vision\n'
  printf '%s\n' '-------------- VLESS-REALITY-Vision --------------'
  printf '协议 (protocol)       = '; cyan_value 'vless'; printf '\n'
  printf '地址 (address)        = '; cyan_value "$address"; printf '\n'
  printf '端口 (port)           = '; cyan_value "$PORT"; printf '\n'
  printf '用户ID (id)           = '; cyan_value "$UUID"; printf '\n'
  printf '传输协议 (network)  = '; cyan_value 'tcp/raw'; printf '\n'
  printf '传输安全 (security) = '; cyan_value 'reality'; printf '\n'
  printf '流控 (flow)           = '; cyan_value 'xtls-rprx-vision'; printf '\n'
  printf 'SNI                   = '; cyan_value "$SERVER_NAME"; printf '\n'
  printf '公钥 (public key)     = '; cyan_value "$PUBLIC_KEY"; printf '\n'
  printf 'Short ID              = '; cyan_value "$SHORT_ID"; printf '\n'
  printf '%s\n' '------------------- 链接 (URL) -------------------'
  cyan_value "$link"; printf '\n'
  printf '%s\n\n' '---------------------- END ----------------------'
  yellow "请在云服务商安全组和本机防火墙中放行 TCP ${PORT}。私钥仅保存在服务器，不要公开。"
}

change_config() {
  [[ -x "$XRAY_BIN" ]] || die "尚未安装。"
  load_state
  ask_server_values
  write_config
  restart_or_rollback
  green "配置已更新并重启服务。"
  show_connection
}

change_menu() {
  [[ -x "$XRAY_BIN" ]] || die "尚未安装。"
  load_state
  printf '\n当前选择: VLESS-REALITY-Vision\n\n'
  printf '%s\n' '请选择更改:' \
    '1) 更改端口' '2) 更改服务器地址' '3) 更改 REALITY 目标域名 / SNI' \
    '4) 更改 UUID' '5) 更改备注' '6) 轮换 REALITY 密钥' \
    '7) 重新输入全部配置' '0) 返回'
  read -r -p '请选择 [0-7]:' choice
  case "$choice" in
    1)
      read -r -p "新端口 [${PORT}]:" value
      PORT=${value:-$PORT}
      valid_port "$PORT" || die "端口无效。"
      ensure_port_available
      ;;
    2)
      read -r -p "客户端连接的 IP/域名 [${ADDRESS:-自动检测}]:" value
      ADDRESS=$value
      ;;
    3)
      read -r -p "新 SNI [${SERVER_NAME}]:" value
      SERVER_NAME=${value:-$SERVER_NAME}
      valid_server_name "$SERVER_NAME" || die "域名无效。"
      ;;
    4)
      read -r -p "新 UUID [回车自动生成]:" value
      UUID=${value:-$("$XRAY_BIN" uuid)}
      [[ $UUID =~ ^[0-9a-fA-F-]{36}$ ]] || die "UUID 格式无效。"
      ;;
    5)
      read -r -p "新备注 [${REMARK}]:" value
      REMARK=${value:-$REMARK}
      ;;
    6) rotate_reality_keys; return ;;
    7) change_config; return ;;
    0) return ;;
    *) die "无效选择。" ;;
  esac
  write_config
  restart_or_rollback
  green "配置已更新并重启服务。"
  show_connection
}

rotate_reality_keys() {
  [[ -x "$XRAY_BIN" ]] || die "尚未安装。"
  load_state
  generate_reality_credentials
  write_config
  restart_or_rollback
  green "REALITY 密钥和 Short ID 已轮换，旧客户端链接立即失效。"
  show_connection
}

service_action() {
  local action=$1
  systemctl "$action" "$SERVICE_NAME"
  green "已执行：${action}。"
}

show_status() { systemctl --no-pager --full status "$SERVICE_NAME" || true; }
show_logs() { journalctl -u "$SERVICE_NAME" -n 100 --no-pager; }

doctor() {
  local failures=0
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

  if [[ -r "$STATE_FILE" ]]; then
    load_state
    if getent ahosts "$SERVER_NAME" >/dev/null 2>&1; then green "[通过] REALITY 目标域名可解析"; else red "[失败] REALITY 目标域名无法解析"; ((failures+=1)); fi
    if ss -ltnH | awk -v port=":${PORT}" '$4 ~ (port "$") {found=1} END {exit !found}'; then green "[通过] TCP ${PORT} 正在监听"; else red "[失败] TCP ${PORT} 未监听"; ((failures+=1)); fi
  fi

  if (( failures == 0 )); then
    green "诊断完成：未发现问题。"
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

update_core() {
  [[ -x "$XRAY_BIN" && -r "$CONFIG_FILE" ]] || die "尚未安装。"
  download_core
  write_service
  XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_BIN" run -test -config "$CONFIG_FILE" >/dev/null
  systemctl restart "$SERVICE_NAME"
  green "Xray Core 已更新并重启服务。"
  "$XRAY_BIN" version | head -n 1
}

update_manager() {
  local temporary
  temporary=$(mktemp)
  trap 'rm -f "$temporary"' RETURN
  green "从本仓库下载管理脚本更新…"
  curl --fail --show-error --location --retry 3 --output "$temporary" "$MANAGER_URL"
  bash -n "$temporary" || die "下载的脚本未通过语法检查，未更新。"
  install -m 755 "$temporary" "$MANAGER_BIN"
  trap - RETURN
  rm -f "$temporary"
  green "管理脚本已更新。重新运行 v2ray 即可使用新版本。"
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
    '4) 备份配置' '5) 恢复最近备份' '6) 轮换 REALITY 密钥' '0) 返回'
  read -r -p '请选择 [0-6]:' choice
  case "$choice" in
    1) update_core ;; 2) update_manager ;; 3) doctor || true ;; 4) manual_backup ;;
    5) restore_latest ;; 6) rotate_reality_keys ;;
    0) return ;; *) yellow "无效选择。" ;;
  esac
}

show_help() {
  printf '%s\n' \
    '直接运行 v2ray 打开主菜单。' \
    'v2ray change   打开配置修改菜单' \
    'v2ray info     查看连接信息' \
    'v2ray doctor   运行综合诊断' \
    'v2ray help     查看完整命令用法'
}

show_about() {
  printf '\n%s\n' "----------- ${APP_NAME} -----------"
  printf '作者: %s\n版本: %s\n内核: %s\n协议: VLESS + REALITY + XTLS Vision\n仓库: https://github.com/0157Martin/v2ray-manager\n\n' \
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
      '1) 安装 / 添加配置' '2) 更改配置' '3) 查看配置' \
      '4) 服务管理' '5) 维护工具' '6) 卸载' '0) 退出'
    read -r -p "请选择：" choice
    case "$choice" in
      1) install_xray; pause ;;
      2) change_menu; pause ;;
      3) show_info; pause ;;
      4) runtime_menu; pause ;;
      5) maintenance_menu; pause ;;
      6) uninstall_xray; pause ;;
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
    info) show_info ;;
    config|change) change_menu ;;
    link) show_connection ;;
    status) show_status ;;
    start|stop|restart) service_action "$1" ;;
    log) show_logs ;;
    update) update_core ;;
    update.sh) update_manager ;;
    rotate) rotate_reality_keys ;;
    backup) manual_backup ;;
    restore) restore_latest ;;
    doctor) doctor ;;
    uninstall) uninstall_xray ;;
    version) printf '%s %s by %s\n' "$APP_NAME" "$MANAGER_VERSION" "$AUTHOR" ;;
    about) show_about ;;
    help|-h|--help) show_help; printf '%s\n' "用法：v2ray [install|info|change|config|link|status|start|stop|restart|log|update|update.sh|rotate|backup|restore|doctor|about|uninstall]" ;;
    *) die "未知命令：$1。输入 v2ray help 查看可用命令。" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
