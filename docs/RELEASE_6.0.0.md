# v2ray-manager 6.0.0

发布日期：2026-10-06

## 更新目标

6.0.0 将项目重新收敛为通用 Xray 服务管理器。代理协议、证书、Caddy 路由、WARP、备份、
迁移和诊断属于核心范围；个人博客模板、随机内容和外部页面仓库不属于核心范围。本次更新同时
把公网客户端入口的判断统一到一个策略函数，解决服务端内部端口与客户端入口端口长期分散判断
的问题。

## 删除的功能与代码

- 删除随机个人主页生成器。
- 删除 Portfolio、Resume 两个外部页面仓库及其 GitHub API、固定提交、部署清单和 SHA-256
  下载流程。
- 删除 Caddy“个人网页设置”菜单。
- 删除 `v2ray caddy page-install`、`page-update` 和 `refresh` 页面命令。
- 删除对应的事务操作白名单、下载失败测试和无效模板测试。
- 删除未调用的旧配置指纹函数和拼写错误的 `speettest` 命令别名。

上述删减减少了运行脚本的网络依赖和维护分支。`upgrade`、`update.sh`、`rollback.sh`、`config`
等已经公开并可能被自动化使用的兼容入口继续保留。

## Caddy 通用站点行为

首次创建静态站点或 Xray Path 路由时，如果站点目录没有 `index.html`，项目生成一个英文通用
占位页：

```text
Service available
```

占位页包含 `noindex,nofollow`，不包含虚构姓名、地点、职业或项目，也不加载脚本和外部资源。

以下内容在升级时保持不变：

- `/var/www/v2ray-manager/<域名>/index.html`；
- 用户自行部署的 CSS、JavaScript、图片和其他静态文件；
- 已有 Caddy 站点内容；
- 已配置的 Xray 入站、UUID、证书和 WARP 策略。

项目只在页面不存在时生成占位页。路由同步不会覆盖网页。需要自定义站点时，用户直接维护对应
站点目录。

## 统一客户端入口策略

新增单一入口端口决策：

| 场景 | 客户端端口 |
| --- | ---: |
| VLESS TLS-XHTTP | 443 |
| TLS WebSocket，受管 Caddy 路由完整匹配 | 443 |
| TLS WebSocket，没有受管 Caddy 路由 | Xray 实际监听端口 |
| 显式提供 CDN/入口域名覆盖 | 443 |
| REALITY、RAW、其他直连协议 | Xray 实际监听端口 |

分享链接、原生客户端 JSON和连接信息使用同一个决策结果。Caddy 路由匹配必须确认同一个 matcher
同时包含目标 Path 与目标后端，不能把站点中两条无关路由的 Path 和端口拼成一次假匹配。

## 诊断变化

`v2ray doctor` 在原有配置、进程和端口检查之外增加公网入口语义：

- TLS-XHTTP 没有匹配的受管 Caddy 路由时报告失败；
- 受管 Caddy 路由存在但 `caddy.service` 未运行时报告失败；
- TLS WebSocket 经过 Caddy 时明确报告公网 TCP 443；
- TLS WebSocket 未经过受管 Caddy 时明确提示客户端将直连监听端口。

这仍不能替代外部客户端测试。云安全组、NAT、DNS、CDN 和客户端实现位于本机诊断边界之外。

## 升级

```bash
v2ray upgrade
v2ray version
v2ray doctor
```

期望版本：

```text
v2ray-manager 6.0.0
```

本次没有提升数据结构版本，不重写现有节点状态。升级过程仍会保存上一版管理脚本并执行现有
事务与迁移检查。

## 回退

如果新脚本在具体环境出现兼容问题：

```bash
v2ray rollback.sh
```

该命令恢复 `/var/backups/v2ray-manager/manager.previous.sh`。回退管理脚本不会自动删除 6.0.0
生成的通用占位页；占位页只在原目录没有 `index.html` 时创建，因此不会替换升级前的网页。

## 验证范围

- Bash 语法和 ShellCheck；
- 单元、更新、恢复、编辑和事务加固测试；
- 12 种 Xray 服务端与客户端配置；
- Caddy 多 Path、h2c、HTTPS 后端与公网端口导出；
- 受管路由必须将 Path 和后端绑定在同一 matcher 的回归测试；
- 通用占位页创建失败回滚及已有页面不覆盖测试。

生产验证仍需要在真实服务器执行 `v2ray doctor`，并从外部客户端测试实际节点。

## 6.0.1 后续调整

用户反馈个人网页属于实际需要的可选能力。6.0.1 因此恢复 Portfolio、Resume 部署，但保持
6.0.0 的核心边界：默认流程不下载模板，菜单只有一个“安装/更新可选网页”入口，命令统一为：

```bash
v2ray caddy page example.com portfolio
v2ray caddy page example.com resume
v2ray caddy page example.com default
```

显式部署会替换该域名网页文件；项目先完成固定提交解析、清单校验和逐文件 SHA-256 校验，再
切换站点目录。失败时保留原网页。Caddy/Xray 路由不随网页部署改变。
