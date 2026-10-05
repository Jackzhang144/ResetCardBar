## ResetCardBar 1.5.0

- Apple Silicon 与 Intel 通用构建，提供 DMG 和 ZIP 下载。
- 增加手动检查更新、默认每小时自动检查、自动下载、安装并重启。
- 更新包使用 Sparkle EdDSA 签名；等待重置卡操作完成后安装，最后两分钟优先处理卡片。
- GitHub Actions 自动运行两种架构的测试，版本标签触发 Release 发布。

### 安装

下载 DMG，打开后将 ResetCardBar 拖入 Applications。需要 macOS 13+，以及已通过 ChatGPT 账号登录的 Codex CLI（`codex login`）。

此版本未经过 Apple Developer ID 签名和公证。首次打开如果被 macOS 阻止，请通过系统设置 → 隐私与安全性 → 仍要打开，按系统提示允许。不要关闭 Gatekeeper 或删除系统安全属性。

应用默认自动检查更新、安装并重启，可在设置页关闭。更新可能因安装位置权限而需要管理员授权。自动使用重置卡仍要求应用运行、Mac 醒着并联网；合盖或关机期间不会消费卡片。
