# 开发指南

## 环境

运行 `xcrun --find swift`、`python3 --version`、`codex --version` 确认工具可用。UI 与系统能力要求 macOS；测试不能在 Linux 上直接执行。

构建使用 Swift 5 语言模式，deployment target 为 macOS 13，默认本机架构。可用 `RESETCARDBAR_ARCH=arm64 make build` 指定架构；构建其他架构并不证明该架构已经运行验证。

完整 Xcode 的 `actool` 用于图标资源目录编译；否则使用 `.icns`。Sparkle 2.10.0 下载后验证固定 SHA-256，框架保留官方签名并嵌入应用。项目当前没有 Swift Package 或 `.xcodeproj`，避免同时引入多个未维护的构建入口。

## 修改与测试

```sh
make test
git diff --check
```

`make test` 包含卡片边界测试、模拟监控测试和 JSONL 子进程测试。RPC 夹具只返回合成账号/卡片数据，覆盖分段输出、异步通知、输出关闭与 12 秒超时。不得让夹具连接真实消费接口。

`--check-account` 是只读入口；`--health-check` 读取系统通知状态。测试输出中的模拟断言数随用例变化，不应将数字写死为实现契约。

## UI 与真实截图

先退出其他运行副本，再执行 `make preview`。预览沿用真实账号、当前自动使用开关和到期时间；它不是纯模拟演示。后台监控继续运行，截图后退出预览并恢复常用安装版。

使用 Codex Computer Use 读取真实应用窗口并采集像素，保存到 `docs/screenshots/`。`dashboard.jpg` 和 `settings.jpg` 当前均为 2026-10-05 实际窗口截图。预览窗口复用 `Dashboard`，但不把窗口截图描述成菜单栏弹出效果。

检查两张卡、自动使用选项、页脚完整显示且不需要上下滚动。设置进入独立页面；卡片超过两张时分页，后台处理不受分页限制。

截图不得包含账号标识、卡片完整 ID、认证信息或其他应用内容。图标原图是生成资产，必须与真实截图明确区分。

## 运行记录

真实记录存放在 Application Support。模拟测试使用独立临时目录，不覆盖用户记录。修改 Codable 结构时考虑已有记录的解码和迁移；损坏或不兼容记录不能静默丢弃。

## 打包和安装

`make package` 先运行测试，再生成 `dist/ResetCardBar-<version>-<arch>.zip`。脚本仅打包，不安装、不修改登录项、不注册全局 skill、不上传远端。

需要更新安装版时，先从菜单正常退出旧版，再用 `ditto build/ResetCardBar.app /Applications/ResetCardBar.app` 覆盖，最后 `open /Applications/ResetCardBar.app`。保留 Bundle ID 和用户记录，检查 `--health-check` 及系统中的待提醒数量。不要在测试中顺带消费真实卡片。

版本号统一维护在 `resources/Info.plist`，行为变化记录到 `CHANGELOG.md`。当前应用使用本地临时签名，没有 Developer ID 公证；不要将 ZIP 描述成已公证的通用安装包。

## Codex skill

仓库自带 `.agents/skills/reset-card-bar-dev`，在仓库范围内发现，不需要全局安装。显式调用示例：

```text
用 $reset-card-bar-dev 检查断网后未确认消费请求的恢复流程，并用模拟服务验证。
```

skill 定义保持简短，项目状态与构建细节以当前源码和这些文档为准，避免复制整套说明产生漂移。

## 发布与更新开发

仓库位于 `~/Code/ResetCardBar`，公开远端为 `Jackzhang144/ResetCardBar`。更新实现为 `src/Updates.swift`，浏览器登录为 `src/Login.swift`。

`RESETCARDBAR_ARCH=universal RESETCARDBAR_BUNDLE_CODEX=1 make test` 构建完整发布包。后端版本与摘要由 `resources/codex-runtime.json` 固定；只能通过核对官方发布及重新验证接口来升级。

`make package` 仍只生成本地 ZIP；`scripts/release.sh` 额外生成 DMG 和签名 appcast。向 GitHub 推送版本标签会触发真正发布，不把它当成普通测试命令。

自动更新必须保留公钥、稳定 HTTPS feed、递增 CFBundleVersion 以及重置卡操作的安全重启约束。失败回调需要恢复监控，不能留下暂停状态。更新流程见 [RELEASING.md](docs/RELEASING.md)。
