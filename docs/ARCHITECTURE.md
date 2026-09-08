> 当前已落地为系统输入法（拼音打字 + 按住说话翻译），安装到 `/Library/Input Methods/`。
> 下文是 v1 设计底稿，菜单栏宿主的表述以现实现状为准。语音流程契约见 `docs/VOICE_INPUT_V2.md`。

# RTranslate 技术架构（v1）

RTranslate 是一个 macOS 菜单栏应用：按住全局快捷键说话，把语音识别结果按选定语言对翻译后，**实时写入当前焦点输入框**。产品形态接近 TypeLess，差异在「源语言 / 目标语言」和「边说边往输入框里写译文」。

当前仓库从空项目起步。v1 只打通核心闭环，不做口水话 AI 润色。

## 1. 目标与非目标

### 目标

- 原生 SwiftUI 菜单栏应用，无 Dock 图标（`LSUIElement`）。
- 按住全局快捷键说话，松开结束。默认右 Option，可在设置里改成左右修饰键或 F8 / F13 等功能键。
- 可选源语言 / 目标语言，默认 **简体中文 → English**。
- 悬浮 HUD 同时显示原文和译文。
- 译文通过合成键盘事件写入当前焦点输入框，边说边改。
- 语音识别和翻译都走 Apple 端侧框架，音频不上传。

### 非目标（v1 不做）

- 中文口水话 / 口头禅的大模型润色。
- Electron / Tauri / 网页壳。
- 沙盒、公证、App Store 分发。
- 历史记录、词库、自定义快捷键编辑器。
- 开机启动（`SMAppService` 可后续加）。

## 2. 为什么这样设计

### 2.1 原生，不套壳

全局热键、麦克风 tap、辅助功能注入、输入法切换都是系统级能力。Swift/AppKit 是最短路径。跨平台壳会把「写入别人家输入框」做成最脆弱的一层。

### 2.2 端侧 Speech + Translation

- 识别：`SpeechAnalyzer` + `SpeechTranscriber`（macOS 26）。流式输出 `isFinal` 与 volatile 中间结果。
- 翻译：`Translation` 框架。已安装模型时用 `TranslationSession(installedSource:target:)`；未安装时用隐藏窗口上的 SwiftUI `.translationTask` 触发系统下载。
- 音频：`AVAudioEngine.inputNode.installTap`，再用 `AVAudioConverter` 转成分析器要求的 PCM。macOS 26 没有 `CaptureInputSequenceProvider`（那是 27+），不能走系统封装的采集序列。

### 2.3 全文翻译，而不是按词增量翻译

中文和英文不是词对齐的。例如：

- 中文多一个「的」，英文语序可能整句重排。
- 「我想…」后半句出来后，前半句译文也可能改。

因此 v1 的翻译输入永远是 **当前完整原文**（已定稿片段 + 当前 volatile 片段），而不是新词增量。译文更新后，用 **字素公共前缀 + 退格 + 补打** 去改已经打进输入框的英文。

代价：翻译器会反复翻译越来越长的句子。这是正确性优先。后续可以改成句级稳定窗口，或把润色模型接到定稿句上。

### 2.4 热键必须能吞掉右 Option

右 Option 是修饰键，不是普通按键。只听 `keyDown` 会漏。必须听 `flagsChanged`，并用设备标志区分左右：

- `NX_DEVICELALTKEYMASK = 0x00000020`
- `NX_DEVICERALTKEYMASK = 0x00000040`

按住说话期间如果把 Option 放给前台应用，会出现 Option+字母快捷键、Option+Delete 删词等副作用。所以 PTT 期间用 `CGEvent` tap **吞掉** 右 Option。Escape 在会话中同样吞掉，避免取消听写时顺手关掉别人的弹窗。

## 3. 核心闭环

```
按住右 Option
    │
    ├─ 记录当前前台应用 / 焦点
    ├─ 切到 ABC 输入法（避免中文 IME 吞 Unicode）
    ├─ 立刻开麦（先缓冲，避免第一句话被切掉）
    ├─ 准备 / 下载语音模型、翻译模型
    │
    ▼
listening
    │  PCM → SpeechAnalyzer
    │  原文 = finalized + volatile
    │  HUD 立刻显示原文
    │  对完整原文 debounce 180ms 后翻译
    │  HUD 显示译文
    │  若开启「实时写入」：公共前缀差分写入焦点输入框
    │
松开右 Option
    │
    ▼
finalizing
    │  结束音频流，flush 识别
    │  再翻译一次最终原文
    │  最后一次差分写入
    │
    ▼
idle（恢复输入法，收起 HUD）

Escape → cancelling：停止识别，按已写入长度退格删掉译文
```

状态机：`idle → preparing → listening → finalizing → idle`。取消走 `cancelling`。出错把原因写到 HUD 和菜单。

## 4. 模块与文件

```
Sources/
  RTranslateApp.swift          菜单栏入口、accessory 策略
  AppModel.swift               设置、权限、语言对、会话编排
  Info.plist / entitlements
  Models/
    AppLanguage.swift          语言、locale 映射
    SessionState.swift         会话状态
  Services/
    PermissionService.swift    麦克风 / 语音识别 / 辅助功能 / 输入监控
    HotkeyMonitor.swift        右 Option 按住说话 + Escape
    AudioCaptureService.swift  AVAudioEngine tap
    AudioBufferRelay.swift     分析器未就绪时的约 2s 缓冲
    BufferConverter.swift      麦克风格式 → 分析器格式
    SpeechEngine.swift         SpeechAnalyzer 流式识别
    TranslationEngine.swift    TranslationSession
    TextInjector.swift         Unicode 输入 + 退格差分
    OverlayController.swift    非激活 HUD 面板
    InputSourceSwitcher.swift  临时切 ABC
  Views/
    MenuBarView.swift
    OverlayView.swift
    SettingsView.swift
    TranslationHostView.swift  给翻译模型下载用的隐藏宿主
```

`AppModel` 在主线程编排。音频 tap 不跳主线程：转换 PCM 后 `yield AnalyzerInput`。识别结果、翻译、注入再回到主线程。

## 5. 实时写入策略

1. 记录当前已写入字符串 `inserted`。
2. 新译文 `next` 到来时，按 Swift `Character`（字素簇）算公共前缀，避免 UTF-16 切到代理对。
3. 对前缀之后的旧字符发退格（虚拟键 51），再对前缀之后的新字符发 Unicode `CGEvent`。
4. 会话结束时只做最后一次差分，不再整段剪贴板粘贴。剪贴板只作为辅助功能不可用时的兜底。
5. 注入使用 `CGEventSource(stateID: .privateState)`，flags 置空，避免物理上还按着的 Option 污染退格。
6. 源语言等于目标语言时跳过翻译，相当于普通听写。

## 6. 音频与识别时序

1. 权限已就绪时，按键当下就 `engine.start()`，tap 写入 `AudioBufferRelay`。
2. `SpeechTranscriber` 解析 locale：优先 `supportedLocale(equivalentTo:)`，否则按语言码兜底。`zh-Hans` → 识别 `zh-CN`，翻译仍用 `zh-Hans`。
3. 如模型未安装：`AssetInventory.assetInstallationRequest(supporting:)` + `downloadAndInstall()`。HUD 显示「正在下载离线模型」。
4. `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` 得到目标格式，转换后喂 `AnalyzerInput(buffer:)`。
5. 分析器就绪后 flush 缓冲。缓冲上限约 2 秒，避免首次下载模型时无限堆积。
6. `SpeechAnalyzer` 是 actor。每次会话递增 generation，丢弃过期结果。
7. 设备热插拔时重建 `AVAudioEngine`。复用旧 engine 会把上一台设备的格式留给 `installTap`，在 ObjC 异常里崩掉。

## 7. 翻译会话

- 启动或切换语言对时查 `LanguageAvailability.status(from:to:)`。
- `.installed`：直接 `TranslationSession(installedSource:target:)`，再 `prepareTranslation()`。
- `.supported`：打开 `TranslationHostView` 的 `.translationTask`，让系统弹出下载。
- `.unsupported`：HUD 报「系统不支持该语言对」。
- volatile 原文 180ms debounce；松开时取消 debounce，立刻译最终稿。
- 翻译 generation 与识别 generation 分开，避免慢请求覆盖新句子。

## 8. 热键、权限与签名

| 能力 | 权限 | 失败表现 |
| --- | --- | --- |
| 麦克风 tap | 麦克风 | 无法听写 |
| SpeechAnalyzer | 语音识别 | 无法出字 |
| 吞快捷键 | 输入监控（session tap）或辅助功能（HID tap） | Option 泄漏到前台应用 |
| 写入输入框 | 辅助功能 | HUD 仍可用，无法注入 |

Info.plist 声明麦克风和语音识别用途。应用 **不沙盒**，本地 ad-hoc 签名（`CODE_SIGN_IDENTITY="-"`）。每次重签后 TCC 可能把辅助功能勾选显示为已开、实际 `AXIsProcessTrusted()` 仍为 false，设置里提供「重新授权」。

快捷键可在设置里更换。按住说话，会话期间吞掉该按键，避免泄漏到前台应用。

## 9. HUD

非激活 `NSPanel`，底部居中，不抢焦点。内容：

- 语言芯片：`简体中文 → English`
- 波形
- 原文（弱）
- 译文（主）
- 提示：`松开右 Option 完成 · Esc 取消`

即使关闭「实时写入」或没有辅助功能，HUD 仍然更新。

## 10. 后续：口水话润色

中文口述常有「那个 / 就是 / 然后 / 呃」。端侧 Translation 会尽量忠实，所以英文也会啰嗦。下一步应加在 **最终定稿之后、写入之前**（或对已稳定的句子窗口）：

```
识别原文 →（可选）LLM 去口水话并转写目标语 → 差分写入
```

实时阶段仍用系统翻译保低延迟；松开后再跑一次润色并修正输入框。v1 不接网络模型，避免把首版核心闭环和 API Key / 隐私问题绑在一起。

## 11. 构建

本机 macOS 26 + Xcode 26。`xcodegen generate` 后 Debug 编译。验证以 `xcodebuild` 是否成功为准；权限授权和真机听写是下一层证据，不能用编译成功代替。
