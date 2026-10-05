# ResetCardBar 开发约定

这是原生 macOS 菜单栏应用。只维护 Codex 所需的 `AGENTS.md` 和 `.agents/skills`，不添加其他 agent 平台的配置。

## 入口和验证

- `src/main.swift`：AppKit/SwiftUI 界面、JSONL RPC、通知、网络与睡眠调度、实例锁及调试入口。
- `src/Monitor.swift`：账号隔离、卡片缓存、幂等使用记录与恢复逻辑。
- `tests/MonitorTests.swift`、`tests/test_rpc.py`：模拟服务及真实子进程夹具。
- `resources/Info.plist`：版本号、Bundle ID、系统图标和更新公钥/feed。
- `src/Updates.swift`：Sparkle 验证与安全安装重启；`src/Login.swift`：浏览器登录。
- `make test` 是逻辑/脚本变更后的验证入口。纯文档改动检查链接与路径即可。
- 界面改动用实际运行窗口验证，保留无需上下滚动的主面板。不要把生成图或设计稿称为截图。
- 构建产物写入 `build/`，发布包写入 `dist/`。不会自动安装到 `/Applications` 或发布到远端。

## 必须保持的行为

- 发送消费请求前，原子写入并同步幂等标识；存储失败时不发送请求。
- 不确定结果必须复用原标识，包括重启、卡片消失或到期后确认。未知结果不代表成功。
- 成功记录和待通知事件持久化；成功后读取额度失败也不能再次消费同一张卡。
- 同一轮成功消费后停止，下一轮使用新额度信息；单卡失败不能阻断其他卡。
- 账号标识缺失、切换或记录损坏时保守处理，不能静默清空记录重新消费。
- 卡片明细可能为空或被截断；数量与明细条数不是同一个概念。
- 通知请求成功提交后才标记已提醒；安排提醒时检查系统任务，不能只看本地标志。
- 普通测试使用模拟服务，不消费真实卡片。启动 `--preview` 会沿用真实账号及当前自动使用设置。
- 保持单实例锁。不要把“登录启动”描述成崩溃后自动恢复。
- 不提交真实账号响应、运行记录、认证数据、环境变量内容或构建日志。

当前默认提前 60 分钟，是用户明确选择。更改默认、提醒阶段或检查频率时更新测试和文档。图标的通知显示问题已被用户明确停止，不在无关任务中继续排查。

## 文档与 skill

阅读 [DEVELOPMENT.md](DEVELOPMENT.md) 了解构建、截图及打包流程。修改消费、提醒或恢复逻辑时参照 [docs/RELIABILITY.md](docs/RELIABILITY.md)。仓库开发 skill 是 `.agents/skills/reset-card-bar-dev/SKILL.md`，只在本项目工作时使用。

Git 提交前检查 `git diff --check`、暂存文件列表与 `.gitignore`。不得因为测试便利而删除用户 Application Support 中的真实记录。

## 发布约束

仓库已接入 GitHub Actions。推送 `v*` 标签会发布公共软件，仅在用户要求发布时执行；普通构建不自动推标签。

维护固定依赖版本和 SHA-256 摘要。不要把 Sparkle 私钥、证书、GitHub token 或登录地址写入源码/日志；发布私钥来自 Keychain 或 Actions secret。保持更新签名验证，不通过删除 quarantine 或关闭 Gatekeeper 来测试未公证包。

更新安装不能打断重置卡请求；更新失败后监控必须继续。版本号要与标签匹配，CFBundleVersion 必须递增。已公开 Release 不覆盖。参考 `docs/RELEASING.md`。
