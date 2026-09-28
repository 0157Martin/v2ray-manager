# Security

请勿在公开 Issue 中提交服务器 IP、UUID、REALITY 私钥、完整配置文件或未脱敏日志。

以下信息可安全用于排查：操作系统版本、`v2ray version` 输出、经过脱敏的
`v2ray status` 与 `v2ray log` 输出。REALITY 私钥只应保存在服务器的
`/etc/xray/config.json` 和 `/etc/xray/manager.env` 中。

如果私钥或完整导入链接已经泄露，请运行：

```bash
v2ray rotate
```

随后重新分发新链接。
