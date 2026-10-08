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

### 解决方法

1. 进入“维护与诊断”，选择 `2) 一键更新项目脚本并迁移数据`。这一步会更新主脚本，并按主项目
   锁定的提交和 SHA-256 更新修正后的 Caddy 组件；
2. 删除或停用与服务器 Path、传输类型不一致的旧入站，重新创建 `VLESS-WebSocket-TLS`；
3. 运行 `v2ray caddy`，选择 `4) 同步 Xray XHTTP/WS 路径反代`，为同一域名重新生成全部
   已启用的 XHTTP/WS 路由；
4. 使用 `v2ray link <WebSocket入站ID>` 重新导出，在客户端删除旧节点后重新导入。不要只修改
   旧节点的 Path，因为端口、Host、SNI、UUID 和传输类型也必须与本次生成结果一致；
5. 校验并加载配置：

   ```bash
   caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
   systemctl reload caddy
   systemctl restart xray
   ```

修正后的 WebSocket 后端必须包含：

```caddyfile
reverse_proxy @xray_ws https://127.0.0.1:后端端口 {
    flush_interval -1
    transport http {
        versions 1.1
        tls_server_name example.com
    }
}
```

如果 `v2ray inbounds` 显示已启用 WS 入站，而站点文件只出现 XHTTP 路由，说明旧 Caddy 组件仍在
漏扫 WS profile；应先更新管理器和组件，再重新同步，不能只向现有 Caddyfile 手工补一条 Path。

### 恢复确认

- Caddy 站点文件包含该域名下每个已启用的 XHTTP/WS Path；
- XHTTP 后端使用 `h2c`，WebSocket 后端使用 HTTPS 且明确包含 `versions 1.1`；
- 每条路由的后端端口与 `v2ray inbounds`、`/etc/xray/config.json` 一致；
- `tls_server_name`、客户端 Host/SNI 和证书域名一致；
- `caddy validate` 返回 `Valid configuration`；
- 灰云（DNS only）状态下客户端实际连接成功。

满足以上条件即可确认恢复。VLESS WebSocket TLS 本身不要求经过 Cloudflare 橙云。

### 避免错误处理

- 不要把 XHTTP 的 `h2c` Path 填入 WebSocket 客户端；
- 不要因为首页返回 `200` 就认定代理 Path 正常；
- 不要因为橙云曾经可用就认定协议必须经过 Cloudflare；
- 不要反复修改防火墙来处理 Caddy 明确返回的 `404`；能够收到 Caddy 的 HTTP 响应已经证明
  请求到达服务器；
- 不要覆盖导入后继续使用客户端缓存的旧节点，重新创建后应删除旧节点再导入新链接。
