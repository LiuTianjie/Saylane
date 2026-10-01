# Saylane 体验排查与重构计划

日期：2026-09-29。基线：`main` @ `5f494cb`（v0.2.75）。

> **实施状态（2026-09-29）**：Phase 1–6 已在工作区落地（见 `CHANGELOG.md` 与 `docs/ARCHITECTURE.md`），按用户要求跳过 Phase 0（签名公证、CI、更新检查）并保留默认触发键与现有手势语义；Phase 2 第 6 条（同键点按 / 按住合一、方向切换改独立快捷键、默认 Fn）未实施。未达到的量化目标：`AppModel.swift` 604 行（目标 < 400）、回调闭包 45 个（目标 < 10）、`@unchecked Sendable` 11 处（目标 0）；其余指标见 §9 的"现状"列已刷新。

本文分三部分：先列出排查到的体验问题及其代码证据，再从技术设计、架构和工程实践三个角度归因，最后给出分阶段的重构计划和验收标准。所有行号以当前 `main` 为准。

---

## 0. 结论摘要

1. **体验问题的根源不是某个 bug，而是编排层没有边界。** `AppModel`（1039 行）同时负责偏好持久化、权限、TIS 安装、热键分发、会话编排、模型生命周期、截屏翻译接线、拼音代理、设置导航和错误上报，全局通过 `AppModel.shared` 访问。任何一处改动都会牵动其他功能，这就是 0.2.x 里"修一个坏一个"的原因。
2. **语音主链路的首要问题是"按下之后什么都没发生"。** 按键 → 180 ms 长按判定 → 切换输入源 → 轮询等待 IMK 挂载（最长 3.2 s）→ 才开始录音。用户已经开口说话，句首却被丢掉；如果目标应用不挂载 IMK，等待结束后只在设置页里留下一条错误。
3. **五套并行的手势识别器共享同一批按键。** 全局 CGEvent tap、IMK `handle`、设置窗口本地监听、右 ⌘ 双击、左 ⌃ 长按，靠 `screenActive`、`owningGesture`、`shortcutDirectActive`、`suppressWorkspaceCancel` 四个布尔量互相仲裁。这是当前最难推理、也最容易回归的部分。
4. **反馈通道要么静默要么抢焦点。** `report()` 只写 `lastError` 和日志；被阻塞的开始动作则直接弹出设置窗口，打断用户在目标应用里的输入。
5. **工程基础薄弱放大了以上问题。** 无 XCTest/Swift Testing target，测试靠手写 `swiftc` 文件列表；无构建 CI；Swift 5 语言模式 + `SWIFT_STRICT_CONCURRENCY: minimal`，靠 9 处 `@unchecked Sendable` 和 7 套手写 generation token 维持并发安全；192 处中文字符串硬编码在 Services/Models 层；偏好 key 散落在 4 个文件；数据目录混用 `RTranslate/` 与 `Saylane/`。

6. **与同类产品相比，触发与截屏入口的设计偏离了行业惯例。** Wispr Flow、Typeless、豆包都默认按住 Fn，Superwhisper 用同一键"点按切换 / 按住 PTT"，没有产品把双击和长按放在同一个键上，也没有产品用"按住单个修饰键"进入截屏；钉图类产品（PixPin、CleanShot）都不冻结全屏。详见 §4。

建议路线：**不做大爆炸重写**。先建安全网（测试 target + CI），再把 `AppModel` 按职责拆成可独立测试的 Store + Feature 模块，随后按"语音 → 输入事件 → 截屏翻译 → 拼音"顺序逐个迁移，每一阶段都能独立发版。预计 6 个阶段，前两个阶段是后续所有工作的前提。

---

## 1. 排查范围

- 全部 Swift 源码（`Sources/`，约 12.5k 行）、`project.yml`、`Makefile`、`scripts/test.sh`、打包与安装脚本。
- `docs/` 全部设计文档与变更记录，用于对照"设计意图 vs. 实现"。
- 本机运行证据：`~/Library/Application Support/RTranslate/Diagnostics/input-session.json`（当前触发键为右 ⌘，全局 tap 处于 `filter` 模式，ghostty 下 IME 在同一秒内 attach/detach 两次）；`/Library/Input Methods` 同时装有豆包输入法。
- 未做：真机逐应用验收、性能采样。以下"体验问题"里凡是标注"推断"的，需要真机复现确认。

---

## 2. 体验问题清单

按用户可感知的严重度分级：**P0** 影响主流程能否用；**P1** 明显别扭、会让人放弃；**P2** 打磨项。

### 2.1 安装与首次使用

| 级别 | 问题 | 证据 |
| --- | --- | --- |
| P0 | PKG 未签名、未公证，Gatekeeper 会拦截。README、官网和安装说明都在向用户解释如何绕过。 | `scripts/package.sh:585-598`；`docs/安装说明.md` |
| P1 | 没有任何更新机制。用户不知道有新版，升级只能手动下载 PKG。 | 源码无 update/Sparkle 相关代码 |
| P1 | 引导完成标记已重置到 `setupVerifiedV7`，每次改 key 老用户都要重走引导。 | `AppModel.swift:128` |
| P1 | 启动后 `settingsChanged()` 立即进入 `isChecking`，此时按快捷键会因 `.modelsChecking` 直接弹出设置窗口，抢走目标应用焦点。刚登录/刚启动时第一次按键几乎必现。 | `AppModel.swift:300, 383-396, 617-620, 763-787` |
| P2 | 引导页里的"试一下"用的是 `SettingsCaptureTarget`，写入的是 SwiftUI `TextEditor` 而不是真实 IMK 客户端，与真实输入框行为不一致，试成功不代表真实场景成功。 | `AppModel.swift:1018-1038` |

### 2.2 语音输入主链路

| 级别 | 问题 | 证据 |
| --- | --- | --- |
| P0 | **句首丢字。** 录音在会话建立之后才开始。当触发键是右 ⌘ 且开启了双击切换（你的当前配置），先等 180 ms 长按判定；全局路径再切换 TIS、轮询 IMK 客户端最长 80×40 ms；然后 `coordinator.start` 才调用 `capture.startStream()`。v1 架构文档写的"立刻开麦、先缓冲"从未实现。 | `InputShortcutHandler.swift:7, 80-83`；`AppModel.swift:514-525, 559-595`；`SessionCoordinator.swift:117-125`；`docs/ARCHITECTURE.md` §3 |
| P0 | **目标应用不挂载 IMK 时按键无响应。** 终端、部分 Electron/Chromium 输入框、非文本焦点下，`waitForClientAndStart` 空转 3.2 s 后 `captureTarget()` 返回 nil，只 `report()` 一条错误到设置页。用户体感是"按了没反应"。本机日志显示 ghostty 下 attach/detach 抖动。 | `AppModel.swift:578-595, 621-628`；诊断日志 |
| P0 | **全局唤起会永久替换用户的输入法。** 全局路径 `selectEnabledMode()` 切到 Saylane 后不恢复原输入源。装了豆包/系统拼音的用户每说一句话，键盘就被换成 Saylane 的 Rime。研究文档推荐的"路线 A：结束后恢复原输入法"没有实现。 | `AppModel.swift:562-566, 582-584`；`docs/history/KEYBOARD_INPUT_ARCHITECTURE.md` 路线 A |
| P1 | **任何应用激活都会取消会话。** `NSWorkspace.didActivateApplicationNotification` 一律 `coordinator.cancel()`。通知横幅、Spotlight、密码弹窗、甚至截屏翻译面板自己 `NSApp.activate` 都会打断正在进行的听写。 | `AppModel.swift:267-278`；`ScreenTranslateController.swift:1210` |
| P1 | **本地模型 30 秒硬上限直接丢弃整段。** 超过 30 s 抛 `ASRModelError.tooLong`，"本次未提交"，之前说的内容全部丢失，没有分段或保留已识别部分。 | `SpeechModel.swift:131`；`QwenAudioBuffer` |
| P1 | **HUD 不显示任何文字。** 只显示波形；识别/译文只以 marked text 的形式出现在目标输入框。在 marked text 渲染差的客户端（Chromium、终端、部分 Electron）里，用户说话期间看不到任何反馈。`OverlayController.setSource/setTranslation` 是死代码。 | `OverlayController.swift:139-147`；`OverlayView.swift` |
| P1 | **错误不可见或抢焦点。** 终端错误只在 `overlayEnabled && state == .idle` 时显示通用的"转换失败"，具体原因藏在设置页 banner；准备阶段的阻塞则弹设置窗口。两种反馈方式都不合适。 | `AppModel.swift:249-257, 383-396, 1010-1015` |
| P1 | **改语言对触发两次完整重载。** `pairSource` 和 `pairTarget` 各自 `didSet` → `applyPairAsTranslateMode()` → `settingsChanged()`，每次都取消会话、重置翻译引擎、可能卸载 Qwen、重新检查模型。 | `AppModel.swift:20-31, 469-475, 763-787` |
| P1 | **翻译模型下载依赖设置窗口可见。** `.translationTask` 挂在 `SettingsView` 上，`downloadModels()` 只是设置 `translationConfiguration`；窗口没开就什么都不会发生。截屏翻译又单独挂了一个在工具条视图上。 | `SettingsView.swift:82-84`；`ScreenTranslateController.swift:1466-1468` |
| P2 | 听写过程中 `consumeIMEEvent` 对所有按键返回 `false`，按键会透传到 marked text 下方的客户端；"任意键结束"只在全局 tap 路径实现。 | `AppModel.swift:481-486`；`PushToTalkHandler.swift` |
| P2 | 20 s 准备超时、180 s 听写超时、8 s 润色超时是三个散落的魔法数，且超时后都以"取消"处理而非降级提交。 | `SessionCoordinator.swift:117, 147, 263` |

### 2.3 拼音输入

| 级别 | 问题 | 证据 |
| --- | --- | --- |
| P1 | **候选窗定位在不返回光标矩形的客户端里跳到屏幕左下角。** `caretScreenRect()` 用 `attributes(forCharacterIndex: 0)`，客户端返回零矩形时回退到 `visible.minX + 24, minY + 80`。 | `SaylaneInputController.swift:188-193`；`CandidateWindowController.swift:144-151` |
| P1 | **一个 Rime session 服务所有客户端。** 切换窗口时通过 `onWillSwitchClient` 强制 `commit()`，会把高亮的中文候选提交进旧窗口。Squirrel 等成熟实现是每个 `IMKInputController` 一个 session。 | `SaylaneInputController.swift:120-133`；`AppModel.swift:262`；`PinyinEngine.swift` |
| P2 | 每个按键事件都调用 `overrideKeyboard(withKeyboardNamed:)`。 | `SaylaneInputController.swift:97` |
| P2 | Shift 切中英文与语音触发键耦合（`shiftToggleEnabled`）；"联想"偏好保留但功能不存在。 | `PinyinEngine.swift:68-76, 102-106` |

### 2.4 截屏翻译

| 级别 | 问题 | 证据 |
| --- | --- | --- |
| P1 | **钉住期间全屏冻结所有鼠标/滚轮输入。** `ScreenPinFreezePanel` 覆盖每块屏幕并吞掉所有事件，用户在关闭前无法操作任何应用。 | `ScreenTranslateController.swift:654-697, 1240-1251` |
| P1 | **钉住面板 `NSApp.activate` + `makeKey`。** 输入法宿主变成前台应用，触发 `deactivateServer` → 提交拼音、取消语音会话；同时触发 2.2 里的 workspace 取消。 | `ScreenTranslateController.swift:1210-1213` |
| P1 | **左 ⌃ 长按 0.3 s 触发划选。** 终端用户习惯先按住 ⌃ 再想按什么，很容易误触全屏遮罩。 | `ScreenHoldHandler.swift:55` |
| P2 | 翻译模型未安装时靠 100 ms 轮询 200 次等待。 | `ScreenTranslateController.swift:333-336` |
| P2 | 截屏方向用 `UserDefaults` 直读直写，绕过了偏好层。 | `ScreenTranslateController.swift:411-414`；`AppModel.swift:932-934` |

### 2.5 设置与反馈

| 级别 | 问题 | 证据 |
| --- | --- | --- |
| P1 | 设置窗口打开期间每秒轮询权限（`CGPreflight*`、AV 授权、TIS 列表）。 | `SettingsView.swift:99-105`；`PermissionService.swift` |
| P1 | 术语表默认开启且每天从维基百科/维基词典拉取。一个输入法进程默认联网，用户没有被告知也没有确认。 | `AppModel.swift:83-90, 700-705`；`DictationGlossaryRemote.swift:5-16` |
| P2 | 应用只有中文界面，错误文案生成在 Services 层，无法本地化。 | Services/Models 层 192 处中文字面量 |
| P2 | 设置页 `busy` 时整块 `disabled`，用户不知道为什么灰掉。 | `SettingsView.swift:154, 180, 203` |

---

## 3. 根因分析

### 3.1 技术设计

**T1 · 会话的"开始"绑定了太多前置条件。** `startSessionNow` 要求：权限就绪、模型就绪、输入源已选中、IMK 客户端已挂载、目标可捕获，全部满足才 `coordinator.start`，而录音又在 `start` 内部才开始。正确顺序应当是：按键即开麦（进环形缓冲），其余条件并行准备，准备好后把缓冲喂给识别器；任何一项失败再把缓冲丢弃并明确告诉用户失败原因。

**T2 · 输入事件没有单一入口。** 同一个物理按键可能同时经由 CGEvent tap（后台线程）和 IMK `handle`（主线程）到达，两边各持一份 `InputShortcutHandler` 状态；设置窗口又有第三份。`GlobalHotkeyRouter.owningGesture`、`AppModel.shortcutDirectActive` 等标志就是为了在三条路径之间打补丁。

**T3 · 状态靠回调闭包广播。** 全项目 42 个 `var onX: ((...) -> Void)?`。`SessionCoordinator` 有 7 个；`ScreenTranslateController` 的 4 个回调在 `handleScreenCaptureHotkey` 里每次调用都重新赋值。没有一个地方能回答"现在整个应用处于什么状态"，UI 只能靠 `isListening`、`isChecking`、`isPreparingModels`、`asrModels.isDownloading` 这些派生布尔量拼凑。

**T4 · 取消语义各自为政。** `SpeechEngine`、`TranslationEngine`、`QwenSpeechEngine`、`LocalSpeechRuntime`、`ScreenTranslateController`、`IMEManager`、`AppModel.settingsRevision` 各自维护 generation/token；有的用 `Int`，有的用 `UUID`，有的既检查 token 又检查 `Task.isCancelled`。结构化并发本可以用父任务取消解决大部分。

**T5 · 反馈通道设计缺失。** 没有区分"需要用户立即知道"（会话失败）、"需要用户稍后处理"（权限缺失）和"仅供排查"（诊断）。于是所有错误都进 `lastError`，再由各处按自己的理解决定要不要弹窗。

### 3.2 架构设计

**A1 · 上帝对象 + 单例。** `AppModel.shared`、`IMEManager.shared`、`GlobalHotkeyMonitor.shared`、`QwenRuntime.shared`、`DictationGlossaryStore.shared`、`ScreenFontWeightService.shared`、`RimeRuntime.shared`。`SaylaneInputController` 直接读写 `AppModel.shared`。`scripts/test.sh` 里每个测试都要手工列出依赖文件，正说明依赖图已经无法自动切分；`AppModel` 本身完全不可测。

**A2 · 分层不存在。** `Services/` 里既有纯逻辑（`DictationCleanup`）、系统适配（`AudioCaptureService`）、UI（`OverlayController` 持有 `NSPanel`）、又有 1479 行的 `ScreenTranslateController` 内含 8 个 NSPanel/NSView 子类和 SwiftUI 视图。`Models/ScreenTranslate.swift`（968 行）里是布局算法。

**A3 · 持久化与命名混乱。** 62 处 `UserDefaults.standard` 直接调用分布在 4 个文件，加上 SwiftUI 里的 `@AppStorage`。目录：模型在 `RTranslate/ASRModels`，诊断在 `RTranslate/Diagnostics`，Rime 在 `Saylane/Rime`；Keychain service 是 `com.rtranslate.final-polish`；bundle ID 是 `com.rtranslate.inputmethod.rtranslate`。`AppModel.init` 里还有一段旧域迁移。

**A4 · 功能间的隐式耦合。** 截屏翻译复用语音的双击切换手势并用 `screenActive` 抢占；截屏的 `NSApp.activate` 会经由 workspace 通知取消语音；拼音的 Shift 切换要看语音触发键；设置窗口打开会 `pinyin.commit()` + `coordinator.cancel()`。三个功能本应各自独立。

**A5 · IMK 进程承担了过多职责。** 输入法宿主进程里跑着 librime、CoreML 字重模型、Vision OCR、屏幕捕获、SwiftUI 设置窗口、MLX worker 管理、维基百科抓取。Qwen 已经拆到子进程是对的，其余重活也应尽量离开输入事件所在的进程/线程。

### 3.3 工程实践

**E1 · 测试。** `Tests/` 3476 行全部是 `precondition` 式可执行程序，由 `scripts/test.sh` 逐个 `swiftc` 编译；无 XCTest/Swift Testing target，无法在 Xcode 里跑单测，无覆盖率，无法并行。CI 只部署网站（`.github/workflows/pages.yml`），源码构建和测试没有 CI。

**E2 · 并发配置。** `SWIFT_VERSION: 5.0`、`SWIFT_STRICT_CONCURRENCY: minimal`。9 处 `@unchecked Sendable`、49 处裸 `Task {}`、9 处 `DispatchQueue.main.async`（tap 线程回主线程）、5 处 `MainActor.assumeIsolated`。编译器没有在帮忙。

**E3 · 可观测性。** 5 处 `NSLog` + 一个 60 条的 JSON 环形日志。没有 `os.Logger` 分类、没有 signpost，没法回答"这次按键到首个 partial 花了多久"这类问题（`SpeechSessionMetrics` 有雏形但只进日志）。

**E4 · 文档漂移。** `ARCHITECTURE.md` 描述的是 v1 菜单栏应用 + CGEvent 注入；`VOICE_INPUT_V2.md`、`SCREEN_TRANSLATE*.md` 是按版本追加的变更日记，且自述"现有实现是半成品，不要把当前实现当设计"。没有一份文档描述当前架构。

**E5 · 本地化。** 界面与错误文案全部硬编码中文，README 却有中英两版，官网也面向英文用户。

---

## 4. 同类应用对标与最佳实践

对标对象：语音输入类 Wispr Flow、Typeless、Superwhisper、豆包输入法 Mac 版、Apple 听写；截屏翻译类 Easydict、Bob、PixPin、CleanShot X、系统截屏；输入法类鼠须管（Squirrel）；快捷键绑定参考 sindresorhus/KeyboardShortcuts。以下只写官方文档能核实的做法，并逐条对照 Saylane 现状。

### 4.1 语音触发方式

| 产品 | 默认触发 | 免提/长句 | 备注 |
| --- | --- | --- | --- |
| Wispr Flow | 按住 Fn（无 Fn 键则 ⌃⌥） | Fn+空格 切换免提 | 按下即录音；另有 Command 模式 Fn+⌃ |
| Typeless | 按住 fn | fn+空格 免提 | 松开后整段粘贴 |
| Superwhisper | 可选 Toggle 或 Push-to-talk | 同一键：快速点按 = 切换，按住 = PTT | 另有"按住换模式"键；支持鼠标侧键 |
| 豆包输入法 Mac | 按住 Fn | 未核实 | 作为输入法运行 |
| Apple 听写 | 双击 Fn / 双击 ⌃（外接键盘）或 F5 麦克风键 | 单击再按停止 | 双击是为了防误触 |
| Saylane 现状 | 右 ⌥（可选 17 个固定键） | "点按开始"偏好 | 右 ⌘ 同时承担长按说话与双击切方向 |

行业共识与 Saylane 的差距：

1. **默认键是 Fn。** 三家主流产品都用 Fn 按住；它几乎不与任何应用快捷键冲突，且用户在别的产品里已经形成肌肉记忆。Saylane 默认右 ⌥ 会吃掉 ⌥+字母 输入特殊字符和 ⌥+Delete 删词，这也是当前代码要在会话期间"吞掉 Option"的原因。建议默认改为 Fn，右 ⌥ 保留为可选。
2. **同一个键上"点按 = 切换、按住 = PTT"合一**（Superwhisper 做法），而不是用一个"触发方式"偏好在两种模式之间二选一。判定规则：按下 ≤ 250 ms 松开 = 点按进入免提，之后再点一下结束；超过 250 ms 仍按住 = PTT，松开提交。录音从按下瞬间开始，两种情况都不丢句首。
3. **免提用组合键（Fn+空格），不用同键双击。** 双击与长按放在同一个键上必然要等双击窗口，Saylane 当前 180 ms 的 `holdDelay` 正是这样来的。切换翻译方向应改为独立快捷键（默认 Fn+D 一类），或放进 HUD/菜单，不再与说话键共用右 ⌘。
4. **按下即录音是所有 PTT 产品的默认行为**，Apple 听写也是按键后立刻出现麦克风波形。这与本文 §5.4 的 preroll 设计一致。
5. **HUD 显示状态文字**（"Listening"、"Processing"、错误原因），不只是波形。Wispr Flow 与 Typeless 的浮动胶囊都带状态；失败时在同一个胶囊里显示原因，不弹窗口。
6. **无法组字时的退路。** Typeless/Superwhisper 走 Accessibility 粘贴，所以在终端、Electron 等任何焦点下都能用。Saylane 用 IMK marked text 是差异化优势（可编辑中间稿、不污染剪贴板），应保留；但目标客户端 1 s 内没有挂载 IMK 时，应提供"以 Accessibility 插入最终结果"的退路（默认关，引导里说明需要辅助功能权限），而不是失败。

### 4.2 快捷键绑定

Wispr Flow 公开的绑定规则可以直接作为 Saylane 的校验规范：

- 必须包含修饰键或合法鼠标键（中键、侧键 4/5），左右键不可绑定；纯字母、数字、标点不可作为触发键。
- 最多三个键；不能同时使用同一修饰键的左右两侧。
- 禁止系统保留组合（⌘空格、⌘⌫、⌘⌃F 等），并对 ⌘⌥+空格/Esc/方向键等给出警告。
- 免提快捷键不能是 PTT 快捷键的子集（否则按下免提键会先触发 PTT）。
- Caps Lock、Esc 作为单键只允许绑定到特定动作；单独占用 Fn 要提示"会改变系统 Fn 行为"。

KeyboardShortcuts 库的 `Recorder` 展示了录制 UI 的标准：点击进入录制态、按下组合即保存、自动检测与系统快捷键和应用菜单的冲突并弹出友好提示、自动持久化。

Saylane 现状与建议：

- 现状：语音触发键是固定枚举 `PushToTalkHotkey`（`Models/PushToTalkHotkey.swift`），只支持修饰键单键和少数 F 键；截屏快捷键有录制功能，但录制逻辑埋在全局 tap 回调里（`GlobalHotkeyMonitor.swift:228-240`）；两者 UI 与校验不一致。
- 建议：一个 `Shortcut` 值类型（修饰键集合 + 可选主键 + 左右区分 + 鼠标键）、一个 `ShortcutRecorder` 视图、一套 `ShortcutValidator`（上面五条规则 + 与 Saylane 内部其他快捷键互斥 + 与 Apple 听写快捷键重复时提示），语音、免提、方向切换、截屏四个动作共用。允许绑定鼠标侧键（Superwhisper 与 Wispr Flow 都支持，Saylane 的 tap 已经能收到鼠标事件）。
- 触发键预设给三档：Fn（推荐）、右 ⌥、右 ⌘，其余通过录制器自定义；设置页展示与 Apple 听写快捷键是否冲突。

### 4.3 首次引导

Typeless 的引导：辅助功能 → 麦克风 → 麦克风测试（说话看蓝条）→ 三个功能各一段可试的演示 → 确认快捷键。Superwhisper 首启只要麦克风和辅助功能两项。行业通行做法：一次只问一项权限、页面内实时重查并自动前进、深链接到精确的隐私面板、每项说明"为什么需要"、必需与可选分开。

Saylane 特殊之处在于它是输入法：多一步"在系统设置里添加输入法"，且输入监控无法像辅助功能那样自动出现在列表里（需要 `CGRequestListenEventAccess` 后引导用户手动添加）。现状的三步引导（欢迎 / 权限 / 试一下）结构没错，问题在细节：

- 试用框用 SwiftUI `TextEditor` 加特殊 `SettingsCaptureTarget`，走的不是真实 IMK 路径。建议在引导窗口里放一个真实的 `NSTextView` 并把 Saylane 选为当前输入源，让试用与真实场景一致；同时加麦克风电平检测（Typeless 的"蓝条"）。
- 权限页应逐项引导而不是一页列全：当前项完成后自动滚到下一项；点"去开通"后进入"等待授权"态，`refresh()` 在引导页内轮询 1 s，引导结束即停止（当前是设置窗口常驻轮询）。
- 输入监控放到"可选增强"页并说明价值："在豆包/系统拼音下也能按 Fn 说话"。若用户跳过，主流程仍完整可用（只在选中 Saylane 时触发）。
- 引导最后一页让用户按一次触发键确认快捷键（Typeless 做法），并展示与 Apple 听写的冲突提示。
- 不因升级重跑引导；重签导致 TCC 失效时，用菜单栏图标标记 + HUD 一次性提示"麦克风权限需要重新允许"，点击直达。

### 4.4 截屏翻译触发与交互

| 产品 | 进入划选 | 划选交互 | 钉住 |
| --- | --- | --- | --- |
| Easydict | ⌥S 截图翻译，⌥A 输入翻译 | 拖拽 | 结果窗口 |
| PixPin | ⌃1 截图，⌃T/⌃2 钉住 | 悬停吸附窗口/元素 + 拖拽，Esc 取消 | 可拖动、可关闭的贴图 |
| CleanShot X | 组合键（可改） | 区域/窗口/滚动，Esc 取消 | 钉在最上层、可拖动 |
| 系统截屏 | ⇧⌘4 / ⇧⌘5 | 空格切换窗口模式，Esc 取消 | 右下角缩略图 |
| Saylane 现状 | ⌥T，或按住左 ⌃ 0.3 s | 悬停吸附 + 拖拽，Esc/右键取消 | 原位钉住、不可拖、冻结全屏 |

差距与建议：

1. **没有产品用"按住单个修饰键"进入截屏。** 全部是组合键单击。左 ⌃ 长按应默认关闭（终端用户误触率高），保留 ⌥T 作为默认；若保留长按，改为"按住 + 鼠标移动超过阈值"才进入。
2. **划选阶段** Saylane 已与 PixPin 对齐（吸附 + 拖拽 + Esc/右键），这部分保留。
3. **钉住阶段** 与所有对标产品相反：Saylane 冻结全屏并吞掉其他应用的输入。对标做法是钉图是一个可拖动、置顶、非激活的浮层，用户可以继续操作其他窗口。建议：去掉全屏冻结（或作为偏好项默认关），面板可拖动，不 `NSApp.activate`，Esc/⌘C 由输入路由在面板可见时接管。
4. **方向切换**：Easydict/Bob 在结果窗口里有语言选择器。Saylane 复用语音的双击右 ⌘ 手势导致两个功能互相干扰；改为面板上的按钮 + 面板内快捷键即可。

### 4.5 输入法本体

鼠须管（Squirrel）作为 macOS 上最成熟的 Rime 前端，是拼音部分的直接参照：

- 每个 `IMKInputController` 持有自己的 Rime session，`activateServer` 时创建/恢复，切换客户端不强制提交。
- `overrideKeyboard(withKeyboardNamed:)` 只在 `activateServer` 调用一次。
- 候选窗跟随 `attributes(forCharacterIndex:lineHeightRectangle:)` 返回的光标矩形，无效时回退到鼠标位置附近。
- 方案切换、部署、用户词库同步都从输入法菜单进入；Saylane 的 IMK 菜单已经有类似结构，可以补上"重新部署 Rime"和"打开用户词库目录"。

### 4.6 分发与更新

独立分发的 Mac 工具（CleanShot、Superwhisper、Wispr Flow、Easydict）全部：Developer ID 签名 + 公证；Sparkle 或自建更新检查；DMG/PKG 双击即装。Saylane 当前 PKG 未签名未公证、无更新检查，这两项比任何代码重构都更直接地影响"第一印象"。

## 5. 目标架构

### 5.1 模块划分

用本地 SPM package 把职责切开，App target 只剩 IMK 入口和装配。依赖只允许自上而下。

```
Saylane.app（IMK 宿主：SaylaneMain、SaylaneInputController、AppDelegate、装配）
  ├─ SaylaneFeatures        各功能的 Store/Reducer 与 SwiftUI/AppKit 视图
  │    ├─ VoiceFeature      VoiceSession 状态机、HUD
  │    ├─ PinyinFeature     每客户端 Composition、候选窗
  │    ├─ ScreenFeature     划选、钉住、翻译覆盖
  │    └─ SettingsFeature   设置、引导、权限页
  ├─ SaylaneInput           统一输入事件路由（tap + IMK + 本地监听）与手势识别器
  ├─ SaylaneSpeech          SpeechRecognizing 协议、Apple 引擎、本地模型运行时、模型商店
  ├─ SaylaneTranslation     TranslationProvider、模型可用性与下载
  ├─ SaylanePinyin          librime C 桥、RimeSession、词库更新
  ├─ SaylaneScreen          OCR、段落分组、版面算法、渲染（纯 AppKit/CoreGraphics，无窗口）
  ├─ SaylanePlatform        权限、TIS 输入源、音频采集、屏幕捕获、Keychain（系统适配，协议 + 实现）
  └─ SaylaneCore            纯逻辑：偏好模型、语言、听写修正、词库、错误类型、日志门面
```

规则：
- `SaylaneCore` 与各算法模块不依赖 AppKit 窗口层，可在任何 target 里测。
- `SaylanePlatform` 只暴露协议（`PermissionProviding`、`InputSourceControlling`、`AudioCapturing`…），App 装配真实实现，测试装配 fake。
- 每个模块独立开启 Swift 6 语言模式与 `strict-concurrency: complete`，先从 Core 开始，逐模块推进。

### 5.2 状态与事件：单向数据流

引入一个 `AppStore`（`@MainActor @Observable`），持有不可变的 `AppState` 值类型，只能通过 `send(_ action:)` 修改；副作用由 `Effect` 描述并交给 `EffectRunner` 执行。视图只读 `state`，服务只发 `Action`。

```swift
struct AppState: Equatable {
    var preferences: Preferences
    var readiness: Readiness            // 权限、输入源、模型
    var voice: VoiceSessionState        // idle / arming / capturing(prerollOnly) / recognizing / finalizing / polishing
    var pinyin: PinyinState
    var screen: ScreenTranslateState
    var notice: UserNotice?             // 唯一的用户反馈通道
    var settings: SettingsUIState
}

enum AppAction {
    case input(InputEvent)              // 来自统一路由
    case voice(VoiceAction)             // partial/final/translated/polished/failed…
    case readiness(ReadinessAction)
    case screen(ScreenAction)
    case preferences(PreferencesAction)
    case system(SystemAction)           // appActivated、inputSourceChanged、deviceChanged…
}
```

好处：状态机可以用纯函数测试（给定 state + action，断言下一个 state 和 effects），不再需要为每个场景造 FakeSpeech/FakeCapture；所有跨功能仲裁（"截屏面板打开时忽略语音按键"）写成 reducer 里的一个 `guard`，而不是四个布尔量。

### 5.3 输入事件统一路由

`InputEventRouter`（在 `SaylaneInput` 模块）是**唯一**消费原始按键的地方。

- 输入源：CGEvent tap（后台线程，只做最小解码后投递）、IMK `handle`、设置窗口本地监听。三者都转换成同一个 `InputEvent { source, type, keyCode, flags, timestamp, isRepeat }` 投递到主 actor 的 `AsyncStream`。
- 去重：同一物理事件可能从 tap 和 IMK 各到一次，按 `(timestamp, keyCode, type)` 在 20 ms 窗口内去重，而不是让 IMK 路径整个放弃热键。
- 手势识别器改为纯值类型 `GestureRecognizer` 协议：`mutating func feed(_ event) -> [Gesture]`，一份实例、一个时钟。现有 `PushToTalkHandler`、`InputShortcutHandler`、`RightCommandDoubleTap`、`ScreenHoldHandler` 合并为一个带优先级的仲裁器；"谁拥有当前手势"是路由器状态，不再散落在 `AppModel`。
- 吞键决策同步返回给 tap 回调（保持现有"回调不阻塞"的约束），但决策依据来自路由器的快照，而不是 monitor 内部另一份状态。

### 5.4 语音会话流水线

```
按键按下
  ├─ 立即：AudioCapture 开始，写入 PrerollBuffer（环形，上限 ~3 s）
  ├─ 并行：准备识别器 / 检查目标 / 若为全局唤起则切输入源并等待 IMK 客户端（有上限）
  └─ 任一失败 → 停止采集，发 .voice(.failed(reason))，HUD 显示原因（不弹设置）
识别器就绪
  └─ 把 preroll 一次性喂入，再切换到实时喂入
partial → HUD 显示原文 / 译文（可关闭）；目标客户端 marked text 同步
松开 → finalize（drain → final → refine → translate → optional polish → commit once）
Esc / 目标丢失 → cancel（清 marked，不提交）
会话结束 → 若本次是全局唤起且用户偏好"回到原输入法"，恢复之前的 TIS 输入源
```

- 本地模型超过时长上限时，先提交已识别的稳定部分并提示，而不是整段丢弃；后续用 VAD 分段替代硬上限。
- 三个超时收敛为 `VoicePolicy` 值类型（`prepareTimeout`、`maxUtterance`、`polishTimeout`），可测、可配置。
- `SpeechSessionMetrics` 改为 `OSSignposter` 区间 + 结构化日志，同时保留 JSON 导出。

### 5.5 并发与取消

- 一个会话 = 一个父 `Task`，采集、识别、预览翻译都是它的子任务；`cancel()` 只取消父任务。各引擎的 generation token 保留作为最后防线，但不再是主要机制。
- 引擎协议改为 `AsyncThrowingStream<SpeechEvent>`（`.partial`、`.final`）而不是 `onPartial` 闭包，天然带取消语义。
- tap 线程 → 主 actor 只用 `AsyncStream.Continuation.yield`，不再 `DispatchQueue.main.async` 捕获 `self`。
- 逐模块开启 `-strict-concurrency=complete`，目标是删掉全部 `@unchecked Sendable`（`AudioFrame` 用 `sending` 参数或不可变拷贝解决）。

### 5.6 持久化与配置

- `Preferences` 是一个 `Codable` 值类型，字段即 key；`PreferencesStore` 负责读写 `UserDefaults`（suite 名固定）、迁移和版本号。全项目禁止直接调用 `UserDefaults.standard`（用 SwiftLint 规则强制）。
- 引导完成状态改为 `onboardingVersion: Int`，升级只在需要新步骤时递增，不再用 `setupVerifiedV7` 这种 key 名。
- 数据目录统一到 `~/Library/Application Support/Saylane/{ASRModels,Diagnostics,Rime,Glossary}`，一次性迁移旧 `RTranslate/` 目录（模型文件用移动而非复制，失败则回退读取旧路径）。Keychain service 同步改名并迁移。

### 5.7 用户反馈

`UserNotice` 是唯一的反馈类型，三个等级由 reducer 决定呈现方式：

| 等级 | 呈现 | 示例 |
| --- | --- | --- |
| `.transient` | HUD 胶囊 2–4 s，不抢焦点 | "没有识别到语音"、"已回到原输入法" |
| `.actionable` | HUD 显示原因 + 菜单栏图标标记；设置页顶部 banner 常驻直到解决 | "麦克风未授权"、"当前语言模型未下载" |
| `.diagnostic` | 仅日志 | 预览翻译暂时失败 |

任何路径都不允许在用户按住快捷键时自动打开设置窗口；只有引导流程和菜单命令可以。

### 5.8 本地化、日志、诊断

- 引入 `Localizable.xcstrings`，中英双语；错误类型是 `enum` + `LocalizedError`，文案在 Features/UI 层解析。
- `os.Logger` 按子系统分类（`voice`、`input`、`pinyin`、`screen`、`models`），signpost 覆盖"按下→采集→首个 partial→提交"。保留现有 JSON 环形日志作为"导出诊断"按钮的数据源。
- 诊断导出与隐私边界不变：不记录音频、按键内容和识别文本。

### 5.9 测试与 CI

- `project.yml` 增加 `SaylaneTests`（Swift Testing）和各 package 的 `Tests/`；现有 `precondition` 测试逐个迁移为 `#expect`，迁移前不删。
- 保留 `scripts/test-rime.sh` 这类必须跨进程的集成测试，改由 `make integration` 触发。
- GitHub Actions：`macos-26` runner，`xcodegen` → `xcodebuild test`（不含需要模型权重的用例）→ 打包（不签名）。PR 必须绿。
- 加 SwiftLint（禁止 `UserDefaults.standard`、禁止 App target 以外引用 `NSApp`、限制文件长度）。

### 5.10 分发

- 申请 Developer ID Installer 证书，`package.sh` 接 `notarytool submit --wait` + `stapler`，PKG 与 app 都公证。这是所有安装体验问题的前提，独立于代码重构。
- 更新检查：菜单里加"检查更新"，请求 GitHub Releases API 比较版本并打开下载页；后续再考虑 Sparkle。

---

## 6. 分阶段实施计划

每个阶段都能单独发一个版本；后一阶段依赖前一阶段但不依赖更后面的。每阶段列出：范围、关键改动、验收标准、风险。规模用 S/M/L 表示相对工作量（S 约数天，M 约一到两周，L 两周以上，按一人全职估算）。

### Phase 0 · 安全网与分发（S–M，可与 Phase 1 并行）

范围：不改产品行为。

1. `project.yml` 加 Swift Testing target；把现有 `Tests/*.swift` 里不依赖真实模型的用例迁入（先做 `SessionCoordinator`、`InputShortcut`、`GlobalHotkey`、`ScreenTranslate` 布局、`DictationCleanup`、`Vocabulary`）。`scripts/test.sh` 保留到迁移完成。
2. GitHub Actions 构建 + 测试。
3. `os.Logger` + signpost 骨架，先接到 `SessionCoordinator.mark()` 现有埋点。
4. PKG 签名与公证；菜单"检查更新"。
5. 写 `docs/ARCHITECTURE.md` 的"当前实现"版本（替换 v1 底稿），作为后续每阶段更新的唯一架构文档。

验收：CI 绿；`xcodebuild test` 可在本机运行；新 PKG 在干净 Mac 上双击可装无 Gatekeeper 警告。

风险：低。公证需要账号与证书，是流程而非技术风险。

### Phase 1 · 拆 AppModel：Store + Preferences + Readiness（M）

范围：引入 `AppStore`/`AppState`/`AppAction`，把 `AppModel` 里三块最独立的职责先搬出去，对外接口暂时保持（`AppModel` 变成 Store 的门面，视图逐步改读 `store.state`）。

1. `Preferences` + `PreferencesStore`（5.6），一次性迁移所有 `UserDefaults` 调用，包括 `PinyinEngine`、`ScreenTranslateController`、`ScreenFontWeightService`、`SettingsView` 的 `@AppStorage`。目录与 Keychain 改名迁移放在这里。
2. `ReadinessReducer`：权限、输入源、模型三类就绪状态合成 `Readiness` 值；`SetupReadiness.Blocker` 保留但改由 reducer 计算。去掉 `SettingsView` 的每秒轮询，改为事件驱动（TIS 通知、`AVCaptureDevice` 授权变化、模型商店事件）+ 窗口获得焦点时刷新一次。
3. `UserNotice`（5.7）替换 `lastError` / `report()`；HUD 与设置 banner 都从 `state.notice` 渲染。`showBlockedStart` 不再打开设置窗口。
4. 语言对修改合并为一个 `PreferencesAction.setLanguagePair(a:b:)`，只触发一次模型检查。
5. 引导流程按 §4.3 重做：逐项权限、页内实时重查自动前进、真实 `NSTextView` 试用 + 麦克风电平条、最后一页按一次触发键确认快捷键；输入监控移到"可选增强"；`onboardingVersion` 替代 `setupVerifiedV7`。

验收：`AppModel.swift` 减到 400 行以下；Store reducer 有纯函数测试覆盖 Readiness 全部 blocker 组合；启动后第一次按键不再弹设置窗口；改语言对只触发一次 `settingsChanged`；干净账户走完引导后能在备忘录里完成一次真实听写。

风险：中。UserDefaults 迁移要覆盖旧 key（含 `com.rtranslate.app` 域）；用一组"升级前后偏好一致"的测试保护。

### Phase 2 · 统一输入事件路由（M）

范围：`SaylaneInput` 模块（5.3）。

1. `InputEvent` + `InputEventRouter`；CGEvent tap、IMK `handle`、设置窗口监听三处只做转换与投递。
2. 四个手势识别器合并为一个带优先级的仲裁器；`GlobalHotkeyRouter`、`shortcutDirectActive`、`suppressWorkspaceCancel`、`screenActive` 删除，改为 reducer 中的显式规则。
3. 去重逻辑替代"tap 存活时 IMK 不看热键"。
4. `NSWorkspace.didActivateApplication` 不再直接取消会话；改为 `SystemAction.frontmostAppChanged(bundleID)`，reducer 只在**目标应用**变化且当前会话绑定了该应用时取消。
5. 快捷键模型按 §4.2 统一：`Shortcut` 值类型 + `ShortcutRecorder` + `ShortcutValidator`（Wispr Flow 五条规则、内部互斥、Apple 听写冲突提示），语音、免提、方向切换、截屏四个动作共用；支持鼠标侧键。`PushToTalkHotkey` 枚举退化为预设列表（Fn / 右 ⌥ / 右 ⌘）。
6. 触发语义改为"同键点按 = 免提切换、按住 = PTT"（Superwhisper 模式），阈值 250 ms；方向切换改为独立快捷键，默认 Fn+D，不再与说话键共用双击。默认触发键改为 Fn，升级用户保留原设置。

验收：现有热键/手势测试全部迁移到新仲裁器并通过；新增"同一按键从 tap 与 IMK 各到一次只产生一个手势"测试；截屏面板打开期间语音按键被忽略是 reducer 测试而非运行时标志；`ShortcutValidator` 对规则表内每条有测试；录制 ⌘空格 被拒绝并给出原因。

风险：中高。这是最容易回归的部分，必须在 Phase 0 的测试基础上做；发版前按 `docs/history/VOICE_INPUT_V2.md` §6 的门槛做真机矩阵。

### Phase 3 · 语音会话体验（M–L）

范围：`VoiceFeature` + `SaylaneSpeech`（5.4、5.5）。这是用户能感知收益最大的阶段。

1. `PrerollBuffer`：按下即采集，识别器就绪后回灌。Phase 2 已把双击从说话键上移走，所以不再有"判定期间"的问题；点按进入免提时同样从按下开始录。
2. 全局唤起：记录原输入源；会话结束且前台应用未变时恢复；偏好项"说完后回到原输入法"默认开启。等待 IMK 客户端上限降到 1 s，超时给出明确 `.actionable` 提示（"当前应用不支持输入法组字，请点进文本框后重试"）。
3. HUD 按 §4.1 第 5 条：波形 + 状态词（正在听 / 正在整理 / AI 校对中）+ 可选原文/译文两行（默认开启，可关），失败原因显示在同一胶囊；复用 `OverlayController` 现有死接口。
3a. 无 IMK 客户端时的退路（可选、默认关）：目标应用 1 s 内未挂载 IMK，且用户已授予辅助功能权限，则仍完成识别并在松开时用 Accessibility 插入最终文本（Typeless/Superwhisper 方式），HUD 说明"本次以粘贴方式写入"。
4. 引擎协议改为 `AsyncThrowingStream<SpeechEvent>`；`SessionCoordinator` 改为父任务 + 子任务，删除 `Run` 里的 6 个 `Task?` 字段。
5. `VoicePolicy` 收敛超时；本地模型超长时提交已识别部分。
6. 翻译模型下载脱离设置窗口：`TranslationProvider` 内部持有一个隐藏宿主窗口承载 `.translationTask`，语音与截屏共用一个 provider 实例。

验收：signpost 数据显示"按下→首帧音频入缓冲"< 50 ms；从其他输入法按键说话后输入法恢复；ghostty/Chromium 下按键 1 s 内必有 HUD 反馈（成功或失败原因）；连续 20 次按住/松开无重复提交（沿用现有门槛）；`SessionCoordinatorTests` 全部场景在新实现上通过。

风险：中。preroll 与 Apple `SpeechAnalyzer` 的格式转换要在真机验证；恢复输入源在目标应用有未提交拼音时的行为需要实测并写进文档（研究文档已指出不能承诺无损）。

### Phase 4 · 截屏翻译模块化（M）

范围：`ScreenFeature` + `SaylaneScreen`。

1. `ScreenTranslateController.swift` 拆为：`ScreenTranslateReducer`（状态）、`ScreenCaptureFlow`（划选）、`ScreenPinWindow`（窗口与视图，一个文件一个类）、`ScreenTranslatePipeline`（OCR → 分组 → 翻译 → 布局，纯异步函数）。`Models/ScreenTranslate.swift` 的布局算法迁到 `SaylaneScreen`，不再叫 Model。
2. 钉住面板按 §4.4 改为 PixPin/CleanShot 式贴图：非激活、可拖动、置顶；不 `NSApp.activate`、不 `makeKey`；Esc/⌘C/空格由输入路由在 `screen.isPinVisible` 时接管。全屏冻结改为偏好项且默认关闭。
3. 入口按 §4.4 第 1 条：默认只保留组合键 ⌥T（通过统一录制器可改）；左 ⌃ 长按默认关闭，若开启则要求按住期间鼠标移动超过阈值才进入划选。
4. 翻译模型等待改为 `await provider.ready()`，去掉轮询。
5. 与语音的方向切换手势解耦：截屏面板内用自己的按钮/快捷键，reducer 中不再复用 `.switchTarget`。

验收：钉住期间可以操作其他应用；打开截屏不会取消进行中的语音会话（或明确以 reducer 规则禁止同时进行）；`ScreenTranslateTests` 的 123 个断言迁移通过；文件均在 400 行以下。

风险：低到中。视觉行为要与用户认可的 0.2.60 基线做截图对照（`scripts/test-screen-scenarios.sh` 已有基础）。

### Phase 5 · 拼音：每客户端会话（M）

范围：`PinyinFeature` + `SaylanePinyin`。

1. 对齐鼠须管（§4.5）：每个 `SaylaneInputController` 持有自己的 `RimeSession`（`activateServer` 创建、`deactivateServer` 保留、controller 释放时销毁），候选窗共享。切换窗口不再强制提交。输入法菜单补"重新部署"和"打开用户词库目录"。
2. 候选窗定位：先用 `attributes(forCharacterIndex:)` 于当前光标位置，零矩形时退回到 `NSEvent.mouseLocation` 附近而非屏幕角落；记录最近一次有效位置作为同客户端的回退。
3. `overrideKeyboard` 只在 `activateServer` 调用。
4. Shift 切换与语音触发键解耦：由输入路由在识别到 Shift 单击手势后投递 `.pinyin(.toggleEnglish)`。
5. 删除无效的"联想"偏好，或在 Rime 接入 predict 插件后再恢复。

验收：`scripts/test-rime.sh` 通过；两个窗口交替输入不互相提交；Chromium 输入框候选窗贴近光标或鼠标。

风险：中。librime 多 session 的内存与用户词库并发写入需要验证（Squirrel 已证明可行）。

### Phase 6 · 收尾：Swift 6、本地化、文档（S–M）

1. 全部模块开启 Swift 6 语言模式与 `strict-concurrency: complete`，删除 `@unchecked Sendable`。
2. `Localizable.xcstrings` 中英双语；Services/Core 层不再含用户可见字面量。
3. `docs/` 整理：`ARCHITECTURE.md` 描述现状；各 `*_V2.md`/变更日记合并进 `CHANGELOG.md`；删除自述"不要当设计"的过期文档。
4. 术语表联网改为默认关闭 + 首次开启时说明数据来源。

验收：编译零并发警告；界面切换到英文系统完整可读；新同学只读 `ARCHITECTURE.md` 就能定位每个功能的入口。

---

## 7. 明确不做的事

- 不做跨平台壳、不做 macOS 26 以下兼容（`VOICE_INPUT_V2.md` §3 的旧系统方案继续搁置）。
- 不在重构期间引入新的识别/翻译后端。
- 不重写 Rime 集成本身（C 桥与 schema 保持），只改会话所有权。
- 不重做设置页视觉（0.2.66/0.2.67 已经来回一次）。

---

## 8. 不等重构也能先做的改动（每项 ≤ 1 天）

按收益排序，都可以在当前代码上直接落地，且不会与后续阶段冲突：

1. **启动/改语言后按键弹设置窗口**：`showBlockedStart` 对 `.modelsChecking` 只发 HUD 提示，不 `openSettings()`。（`AppModel.swift:388-391`）
2. **句首丢字（部分缓解）**：在 `performShortcut(.armHold)` 时就 `capture.startStream()` 进一个临时缓冲，`.press` 时交给 coordinator；`.release`/双击判定时丢弃。这是 Phase 3 preroll 的最小版本。
3. **全局唤起后恢复输入法**：`startSession(fromGlobal:)` 前记录 `InputSourceInstall.currentID`，`onCommit`/`cancel` 后若前台 bundle 未变则 `TISSelectInputSource` 回去。先做成偏好项默认开。
4. **改语言对只重载一次**：`pairSource`/`pairTarget` 的 `didSet` 改为只写偏好，新增 `setLanguagePair(a:b:)` 统一触发 `settingsChanged()`。（`AppModel.swift:20-31`）
5. **截屏钉住不抢焦点**：去掉 `ScreenPinPanel.present` 里的 `NSApp.activate` 与 `makeKey`，Esc 改由已存在的全局 tap 处理。（`ScreenTranslateController.swift:1210-1213`）
6. **设置页停止每秒轮询**：`.task` 改为窗口 `didBecomeKey` 时刷新一次 + 已有 TIS 通知。（`SettingsView.swift:99-105`）
7. **左 ⌃ 长按默认关闭**，作为偏好项开启。
8. **PKG 签名公证**：与代码无关，越早越好。
9. **新用户默认触发键改为 Fn**（`PushToTalkHotkey.function` 已存在），已有用户不动；设置页提示与 Apple 听写"双击 Fn"的关系。
10. **HUD 加状态词**：`OverlayView` 在 `.listening` 时显示"正在听"，失败时显示 `SessionFailure` 的具体文案而非通用"转换失败"。

---

## 9. 度量：重构前后要对比的指标

| 指标 | 重构前 | 重构后（2026-09-29） | 目标 |
| --- | --- | --- | --- |
| 按下 → 首帧音频进入缓冲 | 180 ms + TIS 切换 + ≤3.2 s 等待 | 按下即开麦（`PrerollCapture`），等待上限 1 s | < 50 ms |
| 按下 → 用户看到任何反馈（HUD） | 依赖 `overlayEnabled` 与状态，失败路径无反馈 | 失败原因进同一胶囊；不再弹设置 | < 200 ms，含失败原因 |
| `AppModel.swift` 行数 | 1039 | 604 | < 400，最终删除 |
| 最大单文件行数 | 1479 | 968（`ScreenLayout.swift`，纯算法） | < 500 |
| `UserDefaults.standard` 直接调用 | 62 处 / 4 文件 | 1 处（`PreferencesStore`，测试强制） | 1 处 |
| `var onX:` 回调 | 42 | 45（新增的在功能对象与组合根之间） | < 10 |
| `@unchecked Sendable` | 9 | 11 | 0 |
| 手写 generation token 的类 | 7 | 7 | ≤ 2 |
| Swift 语言模式 / 并发检查 | 5 / minimal | 6 / complete | 6 / complete |
| 可在 Xcode 运行的测试 | 0 | 0（仍为 `swiftc` 可执行测试；新增 6 组） | 迁移到 Swift Testing |
| CI | 仅网站 | 仅网站（Phase 0 未做） | 构建 + 测试 + 打包 |

---

## 附录 · 对标资料来源

- Wispr Flow：[快捷键支持规则](https://docs.wisprflow.ai/articles/2612050838-supported-unsupported-keyboard-hotkey-shortcuts)、[免提模式](https://docs.wisprflow.ai/articles/6391241694-use-flow-hands-free)
- Typeless：[安装与引导](https://www.typeless.com/help/installation-and-setup)、[第一次听写](https://www.typeless.com/help/quickstart/first-dictation)
- Superwhisper：[快捷键设置](https://superwhisper.com/docs/get-started/settings-shortcuts)、[快速开始](https://superwhisper.com/docs/get-started/quickstart.md)
- 豆包输入法 Mac 版：[App Store 页面](https://apps.apple.com/cn/app/id6752316550)（按住 Fn 说话；其余细节未核实）
- Apple 听写快捷键：[Apple 支持文档](https://support.apple.com/guide/mac-help/use-dictation-mh40584/mac)
- Easydict：[README](https://github.com/tisfeng/Easydict)（截图翻译默认 ⌥S）
- PixPin：[静态截图](https://pixpin.com/docs/capture/static-capture)、[钉图](https://pixpin.com/blog/articles/pin-screenshot-on-screen/)
- KeyboardShortcuts：[sindresorhus/KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)
- 鼠须管：[rime/squirrel](https://github.com/rime/squirrel)
- Apple 开发者论坛关于输入监控权限列表的讨论：[thread 828052](https://developer.apple.com/forums/thread/828052)
