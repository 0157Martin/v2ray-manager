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

TLS 组合不会自动修改 DNS、Caddy 或 Nginx，需提供现有 PEM 证书和私钥路径。

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
v2ray info             # 查看版本和连接信息
v2ray change           # 打开分级修改菜单
v2ray config           # change 的兼容别名
v2ray link             # 重新显示 VLESS 导入链接
v2ray status           # 查看服务状态
v2ray start
v2ray stop
v2ray restart
v2ray log              # 查看最近 100 条日志
v2ray update           # 更新 Xray Core，保留配置
v2ray update.sh        # 更新管理脚本
v2ray rotate           # 轮换 REALITY 密钥和 Short ID
v2ray backup           # 创建配置备份
v2ray restore          # 恢复最近一份备份
v2ray doctor           # 运行综合诊断
v2ray uninstall
```

执行 `rotate` 后旧客户端链接会立即失效，需要重新导入新链接。

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

`V2M_UUID` 可省略，脚本会自动生成。服务器使用 NAT、WARP 或出口代理时，应通过 `V2M_ADDRESS` 指定客户端实际连接的 IP 或域名。安装前会检查 TCP 端口，已被其他服务占用时将安全退出。不要在共享日志中输出 UUID 或生成后的导入链接。

`V2M_PROFILE` 的可选值与交互菜单一致（例如 `vless-reality-raw`、`trojan-reality-raw`、`vmess-tls-ws`）。XHTTP/WebSocket 可用 `V2M_PATH` 指定路径；TLS 组合还需 `V2M_CERT_FILE` 和 `V2M_KEY_FILE`。

## 安装提示

一行安装命令会自动完成首次部署，但不会直接弹出协议选择菜单。首次默认使用推荐的 `VLESS-REALITY-Vision-RAW`，并从 `24443` 起自动寻找空闲端口，避免占用常见的 Web 服务端口。内核下载成功后会立即创建或修复 `v2ray` 管理命令；即使后续配置校验失败，也可以直接输入 `v2ray` 重试或查看诊断。完成后输入 `v2ray` 进入菜单，再按需要添加或管理其他协议组合。

从管理菜单开始安装时需要选择：

1. 监听端口，默认 `443`。
2. 客户端 UUID，可使用自动生成值。
3. REALITY 目标域名，默认 `www.microsoft.com`。应选择服务器可以稳定访问、支持 TLS 1.3 且与服务器网络位置合理的站点。
4. 节点备注。

安装后需要在云服务商安全组及服务器防火墙中放行所选 TCP 端口。本脚本不会自动修改防火墙、DNS 或系统代理。

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

每次推送都会在 Ubuntu 24.04 上运行 Bash 语法检查、ShellCheck、单元测试，并下载 Xray 最新稳定版验证生成的 VLESS REALITY 配置。
