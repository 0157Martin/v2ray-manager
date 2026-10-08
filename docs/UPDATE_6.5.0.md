# v2ray-manager 6.5.0 项目更新说明

`v2ray-manager 6.5.0` 的重点不是单纯增加协议，而是让更新、配置、恢复和验证形成一套可追踪、
可回退的工程流程。现有单文件安装方式保持不变，维护源码已经拆分为模块，并由构建检查保证
发布的 `v2ray.sh` 与源码一致。

## 本次更新带来了什么

节点状态改为经过校验的 JSON。升级时仍能读取旧状态，但不会再把节点文件当作 Shell 执行；
未知字段、命令替换和不安全表达式会被拒绝。管理器更新、Xray Core 更新、配置迁移和服务状态
现在使用关联快照，失败或中断后可以回退或通过 `v2ray recover` 恢复。

新增的运维接口包括：

- `v2ray doctor --json`：输出不包含凭据的结构化本机诊断；
- `v2ray doctor --prometheus`：输出适合采集的 Prometheus 文本指标；
- `v2ray plan <文件>`：只预览已有节点的声明式变更；
- `v2ray apply <文件>`：在事务保护下应用变更；
- `v2ray xhttp-mode <入站ID> <模式>`：选择 `auto`、`packet-up` 或 `stream-up`；
- `v2ray rollback.core`：恢复上一组 Xray Core 和 GeoData。

Hysteria2 TLS/QUIC 作为实验选项加入，使用 UDP、TLS 和 QUIC。它要求自有证书、开放对应 UDP
端口，并需要客户端支持。非交互创建时必须设置 `V2M_EXPERIMENTAL=1`，避免自动化脚本在没有
明确选择的情况下启用实验协议。

> 后续勘误：Xray `v26.3.27` 的 Hysteria2 入站被确认存在收包但不回应的互通故障。本项目已
> 停止新建该入站，旧 profile ID 仅为配置迁移保留。处理方法见
> [Hysteria2 故障说明与迁移](HYSTERIA2_MIGRATION.md)。

## 协议菜单为什么重新分类

此前菜单中的“旧版兼容”同时包含 VMess、Trojan-WebSocket、VLESS-TLS-Vision-RAW 和
Hysteria2，容易让人误以为后两者也是旧协议。现在按实际网络路径和部署条件归纳：

| 分类 | 包含的组合 | 选择依据 |
| --- | --- | --- |
| REALITY 直连 | VLESS REALITY RAW/XHTTP/gRPC、Trojan REALITY RAW | 不需要自有证书，入口必须直连或使用灰云 DNS |
| HTTP/CDN | VLESS、VMess、Trojan 的 XHTTP/WebSocket/gRPC TLS 组合 | 使用自有域名和证书，可按协议能力接入 Caddy/CDN |
| 现代证书直连 | VLESS-TLS-Vision-RAW、Hysteria2 TLS/QUIC | 拥有证书；RAW 使用 TCP，Hysteria2 使用 UDP/QUIC |
| 兼容保留 | VMess-TCP | 面向旧客户端或可信链路，新部署不优先 |

菜单编号已按上述分类重排为连续的 1–13。编号只用于交互选择；节点状态保存的仍是
`vless-reality-raw` 等稳定 profile ID。因此现有节点无需改写或提升数据 schema，分享链接也不受影响。
依赖旧菜单数字的键盘录制或标准输入脚本必须改用 `V2M_PROFILE` 稳定 ID，或按新编号更新。

| 稳定 profile ID | 旧编号 | 新编号 |
| --- | ---: | ---: |
| `vless-reality-raw` | 1 | 1 |
| `vless-reality-xhttp` | 2 | 2 |
| `vless-reality-grpc` | 3 | 3 |
| `trojan-reality-raw` | 7 | 4 |
| `vless-tls-xhttp` | 4 | 5 |
| `vless-tls-ws` | 5 | 6 |
| `vless-tls-grpc` | 6 | 7 |
| `vmess-tls-ws` | 9 | 8 |
| `vmess-tls-grpc` | 10 | 9 |
| `trojan-tls-ws` | 11 | 10 |
| `vless-tls-raw` | 12 | 11 |
| `hysteria-tls-quic` | 13 | 12 |
| `vmess-tcp` | 8 | 13 |

## 验证情况

发布前已经在 Ubuntu 22.04、Ubuntu 24.04、Ubuntu 24.04 ARM64、Debian 12 和 Debian 13
完成回归测试。固定版和最新稳定版 Xray 均验证了 13 种服务端/客户端配置与真实本机流量；
Caddy-backed XHTTP 覆盖三种模式，Hysteria2 覆盖正确认证和错误认证。

这些检查只证明同版本 Xray 作为服务端和客户端时的本机行为；它没有证明 Hysteria2 与
sing-box 或官方客户端互通。其余配置的协议握手、本机转发和失败回退符合预期。公网安全组、域名解析、ACME
签发、CDN 规则和客户端网络环境仍需在目标 VPS 上验证。

## 升级建议

升级前建议先运行：

```bash
v2ray backup
v2ray doctor
```

随后执行：

```bash
v2ray upgrade
v2ray version
v2ray doctor --json
```

升级不会主动显示连接凭据。需要重新导出时，使用 `v2ray inbounds` 查看入站 ID，再执行
`v2ray link <入站ID>` 或 `v2ray client <入站ID>`。
