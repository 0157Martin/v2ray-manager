# Security

请勿在公开 Issue 中提交服务器 IP、UUID、REALITY 私钥、完整配置文件或未脱敏日志。

以下信息可安全用于排查：操作系统版本、`v2ray version` 输出、经过脱敏的
`v2ray status` 与 `v2ray log` 输出。REALITY 私钥只应保存在服务器的
`/etc/xray/config.json` 和 `/etc/xray/manager.env` 中。
自动备份保存在 `/var/backups/v2ray-manager/`，权限为仅 root 可读，也应按敏感凭据处理。
6.4.0 的管理事务目录还保存完整关联配置、证书和恢复脚本；不要将它们作为诊断附件公开。
组件版本和摘要固定于主脚本，不依赖远端可变摘要，但这不构成独立签名验证。
`rollback.sh` 会恢复旧凭据及节点状态，已经撤销的凭据可能随快照恢复；回退后应核对用户列表。

如果私钥或完整导入链接已经泄露，请运行：

```bash
v2ray rotate
```

随后重新分发新链接。
