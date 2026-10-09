hysteria_asset() {
  case "$(uname -m)" in
    x86_64|amd64) printf '%s\t%s\n' hysteria-linux-amd64 907ba8c9693edb104b20582681fb7dc15639d5b64a9cbb616a7b539190a86691 ;;
    aarch64|arm64) printf '%s\t%s\n' hysteria-linux-arm64 a68a61a84452ca250ce0368202521965ca9cc9d801a404f1dc9008ac6cf677a7 ;;
    *) red "Hysteria 官方服务端暂不支持此架构：$(uname -m)" >&2; return 1 ;;
  esac
}

install_hysteria_core() (
  set -Eeuo pipefail
  local asset expected actual temporary
  IFS=$'\t' read -r asset expected < <(hysteria_asset) || return 1
  if [[ -x $HYSTERIA_BIN ]]; then
    actual=$(sha256sum "$HYSTERIA_BIN") || return 1
    [[ ${actual%% *} == "$expected" ]] && return 0
  fi
  temporary=$(mktemp) || return 1
  trap 'rm -f -- "$temporary"' EXIT
  download_file "https://github.com/HyNetworks/hysteria/releases/download/app%2F${HYSTERIA_VERSION}/${asset}" "$temporary" || return 1
  actual=$(sha256sum "$temporary") || return 1
  [[ ${actual%% *} == "$expected" ]] || { red 'Hysteria 官方二进制 SHA-256 校验失败。' >&2; return 1; }
  chmod 755 "$temporary"
  "$temporary" version >/dev/null || return 1
  atomic_install "$temporary" "$HYSTERIA_BIN" 755
)

write_hysteria_service_template() {
  cat > "$HYSTERIA_SERVICE_TEMPLATE" <<EOF
[Unit]
Description=Hysteria2 inbound %i managed by v2ray-manager
Documentation=https://v2.hysteria.network/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=$HYSTERIA_BIN server -c $HYSTERIA_CONFIG_DIR/%i.yaml
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=$TLS_DIR

[Install]
WantedBy=multi-user.target
EOF
}

render_hysteria_node() {
  local node_id=$1 config=$HYSTERIA_CONFIG_DIR/$node_id.yaml auth_file=$HYSTERIA_CONFIG_DIR/$node_id.auth auth_cmd=$HYSTERIA_CONFIG_DIR/$node_id-auth
  local credential
  valid_node_id "$node_id" || return 1
  valid_port "$PORT" && valid_server_name "$SERVER_NAME" || return 1
  tls_pair_valid "$(tls_cert_path)" "$(tls_key_path)" || return 1
  install -d -m 700 "$HYSTERIA_CONFIG_DIR"
  {
    printf '%s\n' "$UUID"
    if [[ -n ${EXTRA_UUIDS:-} ]]; then tr ',' '\n' <<<"$EXTRA_UUIDS"; fi
  } > "$auth_file"
  chmod 600 "$auth_file"
  while IFS= read -r credential; do valid_uuid "$credential" || return 1; done < "$auth_file"
  cat > "$auth_cmd" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
grep -Fqx -- "\${2:-}" "$auth_file"
printf '%s\n' "\${2:-}"
EOF
  chmod 700 "$auth_cmd"
  cat > "$config" <<EOF
listen: ":$PORT"
tls:
  cert: "$(tls_cert_path)"
  key: "$(tls_key_path)"
  sniGuard: strict
auth:
  type: command
  command: "$auth_cmd"
masquerade:
  type: string
  string:
    content: "404 Not Found"
    headers:
      content-type: "text/plain; charset=utf-8"
    statusCode: 404
EOF
  chmod 600 "$config"
}

sync_hysteria_services() (
  set -Eeuo pipefail
  local node_file node_id config found=0
  declare -A enabled=()
  for node_file in "$NODES_DIR"/*.env; do
    [[ -f $node_file ]] || continue
    EXTRA_UUIDS=''; load_state_file "$node_file" || return 1
    [[ $PROFILE == hysteria-tls-quic ]] || continue
    ((found+=1)); node_id=$(basename "$node_file" .env); enabled["$node_id"]=1
  done
  if (( found )); then
    install_hysteria_core || return 1
    install -d -m 700 "$HYSTERIA_CONFIG_DIR"
    write_hysteria_service_template || return 1
    for node_file in "$NODES_DIR"/*.env; do
      [[ -f $node_file ]] || continue
      EXTRA_UUIDS=''; load_state_file "$node_file" || return 1
      [[ $PROFILE == hysteria-tls-quic ]] || continue
      node_id=$(basename "$node_file" .env)
      render_hysteria_node "$node_id" || return 1
    done
    systemctl daemon-reload || return 1
  fi
  [[ -d $HYSTERIA_CONFIG_DIR ]] || return 0
  for config in "$HYSTERIA_CONFIG_DIR"/*.yaml; do
    [[ -f $config ]] || continue
    node_id=$(basename "$config" .yaml)
    if [[ -n ${enabled[$node_id]:-} ]]; then
      systemctl enable "hysteria-v2ray-manager@${node_id}.service" >/dev/null
      systemctl restart "hysteria-v2ray-manager@${node_id}.service" || return 1
      systemctl is-active --quiet "hysteria-v2ray-manager@${node_id}.service" || return 1
    else
      systemctl disable --now "hysteria-v2ray-manager@${node_id}.service" >/dev/null 2>&1 || true
      rm -f -- "$config" "$HYSTERIA_CONFIG_DIR/$node_id.auth" "$HYSTERIA_CONFIG_DIR/$node_id-auth"
    fi
  done
  systemctl daemon-reload || return 1
)

hysteria_node_matches_runtime() {
  local node_id node_file
  for node_file in "$NODES_DIR"/*.env; do
    [[ -f $node_file ]] || continue
    node_id=$(basename "$node_file" .env)
    [[ -r $HYSTERIA_CONFIG_DIR/$node_id.yaml ]] || continue
    grep -Fqx "listen: \":$PORT\"" "$HYSTERIA_CONFIG_DIR/$node_id.yaml" || continue
    grep -Fqx "$UUID" "$HYSTERIA_CONFIG_DIR/$node_id.auth" || continue
    systemctl is-active --quiet "hysteria-v2ray-manager@${node_id}.service" && return 0
  done
  return 1
}
