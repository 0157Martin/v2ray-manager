# Hysteria2 故障说明与迁移

## 结论

`v2ray-manager 6.5.0` 生成的链接符合 Hysteria2 URI 基本结构，但服务端使用的是 Xray
`hysteria` 实验入站。Xray Core `v26.3.27` 已有同型问题：入站成功监听并收到客户端 UDP
数据包，却不发送握手响应，最终由客户端超时。修改端口、重复放行防火墙或关闭 Cloudflare
橙云不能修复这个实现问题。

v2rayN 导入 `hysteria2://` 链接后默认强制使用 sing-box。项目原来的 Xray-to-Xray
本机测试只能证明 Xray 两端使用同一实现时可以通信，不能证明它与 sing-box 或 Hysteria
官方客户端互通。因此从本修订开始停止新建 Xray Hysteria2 入站，旧 profile ID
`hysteria-tls-quic` 仍可被读取、导出、删除和迁移，不改变其他节点编号或状态 schema。

参考资料：

- Xray 同型故障：<https://github.com/XTLS/Xray-core/issues/5921>
- Hysteria 官方服务端：<https://v2.hysteria.network/docs/getting-started/Server/>
- Hysteria 官方 URI：<https://v2.hysteria.network/docs/developers/URI-Scheme/>
- v2rayN 核心选择说明：<https://github.com/2dust/v2rayN/discussions/5822>

## 现有节点如何迁移

1. 先用 `v2ray link <入站ID>` 记录域名、UDP 端口和节点名称。截图或日志中已经公开过的
   密码必须更换，不要继续使用。
2. 使用 Hysteria 官方二进制，按官方文档创建独立服务。服务端最小配置如下；证书路径应替换
   为当前域名证书的实际路径，密码应重新生成：

   ```yaml
   listen: :445

   tls:
     cert: /path/to/fullchain.pem
     key: /path/to/privkey.pem

   auth:
     type: password
     password: REPLACE_WITH_A_NEW_RANDOM_PASSWORD

   masquerade:
     type: proxy
     proxy:
       url: https://www.example.com/
       rewriteHost: true
   ```

3. 停用或删除原 Xray Hysteria2 入站，避免两个进程争用同一 UDP 端口，再启动官方
   Hysteria 服务。云安全组和本机防火墙均须放行该 **UDP** 端口；域名应直连服务器，不能使用
   只代理 HTTP/TCP 的普通 Cloudflare 橙云代理。
4. 按官方格式重新生成链接：

   ```text
   hysteria2://URL编码后的新密码@域名:UDP端口/?sni=域名#节点名称
   ```

   `alpn=h3` 不是官方 URI 规定的必要参数，迁移后的链接不再添加它。
5. 在 v2rayN 中重新导入链接并设为活动服务器，然后重启内核。测试时同时检查服务端日志与
   `tcpdump -ni any udp port 445`；必须看到双向 UDP 数据，只有入站包仍表示服务端没有回应。

不要直接把旧 Xray JSON 交给官方 Hysteria。两者配置结构不同，认证字段也不同。
