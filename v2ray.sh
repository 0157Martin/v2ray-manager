#!/usr/bin/env bash
# Modern Xray/VLESS installer and manager, exposed through the v2ray command.
# Supported hosts: Debian and Ubuntu with systemd. Run as root.
# Author: 0157Martin (https://github.com/0157Martin)
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

readonly APP_NAME="v2ray-manager"
readonly AUTHOR="0157Martin"
readonly MANAGER_VERSION="2.0.0"
readonly BIN_DIR="/usr/local/bin"
readonly MANAGER_BIN="$BIN_DIR/v2ray"
readonly XRAY_BIN="$BIN_DIR/xray-core"
readonly ASSET_DIR="/usr/local/share/xray"
readonly CONFIG_DIR="/etc/xray"
readonly CONFIG_FILE="$CONFIG_DIR/config.json"
readonly SERVICE_FILE="/etc/systemd/system/xray.service"
readonly STATE_FILE="$CONFIG_DIR/manager.env"
readonly RELEASE_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
readonly MANAGER_URL="https://raw.githubusercontent.com/0157Martin/v2ray-manager/main/v2ray.sh"
readonly SERVICE_NAME="xray"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
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
  apt-get install -y ca-certificates curl unzip jq coreutils
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

  green "下载 Xray Core ${tag}（${arch}）…"
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
  PRIVATE_KEY=$(awk -F ': *' '/^PrivateKey:|^Private key:/ {print $2; exit}' <<<"$output")
  PUBLIC_KEY=$(awk -F ': *' '/^Password \(PublicKey\):|^Password:|^Public key:/ {print $2; exit}' <<<"$output")
  SHORT_ID=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
  [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" && ${#SHORT_ID} -eq 16 ]] || die "无法生成 REALITY 凭据。"
}

ask_server_values() {
  local default_port default_uuid default_name default_server
  default_port=${PORT:-443}
  default_uuid=${UUID:-$("$XRAY_BIN" uuid)}
  default_name=${REMARK:-xray-reality}
  default_server=${SERVER_NAME:-www.microsoft.com}

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

write_config() {
  ensure_service_user
  install -d -m 755 "$CONFIG_DIR"
  local temporary="$CONFIG_FILE.new"
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
    }' > "$temporary"
  XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_BIN" run -test -config "$temporary" >/dev/null || {
    rm -f "$temporary"
    die "新配置未通过 Xray 校验。"
  }
  install -m 640 -o root -g xray "$temporary" "$CONFIG_FILE"
  rm -f "$temporary"
  cat > "$STATE_FILE" <<EOF
PORT=${PORT}
UUID=${UUID}
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
  download_core
  ask_server_values
  write_config
  write_service
  install_manager_command
  stop_legacy_service
  systemctl enable --now "$SERVICE_NAME"
  green "Xray、VLESS + REALITY 安装完成。"
  show_connection
}

load_state() {
  [[ -r "$STATE_FILE" ]] || die "找不到管理状态，请先安装或重新运行安装以迁移到 2.x。"
  # This file is created by this script with mode 0600.
  # shellcheck disable=SC1090
  . "$STATE_FILE"
}

server_address() {
  local addr
  addr=$(curl --fail --silent --max-time 4 https://api.ipify.org 2>/dev/null || true)
  printf '%s' "${addr:-YOUR_SERVER_IP}"
}

show_connection() {
  load_state
  local address encoded_name link
  address=$(server_address)
  encoded_name=$(jq -rn --arg value "$REMARK" '$value|@uri')
  link="vless://${UUID}@${address}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SERVER_NAME}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${encoded_name}"
  printf '\n服务器：%s\n端口：%s\nUUID：%s\n协议：VLESS\n传输安全：REALITY\n流控：XTLS Vision\nSNI：%s\n公钥/Password：%s\nShort ID：%s\n\n导入链接：\n%s\n\n' \
    "$address" "$PORT" "$UUID" "$SERVER_NAME" "$PUBLIC_KEY" "$SHORT_ID" "$link"
  yellow "请在云服务商安全组和本机防火墙中放行 TCP ${PORT}。私钥仅保存在服务器，不要公开。"
}

change_config() {
  [[ -x "$XRAY_BIN" ]] || die "尚未安装。"
  load_state
  ask_server_values
  write_config
  systemctl restart "$SERVICE_NAME"
  green "配置已更新并重启服务。"
  show_connection
}

rotate_reality_keys() {
  [[ -x "$XRAY_BIN" ]] || die "尚未安装。"
  load_state
  generate_reality_credentials
  write_config
  systemctl restart "$SERVICE_NAME"
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
  systemctl daemon-reload
  green "已卸载本脚本创建的 Xray 程序与配置。为避免影响其他服务，保留了 xray 系统账户。"
}

menu() {
  while :; do
    clear || true
    printf '%s\n' "===== Xray / VLESS REALITY 管理 ====="
    printf '作者：%s | 版本：%s\n\n' "$AUTHOR" "$MANAGER_VERSION"
    printf '%s\n' \
      "1) 安装 / 重装" "2) 修改配置" "3) 查看连接信息" \
      "4) 启动服务" "5) 停止服务" "6) 重启服务" \
      "7) 服务状态" "8) 最近日志" "9) 更新 Xray Core" \
      "10) 更新管理脚本" "11) 轮换 REALITY 密钥" "12) 卸载" "0) 退出"
    read -r -p "请选择：" choice
    case "$choice" in
      1) install_xray; pause ;;
      2) change_config; pause ;;
      3) show_connection; pause ;;
      4) service_action start; pause ;;
      5) service_action stop; pause ;;
      6) service_action restart; pause ;;
      7) show_status; pause ;;
      8) show_logs; pause ;;
      9) update_core; pause ;;
      10) update_manager; pause ;;
      11) rotate_reality_keys; pause ;;
      12) uninstall_xray; pause ;;
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
    config) change_config ;;
    link) show_connection ;;
    status) show_status ;;
    start|stop|restart) service_action "$1" ;;
    log) show_logs ;;
    update) update_core ;;
    update.sh) update_manager ;;
    rotate) rotate_reality_keys ;;
    uninstall) uninstall_xray ;;
    version) printf '%s %s by %s\n' "$APP_NAME" "$MANAGER_VERSION" "$AUTHOR" ;;
    help|-h|--help) printf '%s\n' "用法：v2ray [install|info|config|link|status|start|stop|restart|log|update|update.sh|rotate|uninstall]" ;;
    *) die "未知命令：$1。输入 v2ray help 查看可用命令。" ;;
  esac
}

main "$@"
