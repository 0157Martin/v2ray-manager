# Changelog

## 4.3.1

- 首次非交互自动安装从 TCP 443 开始选择空闲端口；443 空闲时默认使用 443，被现有服务占用时保留该服务并选择后续空闲端口。

## 4.3.0

- 按 XTLS 官方入门教程新增 VLESS + TLS + Vision + RAW，保留原有菜单编号，新增选项 12。
- 新增 `v2ray client [入站ID]`，从已验证的节点参数生成 Xray 客户端 JSON，绑定本机 SOCKS/HTTP 端口，不导出服务端私钥或关闭 TLS 校验。
- Certbot 支持 `V2M_ACME_WEBROOT`，已有网站无需释放 TCP 80 即可响应 HTTP challenge。
- 续期钩子部署前校验证书、私钥、域名及信任链；配置或重启失败恢复旧证书并保留备份，已停止服务保持停止。
- 按官方部署方法停止自动读取 acme.sh 内部文件；外部证书通过稳定安装路径导入。
- 增加续期故障与 webroot 回归测试，实际 Xray 验证 12 种协议的服务端和客户端配置，并与导出链接交叉核验。

## 4.2.1

- 单条链接优先读取启用的入站状态，避免修改节点后仍从旧 `manager.env` 导出失效参数。
- 隔离入站配置合并、防火墙遍历和列表操作的变量，避免添加/修改后显示另一条节点链接。
- 导出前核对入站状态与服务端配置，拒绝占位地址及不一致的节点参数。
- UUID 自动生成/沿用并按标准分段校验；导出前校验 REALITY 公私钥对应关系和 TLS 域名、有效期、私钥匹配，私钥推导通过标准输入完成。
- 自动发现证书时排除未受系统 CA 信任的证书；显式导入自建 CA 证书时提示客户端信任要求，诊断检查完整证书链。
- IPv6 URI 地址使用方括号；显式 IPv6 入口生成 IPv6 监听配置。
- `doctor` 检查所有配置入站的监听端口、REALITY 目标 TLS 1.3 握手和导出参数。
- 增加链接回归测试、11 种导出链接与服务端配置的往返核验，以及本机 REALITY 客户端/服务端真实流量测试。

## 4.2.0

- 内核升级先在暂存目录验证下载和现有配置，再替换内核与 GeoData；安装或健康检查失败时自动恢复旧文件，回退失败时保留恢复材料。
- 服务启动、重启和配置回滚后连续检查 5 秒的进程状态、PID 和自动重启次数，识别启动后立即崩溃。
- 更新内核时保留已停止服务的状态；重复安装不再隐式覆盖现有内核。
- 安装器与管理脚本更新先解析固定提交，支持 `V2M_MANAGER_REF` 指定完整 SHA；管理器更新保留旧文件，新增 `v2ray rollback.sh`。
- 配置备份采用唯一文件名，避免同秒覆盖；恢复时使用备份中的证书校验，并恢复共享证书与按域名保存的证书目录。
- 整合自动发现/申请 TLS 证书及 Certbot 续期钩子，保留显式证书路径支持。
- 新增升级与恢复故障回归测试、安装引导测试；修复 Bash 语法检查原先仅实际检查第一个文件的问题。

## 4.1.1

- 安装流程开始时立即创建或修复 `v2ray` 管理命令，避免下载或配置失败时命令缺失。
- 配置校验失败时显示 Xray 原始错误输出，便于定位问题。
- 修复最新版 Xray 无法识别以 `.new` 结尾的临时配置文件的问题。
- 安装器固定下载已验证的管理脚本版本，避免 GitHub CDN 缓存造成新旧脚本混用。
- 防止把 Cloudflare/WARP 出口 IP 自动写入客户端链接，并提示设置真实入口地址。

## 4.1.0

- 一行安装命令改为自动完成推荐协议的首次部署；完成后输入 `v2ray` 进入管理菜单。
- 首次自动部署从 `24443` 起选择空闲端口，避免与 Caddy、Nginx 等 Web 服务争用 `443`。
- 自动修复失效的 `/usr/local/bin/v2ray` 符号链接。

## 4.0.0

- Replaced the single-inbound model with a multi-inbound registry under `/etc/xray/nodes`.
- Added independent add, modify, enable, disable, delete, list, and link-output operations.
- Existing installations migrate automatically to a `primary` inbound.
- All active inbounds are merged into one validated Xray configuration with transactional backup and rollback.

## 3.1.0

- Expanded the selector to eleven modern and legacy-compatible protocol profiles.
- Added concise characteristics and deployment requirements directly to the protocol menu.

## 3.0.0

- Added five selectable VLESS profiles across REALITY/TLS and RAW/XHTTP/gRPC/WebSocket transports.
- Added profile-aware configuration rendering, share links, menus, certificate import, backup, and restore.
- Validate every generated profile against the latest stable Xray Core in CI.
- Added VLESS-gRPC-TLS, Trojan-REALITY-RAW, Trojan-WebSocket-TLS, and legacy VMess TCP/WS/gRPC profiles with in-menu guidance.

## 2.2.0

- Added an occupied-port preflight check that never stops an unrelated service.
- Added `V2M_ADDRESS` for servers whose reachable address differs from their detected outbound IP.
- Added the classic `v2ray change` submenu and a bilingual, field-oriented connection display.
- Added timestamped installation stages while retaining the modern VLESS REALITY stack.
- Preserve a pre-existing `/usr/local/bin/v2ray` manager and restore it on uninstall.

## 2.1.0

- Added automatic configuration backup and rollback on failed service restarts.
- Added manual `backup` and `restore` commands with ten-backup retention.
- Added `doctor` diagnostics for the core, configuration, service, DNS and listening port.
- Added non-interactive installation through `V2M_*` environment variables.
- Added unit tests and live configuration validation against the latest stable Xray Core.
- Added architecture, operations and security documentation.

## 2.0.0

- Replaced the legacy VMess/TCP default with Xray Core, VLESS, REALITY and XTLS Vision.
- Added release archive SHA-256 verification.
- Added REALITY credential rotation and hardened systemd service settings.
- Added migration handling for installations created by the 1.x series.

## 1.1.0

- Added the `v2ray` management command and one-line installation bootstrapper.
