# Saylane

macOS 输入法：打字走拼音，按住快捷键说话则在当前输入框写入译文（默认中文 → 英文）。装在 `/Library/Input Methods/`，和系统其它输入法一样切换使用。

当前版本 `0.2.48`。语音识别和翻译默认走 Apple 端侧框架；可选的终稿润色才走外部 API。

## 要求

- macOS 26+
- Apple Silicon
- Xcode 26.2+（首次构建 MLX 需 `xcodebuild -downloadComponent MetalToolchain`）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- 打安装包需要 Developer ID Application 证书（`scripts/package.sh` 会拒绝 ad-hoc 身份）

## 开发

```bash
make build          # Debug
make test           # 本地 swiftc 单测
make pkg            # Release + pkg
```

`Saylane.xcodeproj` 由 `project.yml` 生成，不要手改，也不进 git。

第一次使用需要：

1. 麦克风
2. 语音识别
3. 把 Saylane 加到系统输入法并选中
4. 若要在其它输入法下按快捷键唤起，再开输入监控

## 可选千问识别（v0.2.47）

设置 → 本地模型新增 Qwen3-ASR 0.6B 的 **4-bit（约 724 MB）** 和 **6-bit（约 873 MB）**。
默认仍用 Apple；用户主动下载后再点“使用”，可取消、重试、修复和删除。
权重不进 `.app` / PKG，分别存储在用户 Application Support 目录。打包脚本会检查并拒绝包含模型权重的应用。

首版松开后出最终文字，每次最多 30 秒。快捷键、翻译和可选润色复用原有流程。
千问运行在独立进程中；切回 Apple 会退出并释放模型内存，4/6-bit 互切先释放旧模型。下载文件仍保留在磁盘。
技术细节、固定来源及验证边界见 [docs/QWEN_ASR.md](docs/QWEN_ASR.md)。v0.2.47 提供以上可选模型；千问当前为松开后识别，不支持边说边组字。

## 安装

从 [GitHub Release 下载 v0.2.48 安装包](https://github.com/LiuTianjie/Saylane/releases/tag/v0.2.48)，或访问 [产品网页](https://liutianjie.github.io/Saylane/)。Release 同时提供 SHA-256 校验文件。

注意：包内应用已签名，当前 PKG 安装器未签名、未完成 Apple 公证。

见 [docs/安装说明.md](docs/安装说明.md)。构建产物在 `dist/`，不进仓库。

## 仓库结构

```
Sources/          输入法宿主、拼音、语音、设置
Tests/            可脱离 Xcode 跑的单测
Vendor/           固定版本的 Swift ASR 运行源码（无模型权重）
scripts/          打包、词库、图标、卸载
scripts/data/     拼音词库源数据
docs/             架构、安装、语音输入契约
project.yml       XcodeGen 工程定义
```

更完整的设计说明见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。语音输入流程契约见 [docs/VOICE_INPUT_V2.md](docs/VOICE_INPUT_V2.md)。

## Saylane 品牌改名与兼容性

产品显示名、源码入口、Xcode scheme、可执行文件与后续安装包统一为 Saylane。运行 `make build` / `make pkg` 会生成 `Saylane.xcodeproj`、`Saylane.app` 与 `Saylane-<version>.pkg`。

以下旧标识刻意保留，不属于遗漏：
- `com.rtranslate.*` 的 Bundle ID、输入源 ID、Keychain service、偏好迁移域和安装器 receipt ID：保持应用身份连续性；本次不迁移用户凭据和系统授权。
- `~/Library/Application Support/RTranslate`：继续使用已有模型、词频和诊断目录，避免重新下载或丢失用户数据。
- 安装/卸载脚本兼容旧 `RTranslate.app` 路径，核验 Bundle ID 后才清理；同时支持 `Saylane.app`。
- 签名环境变量首选 `SAYLANE_SIGNING_IDENTITY`，兼容旧 `RTRANSLATE_SIGNING_IDENTITY`。
- GitHub 仓库及 Pages 地址仍沿用原路径；已发布 v0.2.47 的文件名和下载地址不变，该历史安装包仍显示旧品牌。Saylane 新版安装包从 v0.2.48 开始发布。

现有系统安装不会自动改名。新版安装器的升级、系统输入法名称和权限连续性仍须实际安装后验收。
