# 发布与更新维护

## 发布端点

仓库：`https://github.com/Jackzhang144/ResetCardBar`。

更新 feed：`https://github.com/Jackzhang144/ResetCardBar/releases/latest/download/appcast.xml`。

每个 Release 包含通用 `.zip`、带 Applications 链接的 `.dmg`、`appcast.xml` 和 `SHA256SUMS`。更新 feed 指向具体版本的 ZIP，不依赖 GitHub Actions artifact。

## 发布步骤

1. 修改 `resources/Info.plist` 中的显示版本及递增构建号，更新 `CHANGELOG.md` 和 `release-notes.md`。
2. `RESETCARDBAR_ARCH=universal RESETCARDBAR_BUNDLE_CODEX=1 make test`；检查 `git diff --check`。
3. 提交并推送 `main`，确认 CI 在 Apple Silicon 和 Intel 上通过。
4. 在用户要求发布的前提下创建匹配显示版本的标签，例如 `v1.5.0`，再推送标签。
5. Release workflow 再次验证两种架构，构建通用包，生成并校验更新签名。全部文件先上传草稿，最后公开。查看 Actions 与 Release 实际状态。

已公开版本不覆盖。草稿发布中断可重新运行 workflow；已发布后修复必须递增版本并创建新标签。不要倒退 CFBundleVersion。

## 密钥

本机的 Sparkle EdDSA 私钥存于登录钥匙串，account 为 `ResetCardBar`。Actions 中是 `SPARKLE_PRIVATE_KEY` secret。公钥在 Info.plist，必须与私钥配对。不可将私钥打印、提交或打包进应用。

`generate_keys --account ResetCardBar` 可查询公钥。需要备份时用工具导出到仓库之外的受限文件，安全备份完成后移除临时副本。私钥丢失可能导致既有安装无法验证后续更新，尤其是目前未使用 Developer ID 的版本。

## 依赖与许可

Sparkle 2.10.0 的版本和摘要固定在 `scripts/fetch-sparkle.sh`。Codex App Server 0.160.0 的两种架构包与摘要固定在 `resources/codex-runtime.json`。后端包保留官方 helper 布局，放入 `Contents/Resources/Codex/<arch>/`，避免把 JSON 和脚本目录误当成嵌套代码 bundle。

依赖升级需重新验证 App Server 握手、只读卡片查询、登录响应及更新流程。构建不得从未校验的 URL 执行下载脚本。

## 更新客户端

使用 Sparkle 官方安装器，默认每小时检查并下载安装。下载包先验证 EdDSA 签名再解压；后台下载完成后，通过 `willInstallUpdateOnQuit` 的安装回调执行安装及重启。

重启前等待本轮 RPC 完成，并避开自动使用卡片的最后两分钟。使用记录继续由 Monitor 写盘；更新不清空偏好或记录。失败回调恢复监控。每个新版本应以受控旧版本验证签名、下载、安装与重启，不以用户真实卡片消费作为更新测试。

## 当前分发限制

目前没有 Developer ID 证书，也未公证。首次安装按 macOS 的「仍要打开」提示由用户允许；不能关闭 Gatekeeper 或替用户绕过安全警告。更新可能需要安装位置的写权限或管理员授权。

将来接入 Developer ID 与 notarization 时，还需正确签署 Sparkle helper 和内置运行组件，再公证最终安装包；EdDSA 更新签名仍需保留。
