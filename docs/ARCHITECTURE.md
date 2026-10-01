# Saylane 架构（当前实现）

更新：2026-09-29。本文描述仓库 `main` 的实际结构。历史设计稿在 `docs/history/`，重构的动机与验收标准在 `docs/REFACTOR_PLAN.md`。

Saylane 是一个 macOS 系统输入法（InputMethodKit 宿主进程），提供三件事：按住快捷键说话并把识别 / 译文写进当前文本框、Rime 拼音打字、划区截屏翻译。识别与翻译全部在本机完成。

## 1. 目录与模块

```
Sources/
  SaylaneMain.swift        进程入口：IMKServer、命令行诊断模式、Debug 预览
  SaylaneApp.swift         AppDelegate：菜单、bootstrap
  AppModel.swift           组合根。视图观察的唯一对象；不含功能逻辑
  Core/                    纯值与纯函数，任何 target 都可测试
    Preferences.swift        全部用户设置，一个值类型
    PreferencesStore.swift   唯一读写 UserDefaults 的地方；旧 key / 旧域 / 引导标记迁移
    AppDirectories.swift     ~/Library/Application Support/Saylane/… 与 RTranslate/ 迁移
    Readiness.swift          权限 / 输入源 / 模型就绪状态 + ReadinessReducer
    UserNotice.swift         唯一的用户反馈类型：transient / actionable / diagnostic
  Input/                   原始按键 → 手势
    InputEvent.swift         统一事件值、InputContext、InputAction
    GestureArbiter.swift     一个值类型识别全部手势（录制、截屏、划选、双击、语音）
    InputEventRouter.swift   唯一消费者：三路来源、去重、长按 / 双击计时器
    GlobalHotkeyMonitor.swift CGEvent tap 适配器（后台线程，只转换事件）
    InputShortcutHandler / PushToTalkHandler / GlobalHotkeyRouter / ScreenHoldHandler
                             手势识别器（保留原有测试）
    ShortcutValidator.swift  快捷键录制规则（Wispr Flow 规则 + Apple 听写冲突提示）
  Voice/                   语音功能
    VoiceSessionController   按下 → 预录 → 会话 → 写入；HUD 接线。不切换输入法
    VoiceTarget.swift        FocusedTextTarget：按「IMK 客户端 → 粘贴 → 剪贴板」写入前台应用的光标处
    PrerollCapture.swift     按下即开麦的环形缓冲，之后回灌给会话
    SessionCoordinator.swift 一次会话的状态机（识别、预览翻译、终稿、润色、提交）
    VoicePolicy.swift        所有超时常量
    ModelCoordinator.swift   语音 / 翻译模型的检查、下载、加载、卸载
    AccessibilityInserter    无 IMK 客户端时粘贴写入（⌘V，随后恢复剪贴板）
    OverlayController.swift  底部 HUD 面板
    MicrophoneLevelMeter     引导页麦克风电平
  Screen/                  截屏翻译
    ScreenFeature.swift      功能接线：权限、偏好、快捷键录制、与语音的让位规则
    ScreenTranslateController 状态 + 流水线（截取 → OCR → 分组 → 翻译 → 布局）
    ScreenSelectionPanel     划选覆盖层
    ScreenPinPanel / ScreenPinViews / ScreenPinChrome  钉住面板、贴片视图、工具条
    ScreenLayout.swift       版面算法、ScreenCaptureShortcut（纯逻辑）
    ScreenOCRService / ScreenCaptureService / ScreenFontWeightService / ScreenPinRenderer / ScreenWindowProbe
  IME/                     InputMethodKit 与 Rime
    SaylaneInputController   IMKInputController + IMEManager（客户端捕获、marked text、光标矩形）
    InputSourceInstall.swift TIS 注册 / 启用 / 选择 / 恢复
    Pinyin/PinyinEngine      每客户端一个 RimePinyinSession；候选窗共享
    Rime/                    librime C 桥、会话、词库更新
  Services/                识别引擎、翻译引擎、TranslationProvider、PermissionsController（权限请求与输入法启用流程）、听写修正、润色接口
  Models/                  AppLanguage、SpeechModel、SessionState、SetupReadiness 等
  Views/                   SwiftUI 设置与引导
  Support/                 诊断日志、预览快照、主题
```

依赖方向：`Views → AppModel → {Voice, Screen, Input, IME, Services} → Core/Models`。`Core` 与 `Input` 的手势层不依赖窗口，可用 `swiftc` 单独编译测试（见 `scripts/test.sh`）。

## 2. 状态从哪里来

- **偏好** 只有一个来源：`PreferencesStore.current: Preferences`。视图用 `AppModel.binding(\.key)` 读写；`AppModel.update` 在写入后按字段差异触发副作用（重载模型、重置手势、刷新路由上下文）。任何文件直接调用 `UserDefaults.standard` 会被 `Tests/BrandingTests.py` 拒绝。
- **就绪** 是 `Readiness` 值，只由 `ReadinessReducer.reduce(state, event)` 产生。权限、TIS、全局 tap、模型协调器各自发 `ReadinessEvent`；`readiness.blocker` 决定按键能否开始，`ReadinessReducer.destination` 决定把用户送到哪一页。
- **反馈** 是 `UserNotice`。`AppModel.post(_:)` 按等级决定呈现：`transient` 只在 HUD 停留几秒；`actionable` 进 HUD、设置 banner 和输入法菜单，直到解决；`diagnostic` 只记日志。任何路径都不会在用户按键时打开设置窗口。

## 3. 输入事件如何流动

```
CGEvent tap（后台线程）─┐
IMK handle（主线程）────┼─► InputEventRouter ─► GestureArbiter ─► [InputAction] ─► AppModel.perform
设置窗口本地监听 ───────┘        │
                                 └─ 去重：同一物理事件 50 ms 内从 tap 与 IMK 各到一次只算一次
```

- `GestureArbiter.feed(event, context)` 是纯函数式的值类型，优先级固定：快捷键录制 → 划选中的 Esc → 左 ⌃ 长按（可选）→ 右 ⌘ 双击 → 截屏组合键 → 语音触发键。截屏会话激活时语音键被忽略。
- tap 回调只做转换和一次加锁的 `feed`，并同步返回是否吞掉事件；动作通过 `AsyncStream` 按序投递到主 actor。
- `VoiceSessionController` 每次进入准备、录音、收尾、空闲状态以及开始 / 结束唤起时，都同步路由上下文；路由不能一直沿用启动时的 `isListening = false`。输入法被禁用后不拦截语音键。去重同时比较来源、类型、键码、修饰状态与 repeat，松开不能被当成按下的重复投递。
- 长按 / 双击窗口的计时器在 `InputEventRouter` 内，到期时再问一次仲裁器（`voiceDeadline` / `screenHoldDeadline`）。
- 钉住的截屏结果**不**在全局层抢键，只有面板被点击成为 key 后，本地监听才处理 Tab / ⌘C / D / R / Esc。

## 4. 一次语音会话

```
按下（armHold / armTap / press）
  └─ VoiceSessionController.arm(): PrerollCapture 立即开麦，环形缓冲 ≤ 3 s
press
  ├─ 试用页可见且设置窗口当前拥有焦点 → 试用框目标，直接开始
  └─ 否则 beginGlobalWake(): 记录原输入源与前台应用；不是我们就 TISSelect；
       最多等 policy.clientWait = 2 s 让目标应用挂载 IMK 客户端；核对客户端所属应用；
       已选中但没有连接时，通过已启用的 ASCII 布局做一次有界切换以恢复连接
startNow
  ├─ readiness.blocker → post(actionable, 目标页)；丢弃预录；恢复输入源
  ├─ 无 IMK 客户端 → 开启了辅助功能退路则用 AccessibilityTarget，否则 actionable 提示
  └─ SessionCoordinator.start(capture: preroll)：先回灌缓冲，再实时喂入
partial → HUD 原文 / 译文 + 目标 marked text
松开 → 立即停止硬件采集（等待客户端期间也一样），保留已采集帧；
       finalize（drain → final → refine → translate → polish → commit 一次）
Esc / 目标丢失 / 目标应用切走 → cancel
结束 → 若为全局唤起且偏好开启且前台应用未变 → 恢复原输入源
```

超时全部来自 `VoicePolicy`（准备 20 s、单句 180 s、润色 8 s、等客户端 2 s、预录 3 s）。本地模型到 30 s 上限时，`SessionCoordinator` 收到长度上限错误后按"松开"处理并提交已识别部分。

`PrerollCapture.stop()` 与 `discard()` 有不同语义：前者停止麦克风并排空已收到的帧，后者取消并丢弃。会话开始时同步领取 stream，防止等客户端期间已经松手的短句在异步 setup 前被取消。缓冲区溢出必须报错，不能无声丢字。可选辅助功能插入绑定原先的具体 AX 输入框；插入失败不能记录为提交成功。

## 5. 模型生命周期

`ModelCoordinator.apply(preferences)` 在语言对 / 模型 / 仅识别变化时调用一次：取消上一轮、发 `.modelsInvalidated`、重置翻译、按需卸载 Qwen、检查安装状态并发布 `.speechModel` / `.translationModel` 事件。下载走 `downloadModels()`；Apple 翻译模型的下载由 `TranslationProvider` 负责，它自带一个只在下载期间出现的小窗口承载 `.translationTask`，语音与截屏各持一个 provider（方向可以不同）。

## 6. 截屏翻译

`ScreenTranslateController` 只保存状态并跑流水线；窗口分别在 `ScreenSelectionPanel`（划选）和 `ScreenPinPanel`（钉住）。钉住面板是 `.nonactivatingPanel`，可拖动，不调用 `NSApp.activate`；全屏冻结是偏好项（默认关）。翻译模型未安装时 `await translation.ready(...)` 等待下载完成，没有轮询。

## 7. 拼音

`IMEManager` 保留当前 controller，controller 保存 IMK 本次传入的文本客户端，停用时释放。启动期间已挂载的客户端也会同步到拼音层；旧 controller 的迟到停用 / 提交回调不操作新 controller。`PinyinEngine` 以 controller 的独立 UUID 保存 `RimePinyinSession`（`IMEManager.onWillSwitchClient` 切换），最多 12 个 LRU，避免对象地址复用命中旧会话；`deactivateServer` 时按 IMK 语义提交。候选窗位置来自 `IMEManager.caretScreenRect()`：先问当前插入点，再回退到上次有效位置，再回退到鼠标附近。

## 8. 并发

App target 以 Swift 6 语言模式 + `strict-concurrency: complete` 编译。UI 与编排都在主 actor；跨线程边界只有三处：CGEvent tap 线程（`SharedArbiter` 加锁 + `AsyncStream`）、音频回调（只传 `AudioFrame` 拷贝）、本地模型推理（`LocalSpeechRuntime` actor + 子进程）。

## 9. 测试

`scripts/test.sh` 用 `swiftc` 逐个编译 `Tests/*.swift`（`precondition` 式可执行程序）并运行，再跑 Rime、本地模型与打包脚本检查。手势、偏好迁移、就绪归约、预录缓冲、快捷键校验、会话状态机都有独立用例；`Tests/BrandingTests.py` 守住标识与存储的向后兼容。

## 10. 明确的限制

- 没有签名公证与自动更新（计划中的 Phase 0 尚未做）。
- 引导页的试用框写入的是本进程的 `TextEditor`，不是真实 IMK 客户端；输入法宿主不能成为自己的客户端。
- "同键点按 = 免提、按住 = PTT" 的统一触发语义与默认改为 Fn 未实施，保留现有触发方式与默认键。
