# 双栖 TwinSpace · macOS 测试版

双栖（TwinSpace）是一款 SwiftUI 开发的 macOS 应用双开工具，支持应用选择、独立副本管理、角标区分、一键启动与副本修复，让同一个应用拥有两个使用空间。

每个应用保留一个副本，可在列表中切换。副本文件图标右下角带蓝色 **2** 角标，名称包含“副本”。通用验证范围见 [VALIDATION.md](VALIDATION.md)。

> TwinSpace is a native macOS app duplicator built with SwiftUI, featuring app selection, separate instances, numbered icon badges, one-click launch, and clone repair.

## 下载

从 [Releases](https://github.com/xy-xxy/twinspace/releases) 获取 **v0.4.1 测试版**。

- **TwinSpace-0.4.1-macos-universal.zip**：macOS 安装包，包含双栖.app、使用说明和验证记录。
- **TwinSpace-0.4.1-source.zip**：源码与构建脚本。
- **SHA256SUMS.txt**：下载文件的 SHA-256 校验值。

最低 macOS 13；安装包同时包含 Apple Silicon 与 Intel 架构。本机运行测试在 Apple Silicon / macOS 27.0.1 完成，Intel 真机尚未验证。应用采用本地签名，未进行 Apple 公证。

本版改进原版完整性错误提示、自动适配和直接删除副本功能。完整历史见 [更新日志](CHANGELOG.md)。

## 安装与使用

1. 从 Releases 下载 `TwinSpace-0.4.1-macos-universal.zip` 并解压，将“双栖.app”拖到“应用程序”。从源码构建的程序位于 `dist/双栖.app`。
2. 这是 **ad-hoc 本地签名、未经 Apple 公证的测试版**。从网络获取时，系统可能阻止首次打开。确认来源后，按 macOS 提示在“系统设置 → 隐私与安全性”中选择“仍要打开”。无需关闭 Gatekeeper 或 SIP。
3. 点击“添加应用…”选择需要双开的 `.app`，支持多选。选择同一 Bundle ID 的新路径会更新原有列表项。
4. 点击“创建并打开副本”并选择复制方式。默认“仅复制应用程序”，已有副本数据保留，首次使用为空白空间。程序本身需要应用大小加约 512 MB 余量；复制数据还需要原版数据快照和已有副本备份的额外空间。
5. 在副本中按应用要求登录另一个账号。工具观察启动 20 秒，通过后仍显示“双账号登录待验证”；它不读取账号、消息或登录凭据。
6. 原版更新后点击“重建副本…”，选“仅复制应用程序”可更新程序并保留现有数据。重建会启动副本，身份和数据位置保持不变。

每个应用最多管理一个副本。重复打开会激活已有副本窗口。取消构建会清理本次临时文件；取消启动观察不会关闭已打开的客户端。

## 复制现有数据

在首次创建或“重建副本…”里选择“复制应用及现有数据”。开始前必须从菜单完全退出原版、副本及相关后台任务；窗口关闭但进程还在后台时不能复制。完成后两份本机配置和记录分别保存，修改副本文件不会写回原版本机数据。

可使用自动识别的数据位置，也可在界面提供目录选择时指定原版实际使用的目录。复制只针对本机资料，不会克隆外部服务、外部文件或云端内容。系统钥匙串不在复制范围内；保存的密码、授权信息和登录状态可能需要重新验证。

若系统拒绝访问原版资料，操作会报错并保留已有副本。开始前请确认原版与副本已完全退出，并为数据快照和备份预留足够磁盘空间。

成功替换前的旧数据与旧程序保存在 `~/Library/Application Support/AppDual/DataBackups/<备份编号>/`。点击“数据备份”可在访达中查看，`manifest.json` 记录每个 `old-N` 快照与原目标路径的对应关系。手动恢复时先退出副本，再按清单恢复；不要改动原版的数据目录。备份可能包含个人信息和凭据，目录仅对当前用户开放。

复制采用先快照、再提交的方式。如果中途退出，双栖会在下一次打开或重建副本前恢复原有状态；恢复也会保留当时发现的数据。通过访达绕过双栖直接打开副本时无法执行该恢复检查，因此中断后应先回到双栖处理。

## 原版完整性校验未通过

如果出现“应用文件与签名记录不一致”，表示 macOS 检测到应用包内资源相对其签名记录发生了新增、变更或缺失。提示列出具体路径；详细系统输出可以通过“复制诊断”获取。这一阶段尚未复制程序。

请从原安装渠道（例如 Mac App Store 或开发者官网）重新安装签名完整的应用程序，再在双栖中重试。账号数据无需删除；不要手工删除提示中的库文件来尝试修复，它们可能被其他组件引用。重新安装只解决原版完整性问题，副本实际运行与功能仍需验证。

## 兼容范围

- 工具最低支持 macOS 13，提供 arm64 + x86_64 Universal 二进制。Intel 真机与较旧 macOS 尚需实测。
- 根据应用的运行和存储机制选择隔离方式。原始签名须完整，应用资源不得链接到程序包以外。
- 并非任意 `.app` 都能双开。自定义存储位置、单实例限制、固定本地端口、原厂签名依赖和受限权限可能影响兼容性。
- 创建后检查实际启动位置与进程状态；适用时检查独立数据目录。窗口出现、进程存活或目录存在，不代表账号登录及全部业务功能已验证。
- 副本采用本地签名。系统钥匙串、分享扩展、通知、音视频、自动更新等功能可能需要单独验证。请更新原版后再重建副本。
- 运行已打包的双栖无需安装开发工具。未采用二进制补丁、插件注入、共享原版资源链接或关闭系统安全设置；安装包不附带第三方客户端。

## 文件位置与卸载

| 内容 | 位置 |
| --- | --- |
| 应用副本 | `~/Applications/` 中名称带“副本”的应用程序 |
| 应用列表 | `~/Library/Application Support/AppDual/apps.json` |
| 独立资料与缓存 | 由应用隔离方式决定，使用稳定的副本标识区分 |
| 数据备份 | `~/Library/Application Support/AppDual/DataBackups/` |
| 独立临时目录 | `~/.twinspace-tmp/` 下的对应副本目录 |

点击“删除副本并移除”会直接删除该条目对应的副本程序，不进入废纸篓；原版、账号数据与备份都保留。重新添加同一原版并选择“仅复制应用程序”，会重建相同身份的副本并沿用数据。手动卸载时退出工具及副本，再删除相应 `.app` 即可；**不会自动删除聊天记录或其他账号数据**。数据和备份可在确认不再需要后自行清理。

构建使用同一磁盘上的临时目录，签名与权限校验完成后原子交换应用包。失败时保留旧副本；异常退出可能留下 `~/Applications/.appdual-stage-*` 临时目录，其中仅有应用构建文件，确认无构建任务后可删除这些临时目录。

## 反馈问题

请到 [Issues](https://github.com/xy-xxy/twinspace/issues) 描述复现步骤，并附上双栖中“复制诊断”的内容。诊断前请检查是否包含不希望公开的路径或其他信息；不要上传账号凭据、聊天记录或数据库文件。

## 从源码构建

需要 macOS、Swift 5.9 或更新的 Apple Command Line Tools / Xcode；运行已打包应用无需安装这些开发工具，无第三方包依赖。

```sh
./scripts/test.sh          # 自动化检查，可在没有 XCTest 的 Command Line Tools 中运行
./scripts/build.sh         # 构建、合并双架构、生成图标、本地签名及 ZIP
open dist/双栖.app
```

输出包括 `.app`、安装 ZIP、源码 ZIP、SHA256 摘要及使用说明。构建脚本不读取开发者账号或执行公证。

诊断 CLI 与界面共用构建引擎：

```sh
swift run DualProbe inspect /Applications/Example.app
swift run DualProbe check-source /Applications/Example.app  # 只读完整性检查
swift run DualProbe build /Applications/Example.app
swift run DualProbe verify /Applications/Example.app
# 先自行打开原版与副本，再观察并存 90 秒；不登录、不结束客户端
swift run DualProbe observe /Applications/Example.app "$HOME/Applications/Example副本.app" 90
```

## 自动发布

推送 `vX.Y.Z` 版本标签后，[Release 工作流](https://github.com/xy-xxy/twinspace/actions/workflows/release.yml) 会自动测试、打包、校验并发布到 Releases。标签必须与 `Resources/Info.plist` 的应用版本一致；`0.x` 及带预发布后缀的版本会标记为测试版。

手动运行该工作流只验证打包流程，不发布。版本更新、标签格式、发布说明和失败重试见 [发布指南](docs/RELEASING.md)。Git 提交信息使用英文。

## 设计参考

应用组机制参考 [Apple 官方文档](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups)。签名处理参考 [Apple Code Signing Tasks](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html) 与 [代码签名错误说明](https://developer.apple.com/documentation/security/errseccsbadresource)。原版校验使用系统 `codesign --verify --deep --strict --verbose=2`。
