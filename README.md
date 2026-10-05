# ResetCardBar · Codex 重置卡助手

一个轻量的 macOS 菜单栏应用，用于查看 Codex 重置卡的到期时间、提前提醒，并在临近到期时自动尝试使用。使用本机 Codex CLI 登录的 ChatGPT 账号，无需填写 API Key。

## 实际截图

以下截图于 2026-10-05 在 macOS 的真实运行窗口中采集。预览窗口与菜单栏弹出面板复用同一个 SwiftUI 界面；显示的数量和到期日期来自实际账号，未使用设计稿或生成图代替截图。

| 主面板 | 设置页 |
| --- | --- |
| <img src="docs/screenshots/dashboard.jpg" width="340" alt="实际运行的重置卡面板，显示两张卡和提前60分钟自动使用设置"> | <img src="docs/screenshots/settings.jpg" width="340" alt="实际运行的独立设置页，显示登录启动和通知测试功能"> |

## 功能

- 菜单栏显示可用卡片数量，圆角卡片展示剩余时间和到期日期。
- 每页显示两张卡；后台处理全部已知卡片，主面板无需上下滚动。
- 自动使用提前时间可选 10、30、60 分钟，当前默认 60 分钟。
- 到期前 24 小时、1 小时、10 分钟、2 分钟分别提醒。
- 常态每 60 秒检查，最后 1 小时每 15 秒，最后 2 分钟或有待确认请求时每 5 秒。
- 原子保存使用记录；网络响应丢失后复用幂等标识确认结果。
- 网络恢复和系统唤醒后补查，临近到期时阻止空闲睡眠。
- 支持登录启动、通知测试，以及通知权限异常提示。

## 构建与运行

需要 macOS 13+、Xcode Command Line Tools、Python 3 和 `make`。可选安装完整 Xcode，以编译 `Assets.car`；没有完整 Xcode 时使用 `.icns` 图标。

```sh
make build
make test
```

应用生成在 `build/ResetCardBar.app`，默认构建本机架构，使用本地临时签名。开发入口是命令行构建，仓库没有 Xcode 工程文件。

先使用 ChatGPT 账号登录 Codex CLI：

```sh
codex login
codex login status
```

将应用复制到 `/Applications` 后运行：

```sh
ditto build/ResetCardBar.app /Applications/ResetCardBar.app
open /Applications/ResetCardBar.app
```

替换安装版前，从菜单退出正在运行的旧版本。允许通知后，在底部齿轮设置页发送测试通知，并按需开启登录启动。

默认查找 `/opt/homebrew/bin/codex`、`/usr/local/bin/codex`、`/Applications/Codex.app/Contents/Resources/codex`；也可在设置页手动选择。CLI 和桌面应用登录账号不同时，以 CLI 当前账号为准。

## 开发命令

| 命令 | 用途 |
| --- | --- |
| `make build` | 构建并检查代码签名 |
| `make test` | 运行卡片边界、模拟监控和真实进程 RPC 测试；不消费真实卡片 |
| `make run` | 启动开发构建 |
| `make preview` | 打开同一界面的预览窗口，读取真实账号并沿用当前自动使用设置 |
| `make health` | 只读检查通知授权、待提醒数量和提前时间 |
| `make package` | 测试后生成 `dist/` 下的应用 ZIP |

已运行其他副本时，实例锁会阻止开发构建启动。需要预览时先从运行版菜单退出，再执行 `make preview`。完整开发流程见 [DEVELOPMENT.md](DEVELOPMENT.md)。

## 能力边界

自动使用需要应用运行、Mac 醒着并联网。空闲睡眠保护不能阻止合盖、主动睡眠或关机。应用没有独立崩溃重启守护进程；退出或崩溃后，自动使用会暂停，已安排的系统提醒仍由 macOS 管理。

服务端返回 `nothingToReset` 时会继续尝试，但应用不能强制创建可重置额度。接口未提供到期明细时也无法保证准确安排。不能承诺卡片绝不过期。

通知中心图标曾显示默认占位图，尚未确认修复；此问题不影响卡片查询和自动使用逻辑。

## 记录与隐私

使用记录位于 `~/Library/Application Support/ResetCardBar/state.json`，偏好域为 `local.jackzhang.ResetCardBar`。记录包含账号标识、卡片标识、到期时间和未确认请求，不包含登录凭据。登录由 Codex CLI 管理。

不要删除记录文件来解决重试异常，否则会丢失未确认请求的标识。不要提交真实账号响应、记录文件、登录凭据或调试日志。

## 仓库与 Codex

```text
src/                  应用界面、RPC、调度与持久化监控
resources/            Info.plist
assets/               图标原图及生成说明
scripts/              构建、图标资源编译与打包脚本
tests/                模拟监控断言及 RPC 进程夹具
docs/                 架构、可靠性、截图和历史检查记录
.agents/skills/       仓库专用 Codex 开发 skill
build/、dist/          本地生成产物，不纳入 Git
```

Codex 入口为 [AGENTS.md](AGENTS.md)。仓库 skill 位于 [.agents/skills/reset-card-bar-dev/SKILL.md](.agents/skills/reset-card-bar-dev/SKILL.md)，在本仓库启动 Codex 后可用 `$reset-card-bar-dev` 调用，目录采用[官方 Codex skill 规范](https://learn.chatgpt.com/docs/build-skills)。

更多说明：[架构](docs/ARCHITECTURE.md) · [可靠性](docs/RELIABILITY.md) · [版本记录](CHANGELOG.md) · [官方 App Server 接口](https://learn.chatgpt.com/docs/app-server)
