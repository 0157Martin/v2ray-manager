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
