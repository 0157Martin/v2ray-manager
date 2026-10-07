show_help() {
  printf '%s\n' \
    '直接运行 v2ray 打开主菜单。' \
    'v2ray add      添加新入站' \
    'v2ray inbounds 查看入站列表' \
    'v2ray links    输出全部启用入站链接' \
    'v2ray users    打开子链接用户管理（查看、新增、删除、重新生成）' \
    'v2ray users list [入站ID] 查看协议分组或指定入站的链接用户' \
    'v2ray users add/delete/replace 管理指定入站的链接用户' \
    'v2ray link <入站ID> <CDN域名|cfip> 以 443 导出 TLS XHTTP/WS 链接' \
    'v2ray firewall 自动放行已启用入站的本机 UFW/firewalld 端口' \
    'v2ray speedtest 运行服务器网络测速' \
    'v2ray route [目标IP/域名] 测试回程路由、丢包和延迟' \
    'v2ray caddy    管理 Caddy 伪装网站和本机反向代理' \
    'v2ray cfip     管理独立 Cloudflare 优选 IP 分支项目' \
    'v2ray warp     管理全部协议共用的 WARP 出站策略' \
    'v2ray upgrade  一键更新项目脚本、迁移数据并保留现有链接' \
    'v2ray update.core [--version <vX.Y.Z> | --latest] [--check] 默认固定基线，可指定版本' \
    'v2ray versions 查看当前内核与上游最新版本' \
    'v2ray rollback.core 恢复上次内核和 GeoData（先校验当前配置）' \
    'v2ray rollback.sh 恢复上一关联快照（包含数据，会撤销快照后的配置修改）' \
    'v2ray recover 恢复中断的管理脚本事务' \
    'v2ray doctor [--json|--prometheus] 本机诊断或导出监控指标' \
    'v2ray plan <文件.json> 预览已有入站的声明式变更' \
    'v2ray apply <文件.json> 在事务中应用声明式变更' \
    'v2ray xhttp-mode <入站ID> <auto|packet-up|stream-up> 设置客户端模式' \
    'v2ray help     查看完整命令用法'
}

show_about() {
  printf '\n%s\n' "----------- ${APP_NAME} -----------"
  printf '作者: %s\n版本: %s\n内核: %s\n协议: VLESS + REALITY/TLS + RAW/XHTTP/gRPC/WebSocket\n仓库: https://github.com/0157Martin/v2ray-manager\n\n' \
    "$AUTHOR" "$MANAGER_VERSION" "$(command_version_line "$XRAY_BIN" '未安装')"
}

menu() {
  while :; do
    clear || true
    local core_version service_state caddy_state active_nodes disabled_nodes install_label
    core_version=$(xray_version_short "$XRAY_BIN" '未安装')
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
    ui_box_title "${APP_NAME}  v${MANAGER_VERSION}  ·  通用 Xray 管理器  ·  by ${AUTHOR}"
    printf '\033[38;5;39m│\033[0m  Xray: %s\n' "$core_version"
    printf '\033[38;5;39m│\033[0m  服务状态: '
    if [[ $service_state == running ]]; then green "$service_state"; else red "$service_state"; fi
    printf '\033[38;5;39m│\033[0m  Caddy: %s  ·  入站：%s 启用 / %s 停用\n' "$caddy_state" "$active_nodes" "$disabled_nodes"
    ui_box_divider
    ui_menu_item "1) $install_label"
    ui_menu_item '2) 入站管理'
    ui_menu_item '3) 连接与导出'
    ui_menu_item '4) Xray 服务管理'
    ui_menu_item '5) Caddy 网站管理'
    ui_menu_item '6) WARP 出站管理（全部协议）'
    ui_menu_item '7) 维护与诊断'
    ui_menu_item '8) 卸载项目'
    ui_box_divider
    ui_menu_item '0) 退出'
    ui_box_bottom
    read -r -p '请选择 [0-8]：' choice
    case "$choice" in
      1) run_mutation install_xray; pause ;;
      2) manage_inbounds_menu ;;
      3) export_menu ;;
      4) runtime_menu ;;
      5) caddy_menu ;;
      6) warp_menu ;;
      7) maintenance_menu ;;
      8) run_mutation uninstall_xray; pause ;;
      0) exit 0 ;;
      *) yellow "无效选择。"; pause ;;
    esac
  done
}

main() {
  require_root
  if [[ ${1:-} == __mutation ]]; then shift; mutation_entry "$@"; return; fi
  # Read-only commands must not trigger migration. All mutations validate state
  # after taking the lock; rollback/recovery must remain usable with newer data.
  case "${1:-menu}" in
    menu) menu ;;
    install) run_mutation install_xray ;;
    add) run_mutation add_inbound ;;
    inbounds) list_inbounds ;;
    links) show_all_links ;;
    firewall) run_mutation open_enabled_inbound_ports ;;
    info) show_info ;;
    config|change) run_mutation change_menu "${2:-}" ;;
    link) show_connection "${2:-}" "${3:-}" ;;
    users) users_command "${@:2}" ;;
    client) export_client "${2:-}" ;;
    cert-refresh) run_mutation refresh_tls_certificates "${2:-}" ;;
    status) show_status ;;
    start|stop|restart) run_mutation service_action "$1" ;;
    log) show_logs ;;
    speedtest) run_speedtest ;;
    route) if [[ -n ${2:-} ]]; then route_latency_test "$2"; else route_test_menu; fi ;;
    caddy) caddy_command "${2:-menu}" "${3:-}" "${4:-}" "${5:-}" ;;
    cfip|cloudflare-ip) cloudflare_ip_command "${@:2}" ;;
    warp) warp_command "${2:-menu}" "${3:-}" ;;
    update|update.core) core_update_command "${@:2}" ;;
    versions) check_core_update latest ;;
    rollback.core) run_mutation rollback_core ;;
    upgrade|update.sh) run_mutation update_manager ;;
    migrate) run_mutation migrate_project_state ;;
    rollback.sh) run_mutation rollback_manager ;;
    recover) run_mutation recover_manager ;;
    rotate) run_mutation rotate_reality_keys "${2:-}" ;;
    backup) run_mutation manual_backup ;;
    restore) run_mutation restore_latest ;;
    doctor) doctor_command "${2:-}" ;;
    plan) plan_desired "${2:-}" ;;
    apply) run_mutation apply_desired "${2:-}" ;;
    xhttp-mode) run_mutation set_xhttp_mode "${2:-}" "${3:-}" ;;
    uninstall) run_mutation uninstall_xray ;;
    version) printf '%s %s by %s\n' "$APP_NAME" "$MANAGER_VERSION" "$AUTHOR" ;;
    about) show_about ;;
    help|-h|--help) show_help; printf '%s\n' "用法：v2ray [install|add|inbounds|links|users [list|show|add|delete|replace|set]|info|change|config|link [入站ID] [CDN域名|cfip]|client [入站ID]|status|start|stop|restart|log|speedtest|route [目标]|caddy [install|verify|static|reverse|xray|page <域名> [portfolio|resume|default]|status|log|repair|uninstall]|cfip [install|test|set|verify|show|get|clear|uninstall]|warp [install|switch <wireguard|masque>|status|test|diagnose|check|selective|all|ipv4|ipv6|dual|off|repair|uninstall]|update|upgrade|update.sh|rollback.sh|rotate|backup|restore|doctor|firewall|about|uninstall]" ;;
    *) die "未知命令：$1。输入 v2ray help 查看可用命令。" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
