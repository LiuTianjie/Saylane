# Saylane 架构（当前实现）

更新：2026-10-01（0.3.0）。本文描述仓库的实际结构。为什么拆成两个进程见 `docs/DESIGN_0.3.md`；更早的设计稿在 `docs/history/`。

Saylane 提供三件事：按住快捷键说话并把识别 / 译文写进当前文本框、Rime 拼音打字、划区截屏翻译。识别与翻译全部在本机完成。

## 1. 两个进程

| | 输入法 `SaylaneIME` | 主程序 `Saylane` |
|---|---|---|
| 位置 | `/Library/Input Methods/Saylane.app` | `/Applications/Saylane.app` |
| Bundle ID | `com.rtranslate.inputmethod.rtranslate` | `com.rtranslate.saylane` |
| 类型 | `LSBackgroundOnly` | `LSUIElement` |
| 负责 | IMKServer、拼音（librime）、候选窗、把文字写进当前客户端 | 触发键、录音、识别、翻译、润色、HUD、截屏翻译、设置与引导、模型 |
| 权限 | 无 | 麦克风、语音识别、辅助功能、屏幕录制 |
| 寿命 | 由系统按需拉起；除升级外不退出 | 输入法挂上客户端时若未运行则在后台拉起；有辅助功能权限时还是登录项。可以随时退出、崩溃、被系统要求重启，打字不受影响 |

输入法进程必须长寿：`imklaunchagent` 统计它的退出次数，30 分钟内第 11 次起所有连着它的应用会永久（直到应用重启）放弃这个输入法。所以凡是会申请权限、联网、加载模型、开窗口的代码都不在这个进程里，`scripts/stage-bundles.sh` 和 `Tests/BrandingTests.py` 会拒绝它链接 AVFoundation、Speech、ScreenCaptureKit 等框架。

## 2. 目录

```
Sources/
  Shared/                  两个进程都编译
    BridgeMessages.swift     协议：请求、事件、整份状态 BridgeContext、端口名
    BridgePort.swift         CFMessagePort 的监听端与发送端
    TestHome.swift           SAYLANE_TEST_HOME：与已安装的产品隔离的测试环境
  IME/                     只在输入法进程
    SaylaneIMEMain.swift     入口：IMKServer；--self-test / --self-test-duo
    SaylaneInputController   IMKInputController：激活、停用、按键回调
    IMEManager.swift         当前客户端的租约、marked text、写入、光标矩形
    InputMethodCore.swift    每个按键的本地决定；主程序请求的预览与终稿写入
    IMEHost.swift            进程接线：拼音、桥、按需拉起主程序
    BridgeResponder.swift    解码请求 → core → 编码回复
    Pinyin/ Rime/            拼音引擎、候选窗、librime 桥
    IMESelfTest.swift        用进程内的文本客户端跑真实代码
  App/                     只在主程序
    SaylaneMain.swift        入口：输入源注册 / 停用（供安装脚本调用）、诊断命令
    AppDelegate.swift        启动参数（--installed、--settings、--background…）
    AppModel.swift           组合根。视图观察的唯一对象
  Core/                    纯值与纯函数：Preferences、PreferencesStore、AppDirectories、Readiness、UserNotice
  Input/                   原始按键 → 手势
    VoiceGesture.swift       触发键状态机（按住、轻点、作废、打断）
    GestureArbiter.swift     全部手势的固定优先级
    InputEventRouter.swift   唯一消费者：来源去重、计时器
    GlobalHotkeyMonitor.swift CGEvent tap
    ScreenHoldHandler / ShortcutValidator
  Voice/                   VoiceSessionController、SessionCoordinator、VoiceTarget（写入路线）、
                           PrerollCapture、OverlayController（HUD）、AccessibilityInserter（粘贴）、LocalTextInserter
  Screen/                  截屏翻译：划选、OCR、版面、钉住面板
  Services/                IMEBridgeClient（主程序一侧的桥）、InputSourceInstall、LoginItem、
                           识别 / 翻译引擎、模型安装、权限、润色、词库更新
  Models/ Views/ Support/  类型、SwiftUI 设置与引导、诊断、自测
```

`project.yml` 有两个 target：`SaylaneIME` = `IME/**` + `Shared/**` + 少量共用文件 + librime；`Saylane` = 除 `IME/**` 以外的全部。

## 3. 桥

两个本地 `CFMessagePort`，`Codable` JSON，各自一条串行发送队列。

- 主程序 → 输入法（`com.rtranslate.saylane.ime-bridge`）：`status`、`context`、`pinyin`、`voiceMarked`、`voiceClear`、`voiceInsert`（带截止时间，返回是否写入）、`voiceEnd`。
- 输入法 → 主程序（`com.rtranslate.saylane.app-bridge`）：`hello`、`attachment`、`key`、`talkKey`、`userTyped`、`typingResumed`、`menu`、`pinyinMode`。

三条规则：

1. **输入法从不等主程序。** 按键怎么处理由 `InputMethodCore` 根据上一次收到的 `BridgeContext` 当场决定。事件发送超时 20 ms，超时后暂停转发 1 s。
2. **状态整份推送。** 主程序每次变化都重算整份 `BridgeContext`（语音阶段、会话、触发键、是否自己听按键、截屏快捷键、菜单文字）并带修订号；丢一条或乱序都不会留下半截状态。
3. **互相看着对方的进程。** 主程序退出，输入法立刻把语音阶段复位并放行排队的按键；即使主程序只是卡死，`listening` 240 s、`finalizing` 45 s 后也会自行复位。输入法退出，主程序改走粘贴。

## 4. 按键

```
CGEvent tap（主程序，需辅助功能）─────────────┐
输入法转发的键码（IMK，无需权限）── 桥 ─────────┼─► InputEventRouter ─► GestureArbiter ─► AppModel.perform
设置窗口本地监听 ─────────────────────────────┘
```

- 有辅助功能权限：主程序自己听，任何应用、任何输入法下都有效；`context.appOwnsKeys = true`，输入法不再转发。
- 没有：输入法把修饰键变化、带修饰键的按键、Esc 的键码转发过来（普通打字从不离开输入法进程）。只有 Saylane 是当前输入法且光标在文本框里时有效。应用自己吃掉的组合键输入法看不到，用 `CGEventSource.secondsSinceLastEventType` 判断“按住期间有没有敲过别的键”；松开事件丢失由 `CGEventSource.flagsState` 轮询兜底。
- 修饰键触发键从不被吞掉。输入法每次看到触发键按下都会报告 `talkKey`（哪个客户端），主程序据此知道键盘在哪里。

触发键状态机（`VoiceGesture`）：单独按住 0.12 s 静默开麦，0.28 s 开始；期间有别的键、点击或第二个修饰键则本次按下作废；说话中松开结束，Esc 取消，别的键或点击是打断（1.5 s 内静默丢弃，之后停止并把文字放进剪贴板）。点按模式在一次干净轻点的松开时开始。

## 5. 一次听写

```
开始   VoiceSessionController.start()
         readiness.blocker → 提示并结束
         归属 = keyboardOwner(前台应用)   浮动面板、helper 进程见 DESIGN §5
         SessionCoordinator.start(预录缓冲 + 实时音频)
预览   partial → HUD 声波；输入法挂载在归属应用上时在光标处显示 marked text
松开   立即停麦 → final → refine → translate → polish → 提交一次
写入   FocusedTextTarget.commit：输入法 insertText → 本进程文本框 → 粘贴 → 剪贴板
         应用切走 / 面板关闭 / 被打断 → 只放剪贴板并提示
```

等终稿期间用户继续打字：输入法把可排队的按键（最多 64 个）排在终稿之后；超过 `userInputFence`（0.45 s）或遇到不能排队的键（回车、方向键、快捷键）则打字先行，终稿稍后照常写入。

超时都在 `VoicePolicy`：准备 20 s、单句 180 s、润色 8 s、预录 3 s、打断宽限 1.5 s。

## 6. 状态从哪里来

- **偏好**：`PreferencesStore`，存在输入法的域 `com.rtranslate.inputmethod.rtranslate`（升级不丢），主程序用 `UserDefaults(suiteName:)` 读写。输入法启动时自己只读触发键和拼音的几项，其余靠推送。
- **就绪**：`Readiness` 值，只由 `ReadinessReducer` 产生。
- **反馈**：`UserNotice`（`transient` / `actionable` / `diagnostic`）。任何路径都不会在用户按键时弹出设置窗口。
- **数据**：`~/Library/Application Support/Saylane/`。诊断日志按进程分成 `Diagnostics/ime.json` 与 `Diagnostics/app.json`，只有阶段与状态，没有文字内容和打字的键码。

## 7. 安装

一个安装包装两个 bundle（`scripts/stage-bundles.sh` 签名，`scripts/component-plist.py` 固定路径）。

- `preinstall`：让主程序退出。不碰输入法进程。
- `postinstall`：用主程序的可执行文件注册输入源；仍在运行的旧输入法进程只结束一次；以登录用户身份打开主程序（`--installed`：只有还缺必需项时才显示引导）。
- 每次安装输入法进程恰好退出一次。同一台机器 30 分钟内安装不要超过 3 次。

## 8. 并发

Swift 6 语言模式 + `strict-concurrency: complete`。UI 与编排在主 actor。跨线程边界：CGEvent tap 线程（加锁的仲裁器 + `AsyncStream`）、音频回调（只传帧拷贝）、本地模型推理（actor + 子进程）、桥的发送队列与主程序的接收队列。

## 9. 测试

| 命令 | 内容 |
|---|---|
| `make test` | `swiftc` 逐个编译运行 `Tests/*.swift`：手势、仲裁、路由、输入法核心、桥（两个真实进程）、会话、偏好、模型、Rime、安装脚本契约 |
| `make test-ime` | 已构建的输入法，进程内文本客户端：真实 Rime、候选窗、桥、预览与终稿写入 |
| `make test-duo` | 两个已构建的程序一起跑完整听写（脚本化的识别器），客户端在前台和作为浮动面板各一遍 |
| `make test-ui` | 已构建的主程序：真实窗口里点按钮、按触发键 |
| `make verify` | 以上全部 |
| `scripts/verify-staged.sh` | 对将要进安装包的已签名 bundle 再跑三个自测（`package-local.sh` 会自动调用） |

自测都在 `SAYLANE_TEST_HOME` 指向的临时目录里运行：独立的数据目录、偏好域和端口名，不发按键、不碰剪贴板、不启动已安装的产品。

本机测不到的只有四样：InputMethodKit 到其它应用的传输、TCC 授权、以 root 运行的安装脚本、真实麦克风与识别模型。

## 10. 明确的限制

- 安装包未签名、未公证，没有自动更新。
- 没有辅助功能权限时，触发键只在 Saylane 是当前输入法且光标在文本框里时有效。
- 功能键作触发键需要辅助功能权限。
- 一个应用如果在本次开机期间见过输入法进程异常退出（见 §1），需要重启该应用才会重新连接。
