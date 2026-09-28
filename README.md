# V2Ray 安装与管理脚本

作者：[0157Martin](https://github.com/0157Martin)

这是一个供**你拥有或获授权管理的 Debian/Ubuntu 服务器**使用的轻量 Bash 脚本。它从 V2Fly 的 GitHub Release 下载 V2Ray Core，并创建一个由 systemd 管理的 VMess/TCP 服务。交互和命令设计受 [233boy/v2ray](https://github.com/233boy/v2ray) 启发；本仓库为独立实现，并未复制其代码。

## 特点

- 从 `v2fly/v2ray-core` 的最新正式 Release 下载对应架构的程序
- 每次更新配置先用 `v2ray test` 校验
- 菜单包括安装、改配置、启动、停止、重启、状态、日志与卸载
- 安装后提供 `v2ray` 管理命令，包含 `info`、`config`、`link`、`update` 与 `update.sh`
- 服务使用专用、不可登录的 `v2ray` 系统账户；运行配置仅 root 和该账户可读
- 不更改防火墙、安全组、DNS 或系统代理，避免意外中断现有网络

## 使用

把 `v2ray.sh` 上传至服务器后运行：

```bash
sudo bash v2ray.sh
```

安装完成后可直接管理：

```bash
v2ray                 # 打开交互菜单
v2ray info            # 查看版本及连接信息
v2ray config          # 修改端口、UUID、备注
v2ray link            # 输出 VMess 导入链接
v2ray status          # 查看 systemd 状态
v2ray start|stop|restart
v2ray log             # 查看最近 100 条服务日志
v2ray update          # 更新 V2Ray Core，保留现有配置
v2ray update.sh       # 更新管理脚本
v2ray uninstall
```

也可使用与原脚本相同风格的一行安装命令：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/0157Martin/v2ray-manager/main/install.sh)
```

如果服务器只安装了 `wget`，可改用：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/0157Martin/v2ray-manager/main/install.sh)
```

引导脚本会先下载主脚本到临时文件再执行，以便可靠安装后续的 `v2ray` 管理命令。对于生产服务器，建议先打开并审阅 [install.sh](https://github.com/0157Martin/v2ray-manager/blob/main/install.sh) 与 [主脚本](https://github.com/0157Martin/v2ray-manager/blob/main/v2ray.sh)。

也可使用非交互入口：

```bash
sudo bash v2ray.sh install
sudo bash v2ray.sh status
sudo bash v2ray.sh link
sudo bash v2ray.sh uninstall
```

安装完成后，按脚本输出在云安全组与服务器防火墙放行所选 TCP 端口。默认配置为 **VMess over TCP，未启用 TLS**；对于敏感业务，应在受信任的网络环境中使用，或在反向代理/传输层中另行部署 TLS。

## 文件位置

| 内容 | 位置 |
| --- | --- |
| V2Ray Core | `/usr/local/bin/v2ray-core` |
| 管理命令 | `/usr/local/bin/v2ray` |
| 配置 | `/etc/v2ray/config.json` |
| systemd 服务 | `/etc/systemd/system/v2ray.service` |
| 管理状态 | `/etc/v2ray/manager.env` |

卸载仅移除上表中由本脚本创建的内容。专用 `v2ray` 系统账户会保留，以免误影响同名的其他服务。

## 仓库结构

本仓库采用与参考项目相近的入口与目录布局，但实现代码独立维护：

```text
.
├── install.sh              # 一行安装命令使用的下载引导脚本
├── v2ray.sh                # 主安装器和 v2ray 管理命令
├── config/                 # 默认值和项目元数据
├── src/                    # 源码组织说明与开发约定
├── templates/              # 配置模板参考
├── tools/                  # 本地检查工具
└── .github/                # Issue 模板
```
