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
