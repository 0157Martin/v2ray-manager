# Xray / VLESS REALITY 安装与管理脚本

作者：[0157Martin](https://github.com/0157Martin)

面向**你拥有或获授权管理的 Debian/Ubuntu 服务器**的一键安装与管理脚本。项目保留熟悉的 `v2ray` 管理命令，但底层已升级为 Xray Core，默认部署 VLESS + REALITY + XTLS Vision。

## 协议组合

1. VLESS + REALITY + XTLS Vision + RAW（默认推荐）
2. VLESS + REALITY + XHTTP
3. VLESS + REALITY + gRPC（兼容用途）
4. VLESS + TLS + XHTTP（需自有域名和证书）
5. VLESS + TLS + WebSocket（需自有域名和证书）
6. VLESS + TLS + gRPC（需自有域名和证书）
7. Trojan + REALITY + RAW
8. VMess + TCP（旧版兼容，无 TLS/REALITY）
9. VMess + WebSocket + TLS（旧版兼容）
10. VMess + gRPC + TLS（旧版兼容）
11. Trojan + WebSocket + TLS
12. VLESS + TLS + XTLS Vision + RAW（官方教程组合）

TLS 组合不会自动修改 DNS、Caddy 或 Nginx。可通过环境变量提供现有 PEM 证书与私钥；未提供时，脚本先匹配已有证书，找不到才使用 Certbot 申请。自动申请需要你拥有的域名指向本机、公网 TCP 80 可达，并会接受 Let's Encrypt 服务条款。默认使用 standalone，要求本机 80 端口空闲；已有网站可设置 `V2M_ACME_WEBROOT=/var/www/html`，由该网站响应 HTTP challenge。证书按域名保存，Certbot 续期后通过部署钩子校验、同步，部署失败回滚。

## 当前技术方案

- Xray Core 最新稳定 Release
- VLESS 协议与 REALITY 传输安全
- XTLS Vision 流控及 RAW/TCP 传输
- 下载官方发布包及其 `.dgst`，安装前验证 SHA-256
- 独立的 `xray` 低权限系统账户和 systemd 安全加固
- 自动生成 UUID、X25519 密钥对与 Short ID
- 输出主流客户端可导入的 `vless://` 链接
- 修改配置或轮换密钥失败时自动恢复上一份可用配置
- 自动保留最近 10 份配置备份，支持手动备份和恢复
- 提供运行状态、配置、DNS 与监听端口综合诊断
- 支持环境变量驱动的非交互安装
- 支持单个 Xray 进程同时运行多个独立入站
- 支持添加、修改、停用、启用和删除单个入站
- `v2ray links` 一次输出全部启用入站的有效链接

## 一行安装

请使用 root 用户运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/0157Martin/v2ray-manager/main/install.sh)
```

只有 `wget` 时：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/0157Martin/v2ray-manager/main/install.sh)
```

生产服务器建议先审阅 [install.sh](https://github.com/0157Martin/v2ray-manager/blob/main/install.sh) 和 [v2ray.sh](https://github.com/0157Martin/v2ray-manager/blob/main/v2ray.sh)。

## 管理命令

```bash
v2ray                  # 打开菜单
v2ray add              # 添加独立入站
v2ray inbounds         # 查看入站列表
v2ray links            # 输出全部启用入站链接
v2ray firewall         # 放行已启用入站的本机 UFW/firewalld TCP 端口
v2ray info             # 查看版本和连接信息
v2ray change           # 打开分级修改菜单
v2ray config           # change 的兼容别名
v2ray link             # 重新显示默认入站链接
v2ray link primary 104.16.1.1 # 用 CDN/优选 IP 导出，SNI/Host 仍使用原域名
v2ray client           # 输出默认启用入站的 Xray 客户端 JSON
v2ray client primary   # 按入站 ID 导出；ID 见 v2ray inbounds
v2ray status           # 查看服务状态
v2ray start
v2ray stop
v2ray restart
v2ray log              # 查看最近 100 条日志
v2ray speedtest        # 测试服务器下载、上传速度和延迟
v2ray caddy            # 打开 Caddy 网站管理菜单
v2ray update           # 更新 Xray Core，保留配置
    v2ray update.sh        # 更新管理脚本
    v2ray rollback.sh      # 恢复上一次更新前的管理脚本
v2ray rotate           # 轮换 REALITY 密钥和 Short ID
v2ray backup           # 创建配置备份
v2ray restore          # 恢复最近一份备份
v2ray doctor           # 运行综合诊断
v2ray uninstall
```

主菜单按“安装、入站管理、连接与导出、Xray 服务、Caddy、维护诊断、卸载”分组，并显示
Xray/Caddy 运行状态和启用、停用入站数量。链接和客户端配置只在“连接与导出”中按用户
选择显示；进入子菜单后可以连续操作，选择 `0` 返回主菜单。

执行 `rotate` 后旧客户端链接会立即失效，需要重新导入新链接。

`v2ray speedtest` 也可从“维护工具 → Speedtest 服务器测速”运行。脚本优先使用已安装的
Ookla `speedtest` 或 `speedtest-cli`；均不存在时安装系统仓库的 `speedtest-cli`。测速会
连接外部 Speedtest 服务器、暴露服务器公网 IP，并消耗一定流量，但不会修改或重启 Xray。

## Caddy 网站伪装与反向代理

主菜单的“Caddy 网站管理”支持通过 Caddy 官方 Debian/Ubuntu 稳定仓库和 GPG key 自动安装，
并提供两种站点：

- 静态伪装网站：为域名生成独立站点目录和简单首页，由 Caddy 自动申请及续期 HTTPS 证书。
- 本机反向代理：把域名代理到 `127.0.0.1:端口`、`localhost:端口` 或 `[::1]:端口`，适合
  本机面板、API 或 Web 应用。为避免开放代理，不接受公网或局域网后端地址。

也可以使用非交互命令：

```bash
v2ray caddy install
v2ray caddy static www.example.com
v2ray caddy reverse app.example.com 127.0.0.1:8080
v2ray caddy xray cdn.example.com 127.0.0.1:24443 /a1b2c3
v2ray caddy status
v2ray caddy log
```

项目不会覆盖现有 Caddyfile，而是在备份后自动追加一次
`import /etc/caddy/conf.d/*.caddy`，站点配置按域名单独保存。写入前备份主 Caddyfile，
新配置必须通过 `caddy validate` 才会 reload；失败时恢复旧站点配置。Caddy 自动 HTTPS
要求域名 A/AAAA 记录指向服务器，并确保公网 TCP 80 和 443 可达。

标准 Caddy 与 Xray 不能同时监听同一 TCP 80/443。若 Xray 或其他程序已占用其中任一端口，
管理器会拒绝安装或配置 Caddy，不会停止现有服务。请先把 Xray 入站改到其他端口，再配置
Caddy。普通 `reverse` 面向 HTTP Web 应用；`xray` 模式按 XHTTP/WS 路径反向代理到使用同一
域名证书的本机 Xray TLS 入站，并让其他路径显示静态伪装页。它不能代理 REALITY/RAW。
建议 Xray 使用 `24443` 等高位端口，Caddy 独占公网 `80/443`。应用前应确认 Xray 的域名、
证书和传输路径与 Caddy 参数完全一致。

Cloudflare 橙云或优选 IP 仅适用于 HTTP 兼容的 TLS XHTTP/WebSocket 节点。使用
`v2ray link <入站ID> <优选IP或CDN域名>` 导出时，连接地址和客户端端口会改为指定地址与
`443`，但 TLS SNI、HTTP Host 和证书域名仍保留节点原域名，避免把优选 IP 错当成证书域名。
Cloudflare 代理不适用于普通 VLESS RAW、REALITY 或任意 TCP 节点。

## 按官方教程部署与导出

4.3.0 依据 [服务器篇](https://xtls.github.io/document/level-0/ch07-xray-server.html)、[证书篇](https://xtls.github.io/document/level-0/ch06-certificates.html) 和 [客户端篇](https://xtls.github.io/document/level-0/ch08-xray-clients.html) 增加 TLS Vision、webroot 申请和原生客户端配置导出。字段使用实际稳定版 Xray 验证；教程中的网站回落、地区分流、SSH 与内核设置需按服务器用途配置，本脚本不自动照搬。

选择菜单协议 12，或使用 `V2M_PROFILE=vless-tls-raw`，即可部署 TLS + Vision。该组合需要自有域名及有效证书，直接连接 Xray 的 TLS 端口，不能把它当成 WebSocket 节点放到普通 HTTP CDN 后面。

以 root 在服务器上导出：

```bash
umask 077
v2ray client primary > client.json
```

将 `client.json` 安全复制到客户端电脑，用 Xray Core 运行 `xray run -config client.json`，应用连接本机 SOCKS `127.0.0.1:10800` 或 HTTP `127.0.0.1:10801`。此 JSON 供 Xray Core 使用，GUI 客户端是否支持完整 JSON 导入取决于其功能。导出前核对启用入站与运行配置，自动填入 UUID、SNI、流控及传输参数；不导出服务端私钥。TLS 保持正常 CA 校验，自建 CA 需另外配置客户端信任。

Certbot 续期钩子执行 `v2ray cert-refresh "$RENEWED_LINEAGE"`：仅更新登记了该来源的域名，先验证有效期、域名、私钥和 CA 链，再部署并检查 Xray 配置；运行中的服务重启失败会恢复旧证书，停止的服务保持停止。失败时保留备份目录并报错。

使用 acme.sh 时，按官方教程先用 `--install-cert` 将证书部署到稳定路径，再以 `V2M_CERT_FILE` / `V2M_KEY_FILE` 导入；脚本不再自动读取 `.acme.sh` 内部工作文件。外部证书的后续同步需由相应 ACME 客户端配置部署钩子，Certbot 钩子不会自动接管它。

## 非交互安装

自动化部署时可以传入环境变量：

```bash
export V2M_NONINTERACTIVE=1
export V2M_PORT=443
export V2M_PROFILE=vless-reality-raw
export V2M_ADDRESS=203.0.113.10
export V2M_SERVER_NAME=www.microsoft.com
export V2M_REMARK=my-server
bash <(curl -fsSL https://raw.githubusercontent.com/0157Martin/v2ray-manager/main/install.sh)
```

`V2M_UUID` 可省略，脚本会自动生成。服务器使用 NAT、WARP 或出口代理时，必须通过 `V2M_ADDRESS` 指定客户端实际连接的 IP 或域名；脚本检测到 Cloudflare/WARP 出口时不会把该出口 IP 写入链接。安装前会检查 TCP 端口，已被其他服务占用时将安全退出。不要在共享日志中输出 UUID 或生成后的导入链接。

`V2M_PROFILE` 的可选值与交互菜单一致（例如 `vless-reality-raw`、`trojan-reality-raw`、`vmess-tls-ws`）。XHTTP/WebSocket 可用 `V2M_PATH` 指定路径；TLS 组合须设置 `V2M_SERVER_NAME` 为你拥有的域名，可用 `V2M_CERT_FILE` 和 `V2M_KEY_FILE` 指定证书，或让脚本自动查找/申请。`V2M_ACME_EMAIL` 可选，用于 Certbot 账户邮箱。

## 更新与回退

`v2ray update` 在临时目录下载并校验新内核和 GeoData，用新内核检查当前配置后才替换文件。运行中的服务重启后会连续检查 5 秒；文件替换或健康检查失败时自动恢复旧内核与 GeoData。原先停止的服务保持停止。自动回退失败时，会输出保留的恢复文件目录。该检查用于发现启动故障，不代表已验证客户端到服务器的端到端连通性。

`v2ray update.sh` 和安装器默认通过 GitHub API 解析 `main` 的完整提交 SHA，再从该固定提交下载脚本，避免一次操作中版本漂移。可设置 `V2M_MANAGER_REF` 为完整的 40 位提交 SHA，以部署指定版本或绕过提交查询的 API 限流。下载通过 HTTPS，并检查 Bash 语法与项目标识；这不是独立签名验证。

管理脚本更新前会保存 `/var/backups/v2ray-manager/manager.previous.sh`，可用 `v2ray rollback.sh` 恢复。若新管理命令本身无法运行，可用 root 执行 `install -m 755 /var/backups/v2ray-manager/manager.previous.sh /usr/local/bin/v2ray`。重新运行安装不会升级已存在的内核；请使用独立的 `v2ray update` 命令。

## 安装提示

一行安装命令在交互终端中会先显示协议列表，必须由用户自行选择协议组合；安装结束时不会自动输出 UUID 或默认链接。随后从 `443` 开始选择监听端口：443 空闲时默认使用 443；已被 Caddy、Nginx 或其他服务占用时，不会停止现有服务。脚本启动后会立即创建或修复 `v2ray` 管理命令；即使后续下载或配置校验失败，也可以直接输入 `v2ray` 重试或查看诊断。完成后输入 `v2ray` 进入菜单；需要导出时主动运行 `v2ray links` 或 `v2ray link`。

没有交互终端时，安装器不会静默创建默认协议。CI、云初始化等自动化部署必须明确设置
`V2M_NONINTERACTIVE=1`，并建议同时提供 `V2M_PROFILE` 等参数；未提供的非交互参数才使用
脚本默认值。

从管理菜单开始安装时需要选择：

1. 监听端口，默认 `443`。
2. 客户端 UUID 自动生成或沿用，脚本校验格式，无需手动填写。
3. REALITY 目标域名，默认 `www.microsoft.com`。应选择服务器可以稳定访问、支持 TLS 1.3 且与服务器网络位置合理的站点。
4. 节点备注。

安装或新增入站后，脚本会检测已启用的本机 UFW 或 firewalld，并自动放行全部已启用入站的 TCP 端口；也可随时运行 `v2ray firewall` 重试。未启用这两种防火墙时，脚本不会猜测或改写 iptables/nftables 规则。

云服务商安全组仍需在控制台手动放行所选 TCP 端口——它属于云账户权限，脚本没有也不应保存该账户的 API 凭据。本脚本不会自动修改 DNS 或系统代理。

## 导入后延迟为 -1 / 无法连接

`-1` 表示客户端测试没有成功，单凭这个结果不能区分入口地址、端口阻断、协议兼容或握手问题。先运行 `v2ray version`、`v2ray doctor` 和 `v2ray log`，确认服务器确实已部署修复后的脚本。诊断会检查全部入站端口、REALITY 目标握手和导出参数，但无法从本机证明公网端口可达。

- 修改入站后，用 `v2ray links` 重新导出并重新导入客户端；4.2.1 起，单条链接也读取最新的启用入站状态。
- 地址必须是客户端能访问的服务器公网 IP 或直连域名。NAT/WARP 的出口 IP 不一定是入口地址；NAT 环境还需核对外部端口映射。
- `v2ray firewall` 只处理本机已启用的 UFW/firewalld；云安全组需要放行**链接中的 TCP 端口**。自动安装优先使用 443；如果 443 已被占用，以实际导出链接中的端口为准。
- 从客户端网络检查 TCP 可达性，例如 Windows PowerShell 的 `Test-NetConnection <服务器地址> -Port <节点端口>`。TCP 成功仍不代表 REALITY/TLS 握手成功。
- 核对客户端及内核是否支持所选协议组合。RAW 服务端在分享链接中使用 `type=tcp`，这是分享格式的兼容写法，无须手动改成 `raw`。

导出器遇到未知地址或入站状态与配置不一致时会报错，避免生成可导入却注定失败的链接。排查时不要公开完整链接、UUID、私钥或未脱敏日志。

UUID 默认自动生成并写入服务器配置和链接；TLS 模式自动查找/申请并导入证书，校验域名、有效期和私钥匹配。导出前会再次校验证书或 REALITY 密钥对。REALITY 模式不需要申请普通 TLS 证书；普通 TLS 模式的客户端仍须信任证书颁发机构，脚本不会通过关闭证书验证来绕过失败。

## 从 1.x 升级

重新运行一行安装命令即可。检测到本项目旧版 `/etc/v2ray/manager.env` 和旧服务定义时，脚本会停用旧的 `v2ray.service`，但保留旧文件便于人工回退。2.x 使用新的 `xray.service` 和 `/etc/xray` 配置，不会静默删除旧配置。

## 文件位置

| 内容 | 位置 |
| --- | --- |
| Xray Core | `/usr/local/bin/xray-core` |
| 管理命令 | `/usr/local/bin/v2ray` |
| GeoData | `/usr/local/share/xray/` |
| 配置 | `/etc/xray/config.json` |
| 管理状态 | `/etc/xray/manager.env` |
| 入站状态 | `/etc/xray/nodes/*.env` |
| systemd 服务 | `/etc/systemd/system/xray.service` |
| 配置备份 | `/var/backups/v2ray-manager/` |

卸载仅删除 2.x 脚本创建的 Xray 文件；专用 `xray` 系统账户和旧版回退文件会保留。
如果安装前 `/usr/local/bin/v2ray` 已被其他管理器使用，脚本会先将它保存到 `/var/backups/v2ray-manager/legacy-v2ray-command`；卸载时自动恢复。

## 仓库结构

```text
.
├── install.sh
├── v2ray.sh
├── CHANGELOG.md
├── config/
├── src/
├── templates/
├── tests/
├── tools/
├── docs/
└── .github/
```

每次推送都会在 Ubuntu 24.04 上运行逐文件 Bash 语法检查、ShellCheck、单元测试、升级/恢复故障模拟和安装引导测试，并下载 Xray 最新稳定版验证全部协议组合及多入站配置。故障模拟不操作真实 systemd 或本机安装目录；真实服务器安装、证书申请和端到端连接仍需要部署环境验证。
