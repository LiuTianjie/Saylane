# Saylane 0.3 重写设计（两进程）

更新：2026-10-01。本文记录 0.3 重写的动机与规格；实现后的结构见 `docs/ARCHITECTURE.md`。

## 0. 为什么重写

0.2.x 把拼音、语音、截屏翻译、设置窗口、全部权限都放在一个 InputMethodKit 宿主进程里。2026-10-01 在真机上用系统日志和反汇编确认了它的三个结构性问题：

1. **输入法进程不能随便退出。** `imklaunchagent` 统计自己拉起的输入法进程的退出次数：30 分钟窗口内第 11 次起，向所有客户端广播 `com.apple.inputmethodkit.abnormaldeath`。每个当时连着它的 App 会记下“The Input Method … has crashed … will no longer be usable in the process”，切回 ABC，并且在自己重启前再也不连接这个输入法（HIToolbox `IMServerDiedAbnormally_Modern`、`-[IMKClient_Modern remoteXPCProxyForSession:]`）。0.2.x 的每次安装、每次“屏幕录制”授权后的“退出并重新打开”、任何一个功能的崩溃，都会消耗这个额度并中断所有 App 的打字。
2. **输入法进程成了前台应用。** 设置 / 引导窗口属于输入法进程，点它一下输入法自己就成了 frontmost，TSM 行为随之异常（0.2.68 记录过）。
3. **主线程被无关工作占用。** 权限轮询、模型加载、HUD 动画、识别回调都和 `handleEvent` 抢同一个主线程；客户端对输入法的调用是同步的，有超时。

对照物是成熟的输入法产品（豆包输入法）：输入法是一个后台进程，不做全局事件监听，语音键走输入法自己的按键通道；设置是单独的应用。

## 1. 进程

| | 输入法 `SaylaneIME` | 主程序 `Saylane` |
|---|---|---|
| 位置 | `/Library/Input Methods/Saylane.app` | `/Applications/Saylane.app` |
| Bundle ID | `com.rtranslate.inputmethod.rtranslate`（不变） | `com.rtranslate.saylane` |
| 类型 | `LSBackgroundOnly` | `LSUIElement` |
| 负责 | IMKServer、拼音（librime）、候选窗、把文字写进当前客户端 | 快捷键、录音、识别、翻译、润色、HUD、截屏翻译、设置与引导、权限、模型 |
| 权限 | 无 | 麦克风、语音识别、辅助功能、屏幕录制 |
| 生命周期 | 由系统按需拉起；除升级外不退出 | 输入法启动或挂上客户端时若未运行则在后台拉起；有辅助功能权限时还是登录项；崩溃或授权重启都不影响打字 |

输入法进程里没有任何会申请权限、联网或加载模型的代码。

## 2. 进程间协议（`Sources/Shared/Bridge*.swift`）

传输用两个 `CFMessagePort`（同一用户会话内的本地端口，两个进程都不在沙盒里）：

- 输入法监听 `com.rtranslate.saylane.ime-bridge`，在主 run loop 上处理主程序的请求。
- 主程序监听 `com.rtranslate.saylane.app-bridge`，接收输入法的事件。

消息是 `Codable` 的 JSON，带 `protocolVersion`。发送都经过各自的一条串行队列，保证顺序；输入法发事件永不等待回复，发送超时 20 ms，连续失败则暂停转发 1 s，主程序卡死不会拖慢打字。

主程序 → 输入法：

| 消息 | 语义 |
|---|---|
| `status` | 版本、pid、协议版本、当前挂载的客户端所属应用、拼音引擎错误 |
| `context` | 整份状态推送：语音阶段、触发键、截屏快捷键、是否正在划选、主程序是否自己监听按键、提交等待上限、菜单要显示的文字 |
| `voiceMarked(session, seq, text)` | 在光标处显示预览（marked text） |
| `voiceClear(session)` | 撤回预览 |
| `voiceInsert(session, text, deadline)` → `Bool` | 写入终稿并回放期间排队的按键；超过 `deadline` 或没有可写的客户端时返回 `false` |
| `voiceEnd(session)` | 会话结束（取消或失败），回放排队按键 |
| `pinyin(prefs)` | 模糊音、候选条预编辑、中英文模式 |

输入法 → 主程序：

| 事件 | 语义 |
|---|---|
| `hello(status)` | 输入法启动；主程序随后重发 `context` 与拼音偏好 |
| `attachment(bundleID?)` | 挂载的客户端变了；`nil` 表示当前没有 |
| `key(kind, keyCode, flags, isRepeat, timestamp)` | 只有键码和修饰位，没有字符；仅当主程序没有自己的按键监听时转发，普通打字从不转发 |
| `talkKey(bundleID, at)` | 触发键在当前客户端里按下。按键只会送到拥有键盘的客户端，所以此刻键盘就在这里；无论是否转发按键都会发（见 §5） |
| `userTyped(session)` | 等终稿期间用户敲了第一个键（它在排队）；只差润色的结果应立即写入 |
| `typingResumed(session)` | 用户在等终稿时继续打字，预览已撤回 |
| `menu(action)` | 输入法菜单里的命令（打开设置、切换方向、截屏翻译、复制上一次听写） |
| `pinyinMode(english)` | Shift 切换了中英文 |

存活检测：双方在握手时互换 pid，用 `DispatchSource` 进程退出源监听对方。主程序退出时输入法把语音阶段复位为空闲并回放排队按键；输入法退出时主程序改走粘贴。

## 3. 谁听按键

- **有辅助功能权限**：主程序建一个可拦截的 `CGEvent` tap，任何应用、任何输入法下都能触发；`context.appOwnsKeys = true`，输入法不再转发按键。
- **没有**：输入法把 IMK 收到的 `flagsChanged` / `keyDown` 的键码转发给主程序，手势在主程序的同一个 `GestureArbiter` 里识别。只有 Saylane 是当前输入法且焦点在文本框时有效，和豆包一致。应用自己吃掉的 ⌘ 快捷键输入法看不到，用 `CGEventSource.secondsSinceLastEventType`（不需要权限）补上组合键判断；松开事件丢失用 `CGEventSource.flagsState` 兜底。

输入法本地只做三条同步判断（不能等主程序）：语音进行中或划选中的 Esc 吞掉；截屏快捷键吞掉；等终稿期间可排队的按键先排队。

修饰键作触发键时，它自己的按下和松开**从不被吞掉**（两种监听方式都一样）：单独一个修饰键本身什么也不做，而跟随修饰键状态的应用（⌘ 悬停、应用切换器）必须照常看到它；输入法也靠它知道键盘此刻在哪个客户端。功能键触发键有自己的可见行为，只在能拦截时使用并被吞掉。

## 4. 语音手势（`VoiceGesture`）

修饰键触发，按住说话：

```
按下（当时没有其它修饰键）──► 待定
  0.12 s 仍单独按着        ──► 预热：静默开麦，不显示任何东西
  0.28 s 仍单独按着        ──► 开始：HUD 出现
  期间按了别的键 / 点了鼠标 / 加了修饰键 ──► 作废，直到松开为止都不再触发；预热的录音丢弃
  0.28 s 内松开            ──► 轻点（用于双击切换方向），不开始
说话中松开                 ──► 结束并写入
说话中 Esc                 ──► 取消
说话中按了别的键 / 点了鼠标  ──► 打断：不足 1.5 s 静默取消；否则停止并把已识别的文字放进剪贴板
```

点按模式（`tapToTalk`）：干净的一次轻点（按下到松开之间没有别的键）在**松开时**开始；再按一次结束。功能键触发没有组合键问题，按下即开始，需要辅助功能权限。

## 5. 文字去向

一次听写属于按下时**拥有键盘**的应用。通常就是前台应用；两种情况例外：

- **浮动面板**（Spotlight、Raycast / Alfred 这类启动器、快速输入窗、系统的打开 / 保存面板）拿到键盘却不会成为“前台应用”。判断依据是 `talkKey`：这一次按下的触发键是经由输入法当前挂载的客户端送来的（2 s 内有效），而 IMK 只把按键送给拥有键盘的客户端，于是听写属于这个客户端的应用。没有这条证据（例如功能键触发、别的输入法）时仍以前台应用为准。
- **helper 进程**：Chromium / Electron 应用的文本客户端报的是 helper 的标识（真机日志里飞书是 `com.electron.lark.helper`）。标识是应用标识加 `.` 后缀的客户端算作该应用的。

终稿依次尝试：

1. 输入法通道（Saylane 是当前输入法且挂载的客户端属于该应用）：`insertText`，替换预览。
2. 粘贴（有辅助功能权限）：写剪贴板、发 ⌘V、1.2 s 后恢复剪贴板。
3. 复制到剪贴板并提示。

应用切走、或面板已经关闭（输入法不再挂载在它上面）则只复制并提示，不会写进别的应用。任何路径都不丢字；最近一次结果可从菜单“复制上一次听写”取回。

## 6. 安装与升级

- 一个安装包装两个 bundle。`preinstall` 让主程序正常退出；**不**杀输入法。
- `postinstall`：由主程序的可执行文件注册输入源；此时仍在运行的旧输入法进程只结束一次；以登录用户身份打开主程序。
- 每次安装输入法进程只退出一次。开发期在同一台机器上 30 分钟内安装不超过 3 次。
- 卸载脚本先停用输入源，再退出两个进程，删除两个 bundle；偏好与模型保留。

## 7. 数据

- 偏好仍存在 `com.rtranslate.inputmethod.rtranslate` 域：主程序用 `UserDefaults(suiteName:)` 读写，升级不丢设置。输入法只在启动时读一次拼音相关的几项，其余由 `context` / `pinyin` 推送。
- `~/Library/Application Support/Saylane/` 不变。诊断日志按进程分成 `Diagnostics/ime.json` 与 `Diagnostics/app.json`，连续相同的记录合并计数。

## 8. 验收（真机）

1. 备忘录、微信、Chrome、VS Code、终端、Claude 桌面端、飞书、Spotlight：拼音可打字；按住触发键说话，文字出现在光标处。
2. ⌘W、⌘C、⌘Tab、⌥←、⇧A、⌘-点击不触发听写、不开麦。
3. 授权辅助功能后，在豆包 / ABC 输入法下同样可以说话并写入。
4. 授权屏幕录制（系统要求重启主程序）前后，任何应用里的拼音打字不中断。
5. 强制结束主程序：打字不受影响；再次需要时主程序被拉起。
6. 升级安装后，已经开着的应用无需重启即可继续打字。
