# Changelog

## Unreleased

## 5.7.5

- 修复主菜单、项目信息和关于页面在 Xray 已安装时，因版本输出管道的 `SIGPIPE` 同时显示真实版本与“未安装/不可用”的问题。

## 5.7.4

- 修复 Xray Core 更新成功后，版本输出被 `head` 提前关闭而在 `pipefail` 下误判失败并触发事务回滚的问题。

## 5.7.3

- 已运行的 Caddy 允许在项目升级时同步 XHTTP 路由；Certbot standalone 冲突继续由 `v2ray doctor` 报告，但只阻止会新启动 Caddy 并占用 TCP 80 的操作。

## 5.7.2

- 默认阻止代理用户访问回环、私网、链路本地等敏感目标；域名目标也参与 IP 路由判断，WARP 不再绕过这一策略。
- 修改操作通过独立 Bash 进程执行，统一使用 flock 写锁与配置/证书/Caddy/服务文件快照；失败或 INT/TERM 时恢复现场，升级迁移子进程继承锁。
- WARP 连通性检查失败时停止提交；配置 JSON 通过同目录临时文件原子替换，TLS 证书与私钥先成对暂存。
- Caddy 配置失败使 XHTTP 迁移失败并触发联合恢复；迁移只允许指定 XHTTP 字段变化，不再全局跳过连接参数校验。
- 有 Certbot standalone 续期配置时拒绝新增 Caddy 端口占用，要求先迁移验证方式并完成续期演练。
- 数据版本升级为 4；已有非 XHTTP 入站也应用出站隔离并在原服务运行时重启。恢复旧备份时重新执行迁移。
- 增加事务/迁移/证书故障注入、Linux 并发锁和真实 Xray 私网目标阻断测试。

## 5.6.1

- 默认网页写入和属主设置失败时正确返回失败；网页准备失败时恢复旧 Caddy 站点配置。
- 博客下载和复制失败显式返回失败，拒绝缺少首页的部署清单。
- 首次配置 Caddy 使用无需联网下载的内置网页；拒绝无效模板菜单输入。
- 更新提交获取失败时增加 DNS/出站诊断提示；明确 `warp off` 仅撤销 Xray 分流。
- 增加默认网页、写入失败、站点回滚与菜单输入回归测试。

- 将两个独立 Caddy 页面重构为个人博客：`portfolio` 使用无水印竹林角色背景，`resume` 使用纯排版纸张风格；个人网页安装与更新菜单新增无需下载的 `default` 内置网页选项。

- Caddy 个人网页拆分到独立的 `v2ray-portfolio-page` 与 `v2ray-resume-page` 仓库；菜单和命令行按模板选择对应仓库，下载固定提交的构建产物并校验 SHA-256，主项目不再存放网页源码与构建文件。
- Caddy 的“个人网页设置”拆分“安装随机个人主页”和“更新随机个人主页”；首次配置静态站点或 XHTTP/WS 路径反代时只自动安装一次，后续同步不再覆盖页面内容。新增 `v2ray caddy page-install <域名>` 与 `v2ray caddy page-update <域名>`。
- `v2ray doctor` 在 Xray 已启用 WARP 策略时检查 `warp-svc` 和本机 SOCKS 监听端口；WARP 服务不可用会明确报错并给出修复或停用命令，避免仅显示 Xray 正常而实际出站不可用。
- 主菜单、入站管理、连接与导出及入站列表改为带状态区、分隔线和编号分组的终端边框布局，保留原有菜单编号与命令行为。
- README 补充 REALITY 的传输范围、入口与目标站的区别、目标站检查条件、认证失败回落行为和密钥轮换后的客户端更新步骤，并链接 Xray 官方资料。
- README 新增安装前检查清单，说明系统权限、下载网络、端口规划、防火墙与云安全组、域名要求和凭据保护。
- README 的 Cloudflare 章节新增橙云与灰云对照表、协议适用范围、HTTPS 设置建议，以及 Caddy 与 REALITY 共用服务器时的分域名示例。
- README 的 WARP 章节明确流媒体检测仅检查公开 HTTP 可访问性，不承诺地区内容、账号或实际播放可用，并链接 Cloudflare 的 WARP 限制说明。
- Caddy 的 XHTTP/WS 路径反代改为按域名汇总全部匹配入站；同步新路径时保留既有路径，并拒绝同一路径指向不同后端的覆盖。

## 5.5.13

- 移除交互式终端菜单中的 ANSI 图像动画，避免启动菜单时改变终端内容。
- 将清除水印并重新补全画面的两张竹林角色图作为 README 项目介绍装饰图。

## 5.5.12

- 终端菜单动画改为由两张竹林角色图缩采样而成的 ANSI 半块字符帧；现代彩色终端会显示两张图对应的字符动画，缺少 `base64` 或 `gzip` 时自动回退到文字动画。

## 5.5.11

- 主菜单加入两帧 ANSI 终端动画，以“竹影守护”和“剑光突进”呈现启动过渡；只在交互式彩色终端显示。设置 `V2M_NO_ANIMATION=1` 可关闭。

## 5.5.10

- 配置修改和 REALITY 密钥轮换统一读取所选入站的当前注册表，避免旧管理状态恢复已撤销的子链接凭据；支持 `v2ray change [入站ID]` 和 `v2ray rotate [入站ID]`。
- 配置校验中间文件放入私有临时目录，失败或中断时自动清理；节点状态和数据版本标记使用创建即为 0600 的临时文件原子替换。
- 批量编辑在输入、证书、配置校验、重启失败或收到中断信号时恢复修改前的入站及配置；恢复失败时保留备份并明确报错。
- 统一入站 ID 校验，修复带点号的已有入站无法管理子链接、导出链接或客户端配置的问题。
- 新增隔离编辑回归测试，覆盖凭据撤销、指定节点、失败/中断回滚、敏感临时文件清理及 Linux 文件权限，并纳入 CI。

## 5.5.9

- REALITY 创建前验证目标站的 TLS 1.3、X25519/TLS 握手、H2 协商、证书链和 SNI 匹配，不再把任意可解析域名视为可用目标。
- `doctor` 新增 REALITY 本机入口回落测试，能够识别“端口在监听、目标可访问，但 Xray 回落握手仍超时”的假正常状态。
- VLESS-REALITY-Vision-RAW 从默认推荐调整为高级选项，明确要求目标站和客户端版本先通过实际检测。

## 5.5.8

- 入站修改、停用、启用和删除支持空格/逗号分隔的多个 ID，也支持使用 `all` 选择全部符合状态的入站。
- 批量修改可一次为多个入站设置相同入口域名或 REALITY 目标；完整编辑仍可逐个确认，最后只重建并重启一次。
- 批量操作先验证全部目标；批量删除要求输入完整的 `DELETE`，并在确认前列出目标入站。

## 5.5.7

- 将 REALITY 默认目标从在 Xray 26.3.27 上存在已知握手故障的 `www.microsoft.com` 改为 `dl.google.com`。
- 交互与无人值守安装会拒绝已知不兼容的 Microsoft REALITY 目标，并给出可执行的替代建议。

## 5.5.6

- 中文项目指南新增完整转发机制图，展示 Caddy 域名/路径匹配、Xray 入站认证、嗅探、路由
  规则以及 Direct、WARP、Blackhole 三种出站决策。
- 新增管理平面与数据平面运行图、配置变更事务图和 systemd/Xray 启动时序图，并解释多入站
  共享路由、失败回滚及响应返回路径。

## 5.5.5

- 新增中文《项目使用与原理指南》，以完整流量路径解释入站、子链接、Caddy、Cloudflare 和
  WARP 的职责、组合方式与安全边界。
- 补充首次安装、更新、端口规划、多人使用、备份回滚、延迟 `-1` 排障和敏感文件说明，并
  修正 README 主菜单描述中遗漏 WARP 的问题。

## 5.5.4

- 修复 WARP 诊断直接输出调试日志可能暴露许可证、账户、设备、公钥和注册标识的问题。
- 诊断日志现在只保留连接阶段、警告和错误行，并在输出前对凭据名称、值及 UUID 做二次脱敏；
  不再显示完整 `RegistrationInfo` 调试记录。

## 5.5.3

- WARP Local Proxy 现在显式选择 Cloudflare 要求的 MASQUE 隧道协议，再设置本机代理模式。
- 修复状态卡在 `Connecting / Happy Eyeballs` 时反复删除注册的问题；该状态现在识别为上游
  网络问题，并保留有效注册。
- 新增 WARP 上游诊断，显示时间同步、IPv4/IPv6 路由、UFW、客户端状态和服务日志，并列出
  Cloudflare 官方要求的 MASQUE 出站端口；可运行 `v2ray warp diagnose`。

## 5.5.2

- 修复 `warp-cli connect` 尚未完成就宣告安装成功的问题；现在等待本机代理端口最多 30 秒，
  并通过 Cloudflare trace 验证出口后才报告成功。
- WARP 本机代理启动失败时自动重连，必要时重新注册设备；修复菜单会恢复服务、代理模式、
  端口和 Xray 配置，并输出可用于继续排查的状态。
- WARP 检测、安装或策略操作失败后不再退出整个管理器，而是返回 WARP 菜单，避免后续菜单
  数字被 shell 当成命令执行。

## 5.5.1

- 修复 Caddy XHTTP/WS 反代路径留空时直接报错并退出菜单的问题；留空现在使用匹配入站的
  现有路径，找不到匹配项时使用 `/xhttp`。
- Caddy 会按 TLS 域名自动匹配已启用的 XHTTP/WS 入站并填入本机端口与路径；手动输入的
  路径缺少 `/` 时自动补齐，无效输入和配置失败会留在 Caddy 菜单中。

## 5.5.0

- WARP 菜单扩展为完整的九项管理界面，同时保持策略对全部协议统一生效，不按入站分别配置。
- 新增自动双栈、仅 IPv4、仅 IPv6 三种 WARP 目标地址策略，以及 Netflix、Disney+、ChatGPT
  当前出口可访问性检测；结果不作为账号地区或版权解锁承诺。
- 新增 WARP 一键修复：恢复服务、注册、本机代理端口并重新生成和校验 Xray 配置。

## 5.4.0

- 主菜单新增 WARP 出站管理，使用 Cloudflare 官方 Linux 客户端的本机代理模式，不接管
  服务器默认路由，不影响 SSH、Caddy 或系统更新。
- WARP 策略统一作用于全部 VLESS、VMess、Trojan 入站，可选择指定域名分流或全部 Xray
  公网 TCP 流量；UDP 和私有地址始终直连，现有 UUID、端口和分享链接保持不变。
- 新增 WARP 安装、注册、状态、出口检测、关闭和卸载操作；策略写入 Xray 配置前执行校验，
  服务启动失败时随项目配置一起回滚。

## 5.3.0

- 默认安装流程只部署 Xray Core、空入站配置、systemd 服务和管理命令，不再弹出协议选择，
  也不创建默认链接；安装后通过 `v2ray add` 或入站管理菜单手动选择协议。
- 空入站成为受支持的配置状态，第一次添加协议以及删除最后一个入站都可正常重建配置。
- 重新运行安装/修复会保留已有入站和链接；显式设置 `V2M_NONINTERACTIVE=1` 时仍可供
  CI、云初始化等自动化场景直接创建入站。

## 5.2.0

- 新增 `v2ray upgrade` 一键项目更新入口；下载并校验新脚本后自动迁移数据结构、重建配置，
  并验证现有入站连接参数保持不变。
- 项目状态和入站文件新增数据结构版本；迁移失败或链接参数发生非预期变化时自动恢复配置和
  旧管理脚本。`v2ray update.sh` 保留为兼容别名。
- 新脚本运行时自动检测旧数据版本，兼容由 5.1 及更早更新器完成的首次脚本替换。

## 5.1.0

- README 新增 12 种协议的 Cloudflare 橙云兼容表，说明 REALITY/RAW 必须直连、
  WebSocket/gRPC 的使用条件、支持端口以及 Spectrum 与普通橙云的区别。
- 重写项目简介、功能概览和协议选择指南，修正命令缩进、旧版本说明及端口行为描述，
  并补充安装后的最短检查与导出流程。
- 子链接管理升级为按序号查看、新增、删除和重新生成凭据；单项操作只影响指定链接，
  同时保留原有的按总数设置命令。
- 入站列表按 REALITY 直连、TLS HTTP/CDN、其他直连与旧版兼容分组，并显示每个入站的
  当前链接数量。

## 5.0.0

- 一个入站现在支持 1–10 个独立用户凭据和可同时使用的子链接，共享协议、端口及传输配置。
- “连接与导出”新增按入站选择子链接总数；保留已有凭据，按目标数量补充或裁剪，并通过
  Xray 配置校验、服务健康检查和失败回滚后生效。
- 新增 `v2ray users <入站ID> <1-10>` 命令；多链接备注自动追加序号，客户端 JSON 默认
  使用第一条凭据。

## 4.9.0

- 新建入站默认从 443 自动寻找空闲端口，443 被占用时选择后续端口，不停止已有服务。
- 用户选完协议后立即显示最终协议名称；安装完成仍不自动输出完整节点链接。
- 分享链接停止探测和写入公网 IP：TLS 节点使用证书域名，其他节点要求配置入口域名；
  CDN 自定义入口同样只接受域名。

## 4.8.1

- 协议选择菜单按“直连/灰云”“HTTP/CDN 橙云”“旧版兼容”重新分组，同时保持原编号。
- 所有 REALITY 组合明确标注必须直达 Xray、不能经过 Cloudflare 普通橙云；XHTTP/gRPC
  传输名称不再被描述成自动兼容 CDN。
- 普通 TLS XHTTP/WebSocket/gRPC 明确标注为 Caddy/CDN 方案，RAW 标注为直连方案。

## 4.8.0

- 维护菜单新增路由与延迟测试，使用 Ping 和 10 轮 MTR 显示 VPS 到目标的回程路径、逐跳
  丢包及平均延迟，并保留 Speedtest 带宽入口。
- 根据当前节点地址和端口生成 Windows、Linux/macOS 客户端去程测试命令，明确区分去程
  与回程，避免把服务器侧探测误报为客户端真实路由。
- 新增 `v2ray route <目标IP或域名>` 非交互回程测试命令和严格的目标格式校验。

## 4.7.0

- 重组主菜单为安装、入站、连接导出、Xray 服务、Caddy、维护诊断和卸载七个入口。
- 主界面显示 Xray/Caddy 服务状态及启用、停用入站数量，并根据安装状态调整首项说明。
- 新增独立“连接与导出”菜单，由用户选择普通链接、CDN 优选链接或客户端 JSON。
- 入站、服务、Caddy 和维护子菜单支持连续操作，并明确提供返回主菜单入口。

## 4.6.1

- 一行安装器在交互终端中要求用户自行选择协议，不再强制进入非交互默认协议安装。
- 无终端运行时不再静默创建默认节点；自动化部署必须明确设置 `V2M_NONINTERACTIVE=1`。
- 安装完成后继续保持不自动输出 UUID 或默认分享链接。

## 4.6.0

- Caddy 新增按路径代理 Xray TLS XHTTP/WebSocket 入站，并为其他路径提供静态伪装页面。
- `v2ray link <入站ID> <CDN地址>` 支持 Cloudflare/优选 IP 导出，固定客户端端口为 443，
  同时保留原域名作为 SNI/Host，避免证书校验失败。
- 初次安装成功后不再自动输出 UUID 和默认分享链接，改为提示用户按需运行导出命令。

## 4.5.0

- 主菜单新增 Caddy 网站管理：通过官方稳定仓库和 GPG key 自动安装 Caddy、创建自动 HTTPS
  静态伪装网站，以及反向代理到受限的本机后端地址。
- Caddy 站点使用独立 `conf.d` 配置，保留现有 Caddyfile；应用前校验，reload 失败恢复旧
  站点配置，并检测 Xray 或其他服务的 TCP 80/443 冲突。
- 新增 `v2ray caddy install|static|reverse|status|log` 非交互命令和 Caddy 配置单元测试。

## 4.4.0

- 维护工具菜单新增 Speedtest 服务器测速，并提供 `v2ray speedtest` 命令；自动识别 Ookla
  CLI 或 `speedtest-cli`，缺少时从系统仓库安装，测速过程不重启或修改 Xray。

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
