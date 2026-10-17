# 版本发布

推送版本标签到 `xy-xxy/twinspace` 后，[Release 工作流](https://github.com/xy-xxy/twinspace/actions/workflows/release.yml) 自动完成：

1. 校验标签与应用版本一致。
2. 运行发布脚本测试和核心功能测试。
3. 在 macOS 构建 arm64 + x86_64 Universal 应用，进行本地签名与校验。
4. 生成 DMG、ZIP 安装包、源码包、英文 README、验证记录及 SHA-256 清单。DMG 在 macOS 构建阶段只读挂载，校验应用版本、签名、双架构及 Applications 快捷入口后才替换产物。
5. 在 GitHub 创建草稿，上传并校验全部附件，再公开发布。

使用仓库自带的 `GITHUB_TOKEN`，无需配置个人访问令牌、Apple 开发者证书或公证密钥。仅发布步骤申请 `contents: write`；测试与构建使用只读权限。

## 准备新版本

以 `0.4.2` 为例：

- 修改 `Resources/Info.plist` 中的 `CFBundleShortVersionString` 为 `0.4.2`，递增 `CFBundleVersion`。界面、诊断和打包脚本从该文件获取版本号。
- 更新 `CHANGELOG.md`、README 的下载版本和 `VALIDATION.md`，只记录实际通过的验证。
- 使用英文编写 `docs/releases/v0.4.2.md`，与英文 README 保持一致。有该文件时作为 Release 正文；没有时自动生成安装、下载、验证范围与更新日志链接。
- 提交信息使用英文，先推送代码，再推送标签：

```sh
git add Resources/Info.plist CHANGELOG.md README.md VALIDATION.md docs/releases
git commit -m "Prepare release 0.4.2"
git push origin main
git tag -a v0.4.2 -m "Release v0.4.2"
git push origin v0.4.2
```

标签必须是 `vX.Y.Z`，或 `vX.Y.Z-alpha.N`、`vX.Y.Z-beta.N`、`vX.Y.Z-rc.N`（N 从 1 开始）。例如 `v0.4.2-beta.1` 对应应用版本仍为 `0.4.2`。

`0.x` 版本及带 alpha / beta / rc 后缀的标签发布为 Pre-release。`1.0.0` 起不带后缀的标签发布为正式版本。标签版本与应用不一致时会停止，不会发布名称与内容不符的安装包。

预发布说明优先使用同名文件，例如 `docs/releases/v0.4.2-beta.1.md`；否则使用 `docs/releases/v0.4.2.md`，再否则使用默认英文正文。Release 标题统一使用 TwinSpace。

## 附件与验证

从当前打包版本起，每次 Release 包含 6 个附件：

- `TwinSpace-X.Y.Z-macos-universal.dmg`
- `TwinSpace-X.Y.Z-macos-universal.zip`
- `TwinSpace-X.Y.Z-source.zip`
- `README.md`
- `VALIDATION.zh-CN.md`
- `SHA256SUMS.txt`

SHA-256 清单覆盖 DMG、两个 ZIP 和两个说明文件。公开前检查所有本地校验值、安装包身份与版本、GitHub 上的附件大小及 SHA-256，以及远端标签是否仍指向构建时的提交。源码包排除构建目录、应用数据和 Python 缓存。

当前仍是本地签名，没有 Apple 公证；自动构建成功不代表双账号登录或各应用全部业务功能通过。实际范围以 `VALIDATION.md` 为准。

## 验证流程而不发布

在 GitHub Actions 中打开 **Release → Run workflow**，选择 `main`；也可以运行：

```sh
gh workflow run release.yml --repo xy-xxy/twinspace --ref main
```

手动运行会测试、构建、校验并上传 Actions artifact，**不会创建或修改 GitHub Release**。适合调整发布流程后验证，也不会覆盖现有 v0.4.1。

本地检查发布逻辑：

```sh
python3 -m unittest discover -s Tests/ReleaseTests -v
python3 scripts/release.py prepare --tag v0.4.2
./scripts/build.sh
python3 scripts/release.py verify
```

将示例标签替换为 `Info.plist` 对应的版本。`publish` 命令只接受目标仓库的标签推送事件，手动本地调用会停止。

## 失败与重试

- 构建或测试失败：修复后使用新的版本标签，不要移动已发布标签。
- 上传中断：Release 保持草稿，可在 Actions 中重新运行失败的任务，继续上传和验证。
- 同一提交的自动 Release 已发布：重跑不会覆盖既有附件；重新构建的 ZIP 时间戳可能不同，公开版本仍保留原文件。
- 已存在手动创建的 Release、来源提交不同、标签已移动或校验不通过：停止并报告原因，不强制覆盖。
- 手动编辑或公开进行中的草稿可能导致工作流停止；让工作流完成上传和公开即可。
