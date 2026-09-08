# RTranslate

macOS 输入法：打字走拼音，按住快捷键说话则在当前输入框写入译文（默认中文 → 英文）。装在 `/Library/Input Methods/`，和系统其它输入法一样切换使用。

当前版本 `0.2.45`。语音识别和翻译默认走 Apple 端侧框架；可选的终稿润色才走外部 API。

## 要求

- macOS 26+
- Apple Silicon
- Xcode 26+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- 打安装包需要 Developer ID Application 证书（`scripts/package.sh` 会拒绝 ad-hoc 身份）

## 开发

```bash
make build          # Debug
make test           # 本地 swiftc 单测
make pkg            # Release + pkg
```

`RTranslate.xcodeproj` 由 `project.yml` 生成，不要手改，也不进 git。

第一次使用需要：

1. 麦克风
2. 语音识别
3. 把 RTranslate 加到系统输入法并选中
4. 若要在其它输入法下按快捷键唤起，再开输入监控

## 安装

从 [GitHub Release 下载 v0.2.45 安装包](https://github.com/LiuTianjie/rtranslate/releases/tag/v0.2.45)，或访问 [产品网页](https://liutianjie.github.io/rtranslate/)。Release 同时提供 SHA-256 校验文件。

注意：包内应用已签名，当前 PKG 安装器未签名、未完成 Apple 公证。

见 [docs/安装说明.md](docs/安装说明.md)。构建产物在 `dist/`，不进仓库。

## 仓库结构

```
Sources/          输入法宿主、拼音、语音、设置
Tests/            可脱离 Xcode 跑的单测
scripts/          打包、词库、图标、卸载
scripts/data/     拼音词库源数据
docs/             架构、安装、语音输入契约
project.yml       XcodeGen 工程定义
```

更完整的设计说明见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。语音输入流程契约见 [docs/VOICE_INPUT_V2.md](docs/VOICE_INPUT_V2.md)。
