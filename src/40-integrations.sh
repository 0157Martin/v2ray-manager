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
