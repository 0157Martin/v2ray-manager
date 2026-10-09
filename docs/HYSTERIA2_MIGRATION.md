# Hysteria2 故障说明与迁移

## 问题原因

`v2ray-manager 6.5.0` 使用 Xray 的实验性 `hysteria` 入站。该实现可能已经监听并收到客户端 UDP 数据包，却不返回握手响应，v2rayN 使用 sing-box 连接时最终超时。修改端口、反复放行防火墙或切换 Cloudflare 开关不能修复服务端实现问题。

Cloudflare 普通橙云也不代理任意 UDP。Hysteria2 域名必须使用灰云（DNS only），并将 UDP 端口直接解析到服务器。

项目现改用 **Hysteria 官方服务端** 承载 `hysteria-tls-quic`。Xray 继续管理其他入站；节点 ID、UUID、域名、UDP 端口和证书保持不变，升级时由管理器自动生成官方配置和独立的 systemd 实例。

规范和依据：

- Hysteria 官方安装：<https://v2.hysteria.network/docs/getting-started/Server-Installation-Script/>
- Hysteria 官方服务端配置：<https://v2.hysteria.network/docs/getting-started/Server/>
- Hysteria 官方完整配置：<https://v2.hysteria.network/docs/advanced/Full-Server-Config/>
- Hysteria 官方 URI：<https://v2.hysteria.network/docs/developers/URI-Scheme/>
- Xray 同型故障：<https://github.com/XTLS/Xray-core/issues/5921>
- v2rayN 核心选择说明：<https://github.com/2dust/v2rayN/discussions/5822>
- 补充兼容排查（非规范依据）：<https://www.chonglangbiji.com/clients/v2rayn-hysteria2-share-link-import-failed-2026/>

## 管理器如何迁移

执行项目更新后，管理器会：

1. 从 Xray 合并配置中移除旧 Hysteria 实验入站，避免 UDP 端口冲突；
2. 下载固定版本的 Hysteria 官方二进制并校验 SHA-256；
3. 按已有节点生成 `hysteria-v2ray-manager@<入站ID>.service`；
4. 保留原 UUID 作为认证密码，并继续支持已有子链接；
5. 停用或删除节点时同步停止服务并删除生成配置；恢复备份后重新生成服务配置。

生成的服务端配置使用已有证书和 command 认证，等价于：

```yaml
listen: ":445"
tls:
  cert: /etc/xray/tls/example.com/cert.pem
  key: /etc/xray/tls/example.com/key.pem
  sniGuard: strict
auth:
  type: command
  command: /etc/hysteria-v2ray-manager/入站ID-auth
masquerade:
  type: string
  string:
    content: "404 Not Found"
    statusCode: 404
```

分享链接按官方格式输出：

```text
hysteria2://URL编码后的密码@域名:UDP端口/?sni=域名#节点名称
```

`alpn=h3` 不是官方 URI 规定的必要参数，因此不再添加。`v2ray client <入站ID>` 导出 sing-box 格式的 Hysteria2 客户端配置。

## 验证与排查

```bash
v2ray doctor
systemctl status 'hysteria-v2ray-manager@*.service'
journalctl -u 'hysteria-v2ray-manager@*.service' -n 100 --no-pager
ss -lnup
```

云安全组和本机防火墙都必须放行节点的 **UDP** 端口。在 v2rayN 中重新导入链接、选用 sing-box 内核并重启内核。仍超时时，用 `tcpdump -ni any udp port <端口>` 检查双向数据；只有入站包通常表示服务端没有响应或回程网络被阻断。

不要把旧 Xray JSON 直接交给官方 Hysteria。两者的配置结构和认证字段不同。
