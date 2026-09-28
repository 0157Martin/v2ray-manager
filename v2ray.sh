#!/usr/bin/env bash
# v2ray-manager — small, auditable V2Ray server installer and service manager.
# Supported hosts: Debian and Ubuntu with systemd. Run as root.
# Author: 0157Martin (https://github.com/0157Martin)
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

readonly APP_NAME="v2ray-manager"
readonly AUTHOR="0157Martin"
readonly MANAGER_VERSION="1.1.0"
readonly BIN_DIR="/usr/local/bin"
readonly MANAGER_BIN="$BIN_DIR/v2ray"
readonly V2RAY_BIN="$BIN_DIR/v2ray-core"
readonly CONFIG_DIR="/etc/v2ray"
readonly CONFIG_FILE="$CONFIG_DIR/config.json"
readonly SERVICE_FILE="/etc/systemd/system/v2ray.service"
readonly STATE_FILE="$CONFIG_DIR/manager.env"
readonly RELEASE_API="https://api.github.com/repos/v2fly/v2ray-core/releases/latest"
readonly MANAGER_URL="https://raw.githubusercontent.com/0157Martin/v2ray-manager/main/v2ray.sh"

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
  . /etc/os-release
  [[ ${ID:-} == "debian" || ${ID:-} == "ubuntu" ]] || die "仅支持 Debian/Ubuntu。"
  command -v systemctl >/dev/null || die "需要 systemd。"
}

install_dependencies() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl unzip jq
}

ensure_service_user() {
  if ! getent passwd v2ray >/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin v2ray
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
  local arch tag url temp_dir
  arch=$(arch_name)
  tag=$(curl --fail --silent --show-error --location "$RELEASE_API" | jq -r '.tag_name')
  [[ -n "$tag" && "$tag" != "null" ]] || die "无法读取 V2Ray 最新版本。"
  url="https://github.com/v2fly/v2ray-core/releases/download/${tag}/v2ray-linux-${arch}.zip"
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN
  green "下载 V2Ray Core ${tag}（${arch}）…"
  curl --fail --show-error --location --retry 3 --output "$temp_dir/v2ray.zip" "$url"
  unzip -q "$temp_dir/v2ray.zip" -d "$temp_dir/core"
  [[ -x "$temp_dir/core/v2ray" ]] || die "发布包内没有 v2ray 可执行文件。"
  install -d -m 755 "$BIN_DIR" "$CONFIG_DIR"
  install -m 755 "$temp_dir/core/v2ray" "$V2RAY_BIN"
  install -m 644 "$temp_dir/core/geoip.dat" "$BIN_DIR/geoip.dat"
  install -m 644 "$temp_dir/core/geosite.dat" "$BIN_DIR/geosite.dat"
  trap - RETURN
  rm -rf "$temp_dir"
}

valid_port() { [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

ask_server_values() {
  local default_port default_uuid
  default_port=${PORT:-443}
  default_uuid=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
  while :; do
    read -r -p "监听端口 [${default_port}]：" PORT
    PORT=${PORT:-$default_port}
    valid_port "$PORT" && break
    yellow "请输入 1 到 65535 的端口。"
  done
  read -r -p "客户端 UUID [${default_uuid}]：" UUID
  UUID=${UUID:-$default_uuid}
  [[ $UUID =~ ^[0-9a-fA-F-]{36}$ ]] || die "UUID 格式无效。"
  read -r -p "备注名称 [v2ray-server]：" REMARK
  REMARK=${REMARK:-v2ray-server}
}

write_config() {
  ensure_service_user
  install -d -m 755 "$CONFIG_DIR"
  local temporary="$CONFIG_FILE.new"
  jq -n --argjson port "$PORT" --arg id "$UUID" '{
    log: {loglevel: "warning"},
    inbounds: [{
      port: $port, listen: "0.0.0.0", protocol: "vmess",
      settings: {clients: [{id: $id, alterId: 0}], disableInsecureEncryption: false},
      streamSettings: {network: "tcp"}
    }],
    outbounds: [{protocol: "freedom", tag: "direct"}, {protocol: "blackhole", tag: "block"}]
  }' > "$temporary"
  "$V2RAY_BIN" test -config "$temporary" >/dev/null || { rm -f "$temporary"; die "新配置未通过 V2Ray 校验。"; }
  install -m 640 -o root -g v2ray "$temporary" "$CONFIG_FILE"
  rm -f "$temporary"
  cat > "$STATE_FILE" <<EOF
PORT=${PORT}
UUID=${UUID}
REMARK=$(printf %q "$REMARK")
EOF
  chmod 600 "$STATE_FILE"
}

write_service() {
  cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=V2Ray Service
Documentation=https://www.v2fly.org/
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=v2ray
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/v2ray-core run -config /etc/v2ray/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

install_v2ray() {
  require_supported_os
  [[ -x "$V2RAY_BIN" ]] && yellow "检测到已有安装，将更新内核并覆盖服务端配置。"
  download_core
  ask_server_values
  write_config
  write_service
  install_manager_command
  systemctl enable --now v2ray
  green "安装完成。"
  show_connection
}

install_manager_command() {
  # $0 can be a downloaded file, a process-substitution descriptor, or this command itself.
  [[ -r "$0" ]] || die "无法读取当前脚本，未能安装 v2ray 管理命令。"
  if [[ "$(readlink -f "$0")" != "$(readlink -f "$MANAGER_BIN" 2>/dev/null || true)" ]]; then
    install -m 755 "$0" "$MANAGER_BIN"
  fi
}

load_state() {
  [[ -r "$STATE_FILE" ]] || die "找不到管理状态，请先安装。"
  # This file is created by this script with restrictive permissions.
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
  local address vmess_json vmess_link
  address=$(server_address)
  vmess_json=$(jq -nc --arg v 2 --arg ps "$REMARK" --arg add "$address" --arg port "$PORT" --arg id "$UUID" \
    '{v:$v,ps:$ps,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:"tcp",type:"none",host:"",path:"",tls:""}')
  vmess_link="vmess://$(printf '%s' "$vmess_json" | base64 -w 0)"
  printf '\n服务器：%s\n端口：%s\nUUID：%s\n传输：VMess / TCP（未启用 TLS）\n\n导入链接：\n%s\n\n' "$address" "$PORT" "$UUID" "$vmess_link"
  yellow "请在云服务商安全组和本机防火墙中放行 TCP ${PORT}。未启用 TLS 的连接不适合承载敏感数据。"
}

change_config() {
  [[ -x "$V2RAY_BIN" ]] || die "尚未安装。"
  load_state
  ask_server_values
  write_config
  systemctl restart v2ray
  green "配置已更新并重启服务。"
  show_connection
}

service_action() {
  local action=$1
  systemctl "$action" v2ray
  green "已执行：${action}。"
}

show_status() {
  systemctl --no-pager --full status v2ray || true
}

show_logs() {
  journalctl -u v2ray -n 100 --no-pager
}

show_info() {
  load_state
  printf '作者：%s\n' "$AUTHOR"
  printf '管理器版本：%s\n' "$MANAGER_VERSION"
  printf '内核版本：%s\n' "$($V2RAY_BIN version 2>/dev/null | head -n 1 || printf '不可用')"
  show_connection
}

update_core() {
  [[ -x "$V2RAY_BIN" && -r "$CONFIG_FILE" ]] || die "尚未安装。"
  download_core
  write_service
  systemctl restart v2ray
  green "V2Ray Core 已更新并重启服务。"
  "$V2RAY_BIN" version | head -n 1
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

uninstall_v2ray() {
  read -r -p "将停止服务并删除 V2Ray 程序与 /etc/v2ray 配置。继续？[y/N] " answer
  [[ ${answer,,} == y || ${answer,,} == yes ]] || return
  systemctl disable --now v2ray 2>/dev/null || true
  rm -f "$SERVICE_FILE" "$V2RAY_BIN" "$BIN_DIR/geoip.dat" "$BIN_DIR/geosite.dat" "$MANAGER_BIN"
  rm -rf "$CONFIG_DIR"
  systemctl daemon-reload
  green "已卸载 V2Ray 与本脚本创建的配置。为避免影响其他服务，保留了 v2ray 系统账户。"
}

menu() {
  while :; do
    clear || true
    printf '%s\n' "===== V2Ray 安装与管理 ====="
    printf '作者：%s | 版本：%s\n\n' "$AUTHOR" "$MANAGER_VERSION"
    printf '%s\n' "1) 安装 / 重装" "2) 修改 VMess 配置" "3) 查看连接信息" "4) 启动服务" "5) 停止服务" "6) 重启服务" "7) 服务状态" "8) 最近日志" "9) 更新 V2Ray Core" "10) 更新管理脚本" "11) 卸载" "0) 退出"
    read -r -p "请选择：" choice
    case "$choice" in
      1) install_v2ray; pause ;;
      2) change_config; pause ;;
      3) show_connection; pause ;;
      4) service_action start; pause ;;
      5) service_action stop; pause ;;
      6) service_action restart; pause ;;
      7) show_status; pause ;;
      8) show_logs; pause ;;
      9) update_core; pause ;;
      10) update_manager; pause ;;
      11) uninstall_v2ray; pause ;;
      0) exit 0 ;;
      *) yellow "无效选择。"; pause ;;
    esac
  done
}

main() {
  require_root
  case "${1:-menu}" in
    menu) menu ;;
    install) install_v2ray ;;
    info) show_info ;;
    config) change_config ;;
    status) show_status ;;
    link) show_connection ;;
    start|stop|restart) service_action "$1" ;;
    log) show_logs ;;
    update) update_core ;;
    update.sh) update_manager ;;
    uninstall) uninstall_v2ray ;;
    version) printf '%s %s by %s\n' "$APP_NAME" "$MANAGER_VERSION" "$AUTHOR" ;;
    help|-h|--help) printf '%s\n' "用法：v2ray [install|info|config|link|status|start|stop|restart|log|update|update.sh|uninstall]" ;;
    *) die "未知命令：$1。输入 v2ray help 查看可用命令。" ;;
  esac
}

main "$@"
