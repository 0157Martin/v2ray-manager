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
