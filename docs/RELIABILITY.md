# 6.4.0 可靠性改造

6.4.0 首先交付固定依赖、可选择的内核版本、关联回退、持久化恢复入口及回归测试。
Hysteria2、XHTTP 高级预设、监控指标、声明式配置及源码模块化随后已在 6.5.0 完成并发布；
本文件后续章节保留的是当时的阶段划分和设计依据。

## 组件版本锁

`v2ray.sh` 的 `component_manifest()` 是唯一运行时版本清单，嵌入单文件发布物，
包含组件仓库、完整提交、文件名和 SHA-256，不依赖额外文件。维护者更新组件时必须
一起审查提交和更新摘要，不允许回退到 `main` 或忽略摘要错误。

| 组件 | 固定提交 |
| --- | --- |
| Caddy manager | `f5b872a2ff4fe602ce7509737869d829e4b80e2d` |
| Cloudflare IP manager | `c6a2e4c8c8a7543e523468f396c6cdbae3b5564e` |
| WireGuard manager | `bc1d425add8f172838ea450cfc2955ade1e73a0c` |
| MASQUE manager | `93cd9564cb9e7d6872916dab5ef00bbf4d21816b` |

下载仅允许 HTTPS 及 HTTPS 重定向，连接超时 15 秒、每次传输超时 120 秒，最多重试
3 次。完成摘要及 Bash 语法检查后，在目标文件同目录原子替换。失败保留已安装文件。
摘要匹配的已安装文件可离线使用。WARP 的只读诊断不自动替换不匹配的旧脚本，而是拒绝执行
并提示运行 install/repair；Caddy 和 Cloudflare 分支入口会在调用前检查并安装锁定版本。

摘要固定在受审查的主脚本中，不从组件可变分支动态获取。它防止版本漂移和不匹配内容被安装，
但不是独立签名系统，也不锁定各组件内部的 APT 软件包、下载的核心或网页资源。
上游组件尚未提供统一接口版本字段，当前以具体提交锁定接口契约；更新仍需人工审查与部署验收。

## 内核选择

固定基线：[`v26.3.27`](https://github.com/XTLS/Xray-core/releases/tag/v26.3.27)。

```bash
v2ray versions
v2ray update.core --version v26.3.27 --check
v2ray update.core --version v26.3.27
v2ray update.core --latest --check
v2ray update.core --latest
v2ray rollback.core
```

`update` 保留为 `update.core` 的兼容入口。不传版本时使用项目固定基线；环境变量
`V2M_XRAY_VERSION` 可覆盖安装及更新的默认值，命令行选择优先。
`--version` 与 `--latest` 互斥，缺失参数及不合法的标签在下载前被拒绝。
`--check` 不安装依赖、不修改配置、不进行状态迁移、不重启服务；它只报告版本，
不代表该版本资源已下载或已通过本机配置测试。

升级和显式回退均先校验候选核心能否读取当前配置。保留成功升级前的内核与 GeoData，
供运行一段时间后主动回退。内核回退不恢复节点配置；旧核心不兼容当前配置时停止操作。
检查到原服务已停止时，升级或回退都不启动该服务。

## 管理器事务

```text
下载候选脚本并校验
  → 保存文件及服务状态，生成校验清单
  → 原子写入 manager.pending
  → 替换管理脚本并运行数据迁移
  → 成功：发布 manager.rollback 并移除 pending
  → 失败：恢复关联快照；恢复失败则保留 pending 与现场
```

每一代快照目录为 `/var/backups/v2ray-manager/manager-transaction.<ID>`，目录仅 root
可访问。记录脚本版本、数据版本、Xray/Caddy 运行状态和文件摘要。快照覆盖：

- `/usr/local/bin/v2ray`。
- `/etc/xray`，包括节点、TLS 材料与 WARP 策略状态。
- Caddy 主配置、受管站点配置。
- Xray systemd 服务定义。
- `/usr/local/libexec/v2ray-manager` 的组件脚本。

不覆盖 Xray 核心、APT 包、Caddy 网页内容、ACME 账户和 `/etc/letsencrypt`、WARP
后端自行维护的隧道配置或运行状态。更改这些资源的跨项目操作仍不能视作全系统事务。
回退后会按快照恢复 Xray/Caddy 的运行或停止状态。
快照范围内若包含符号链接，升级在替换之前拒绝继续，避免把指向外部可变文件的链接误作
已保存的历史内容。此类自定义布局需先明确其备份与恢复策略。

`v2ray rollback.sh` 会恢复关联数据并移除快照之后新增的节点和文件；回退前的现场另存
为新一代快照。不存在关联快照时拒绝只恢复旧脚本，避免脚本与数据结构错配。
由 6.3.x 旧更新器执行的首次升级没有这种关联快照，不能追溯生成历史状态。

## 中断恢复

存在 `manager.pending` 时，后续修改被阻止，内部升级迁移和显式恢复除外：

```bash
v2ray recover
```

若管理命令无法执行，使用失败信息中打印的具体 `recovery.sh` 路径执行 `recover`。
每个快照保存一份当时的协调器，不依赖被替换后的管理脚本能正常启动。
恢复入口不先迁移当前数据；即使当前目录含更高版本的数据也能恢复。校验清单或格式错误
会拒绝恢复并保留 pending；文件复制或服务检查失败也保留现场，便于排错后重试。

这是基于文件日志的进程中断恢复机制，不承诺在断电、文件系统损坏或存储设备丢写时提供
数据库级持久性。不能捕获 SIGKILL；下一次操作通过未清理的 pending 识别中断。
内核更新仍使用自己的失败回退逻辑，尚未加入同样的 pending 恢复入口。

普通配置归档保留最近 10 份；管理器和核心事务代际单独保留，不自动删除。运维时检查
`du -sh /var/backups/v2ray-manager`。仅在确认不再需要，且目录未被 `manager.pending`、
`manager.rollback` 或 `core.rollback` 引用后，才可人工清理。

## 验证与后续工作

`tests/reliability.sh` 覆盖固定版本、无效参数、只读查询、组件摘要失败、离线复用、
管理脚本升级失败、关联回退、持久化恢复、快照损坏和停用节点的新数据版本保护。
`tests/recovery.sh` 增加成功升级后的主动内核回退。

CI 将 Ubuntu x64/ARM64、Debian 容器及固定/最新 Xray 版本分开验证；Actions 固定完整提交。
本地与 CI 的实际结果见 [VALIDATION.md](VALIDATION.md)，配置测试不等于生产部署验收。

上述后续项目已在 6.5.0 分阶段完成：结构化诊断、Caddy/XHTTP 真实互通、Hysteria2 的
UDP/TLS/认证测试、状态 JSON 化和源码模块化均有独立回归覆盖。公网 UDP、防火墙和不同客户端
实现的兼容性仍需在目标 VPS 与实际客户端环境中验收。
