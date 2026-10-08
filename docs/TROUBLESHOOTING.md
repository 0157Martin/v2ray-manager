# 已验证故障处理笔记

本文记录已经在实际部署中确认原因并解决的问题。处理类似故障时，先比较客户端导入参数、
节点注册表、Xray 实际配置和 Caddy 路由，不要仅凭协议名称、网页能否打开或 Cloudflare
代理状态判断。

## VLESS WebSocket TLS：橙云可用，关闭橙云后不可用

### 现象

- 客户端节点为 `VLESS + WebSocket + TLS`；
- Cloudflare 橙云开启时曾经可以使用；
- 切换为灰云（DNS only）后延迟为 `-1` 或无法连接；
- 域名能够解析到 VPS，TCP 443、TLS 证书和 Caddy 网站首页都正常。

### 本次确认的原因

客户端保留的是旧 WebSocket 节点：

```text
network = ws
path    = /b459d42e3591
port    = 443
```

一次检查中，服务器 Caddy 当时只显示另一条 XHTTP 路由：

```text
path    = /5e365874f6ab
backend = h2c://127.0.0.1:24443
```

客户端请求旧路径时，直连源站的 Caddy 返回 `404`。路径不同之外，传输类型也不同：
`h2c` 后端属于 XHTTP，不能通过把 WebSocket 客户端的 Path 手工改成 XHTTP Path 来修复。

重新创建 VLESS-WebSocket-TLS 入站并导入服务器新生成的链接后，灰云直连已经恢复；但随后
执行旧版“同步 Xray XHTTP/WS 路径反代”，连接再次失效。因此最终确认存在两个连续问题：

1. 旧客户端节点的 Path/传输与服务器当时的有效入站不一致；重新创建和重新导入解决了这一层；
2. 旧版独立 Caddy 组件检查的是已经废弃的 `vless-ws-tls`、`vmess-ws-tls`、
   `trojan-ws-tls` profile 名称，而主项目实际保存 `vless-tls-ws`、`vmess-tls-ws`、
   `trojan-tls-ws`，因此同步时会漏掉全部 WS 入站，只保留当次手工选中的 XHTTP 路由；
3. 旧版 Caddy 生成器为 HTTPS WebSocket 后端使用 Caddy 默认的 `HTTP/1.1 + HTTP/2` 上游协商，
   没有把 Xray WebSocket 的 Upgrade 请求固定为 HTTP/1.1。

项目现已修正组件的 profile 名称，并在 WebSocket 上游中生成 `versions 1.1`。同步同一域名时，
配置必须同时出现所有已启用的 XHTTP/WS Path。XHTTP 仍使用 `h2c`，两种传输不能互换。
VLESS WebSocket TLS 不强制依赖 Cloudflare 橙云。

### 诊断步骤

1. 查看服务器当前入站：

   ```bash
   v2ray inbounds
   ```

2. 比较 Caddy 实际路径和后端类型：

   ```bash
   grep -RnsE '@xray|path|reverse_proxy' \
     /etc/caddy/Caddyfile /etc/caddy/conf.d 2>/dev/null
   ```

3. 查看 Xray 的 WebSocket/XHTTP 入站：

   ```bash
   jq -r '
     .inbounds[]
     | select(.streamSettings.network == "ws" or .streamSettings.network == "xhttp")
     | [
         .tag,
         .listen,
         (.port | tostring),
         .streamSettings.network,
         (.streamSettings.wsSettings.path // .streamSettings.xhttpSettings.path),
         (.streamSettings.security // "none")
       ]
     | @tsv
   ' /etc/xray/config.json
   ```

4. 使用客户端保存的 Path 直接测试源站。WebSocket Path 若由 Caddy 普通返回 `404`，说明没有
   命中反向代理路由：

   ```bash
   curl -vk --http1.1 \
     -H 'Connection: Upgrade' \
     -H 'Upgrade: websocket' \
     -H 'Sec-WebSocket-Version: 13' \
     -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
     https://example.com/客户端保存的路径
   ```

### 已验证的直连恢复步骤

1. 删除或停用已失配的旧入站；
2. 从“入站管理”重新创建 `VLESS-WebSocket-TLS`；
3. 使用 `v2ray link <WebSocket入站ID>` 重新导出；
4. 在客户端删除旧节点后重新导入，不能只保留旧节点并手工替换其中一个字段；
5. 暂不执行旧版本的 Caddy 路径同步，先按新链接的实际入站端口完成灰云直连测试。

### 修正版 Caddy 同步

更新管理器后再运行 `v2ray caddy`，选择“同步 Xray XHTTP/WS 路径反代”。生成的 WebSocket
后端必须包含：

```caddyfile
reverse_proxy @xray_ws https://127.0.0.1:后端端口 {
    flush_interval -1
    transport http {
        versions 1.1
        tls_server_name example.com
    }
}
```

如果 `v2ray inbounds` 显示已启用 WS 入站，而站点文件只出现 XHTTP 路由，说明服务器仍在使用
漏扫 WS profile 的旧 Caddy 组件。执行管理器更新后重新同步；更新会按固定提交和 SHA-256
替换组件，不能只修改现有 Caddyfile 中的一条 Path。

然后执行 Caddy 校验并重载：

   ```bash
   caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
   systemctl reload caddy
   systemctl restart xray
   ```

保持灰云复测，确认客户端的协议、域名、端口、Host/SNI 和 Path 都来自同一次导出。

### 生产环境复核记录（2026-10-08）

实际恢复流程如下：

1. 进入“维护与诊断”，选择 `2) 一键更新项目脚本并迁移数据`，把管理器更新到 `6.5.1`；
2. 进入 `v2ray caddy`，选择 `4) 同步 Xray XHTTP/WS 路径反代`；
3. 同步后的同一域名站点文件同时保留了三条已启用的路由：一条 XHTTP 后端和两条
   VLESS-WebSocket-TLS 后端；
4. XHTTP 路由使用 `h2c://127.0.0.1:24443` 和 `versions h2c`；两个 WebSocket 路由分别转发到
   `https://127.0.0.1:24445`、`https://127.0.0.1:24444`，并都包含 `versions 1.1` 及正确的
   `tls_server_name`；
5. `caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile` 返回
   `Valid configuration`，随后 reload Caddy、restart Xray，客户端恢复使用。

这次实测确认故障来自旧 Caddy 组件漏扫 WS profile 和 WS 上游协议选择，并非 VLESS WebSocket
TLS 必须经过 Cloudflare 橙云。检查修复是否生效时，应以“全部已启用路径均存在、后端端口正确、
WS 明确使用 HTTP/1.1、Caddy 校验成功、客户端实测通过”作为完整验收条件。

### 避免错误处理

- 不要把 XHTTP 的 `h2c` Path 填入 WebSocket 客户端；
- 不要因为首页返回 `200` 就认定代理 Path 正常；
- 不要因为橙云曾经可用就认定协议必须经过 Cloudflare；
- 不要反复修改防火墙来处理 Caddy 明确返回的 `404`；能够收到 Caddy 的 HTTP 响应已经证明
  请求到达服务器；
- 不要覆盖导入后继续使用客户端缓存的旧节点，重新创建后应删除旧节点再导入新链接。
