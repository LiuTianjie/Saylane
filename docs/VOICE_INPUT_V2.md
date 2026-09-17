# Saylane 语音输入 V2：产品流程、架构与验收

更新：2026-09-07。本文是下一版的实现契约，不代表下列功能已经全部实现。

## 1. 先承认可用性缺口

当前版本没有完成端到端验收，不能作为“已可用的生产版”交付。旧 dist/0.1.0 包不能用于验收本轮修复。
本轮本机复现：TISCreateInputSourceList 返回 Unmanaged<CFArray>?，直接 as? [TISInputSource] 永远失败。导致安装检测一直失败；快捷键触发后会进入 fail，HUD 随后消失。这不是已证实的进程崩溃。
本机现有安装位于用户 Input Methods，且属主为 root；与此前摘要声称的系统级安装不一致，以本机检查为准。

## 2. 唯一主流程

1. 安装器：退出旧 Saylane，核验 bundle ID 后清理系统/当前用户 Input Methods 和 Applications 的旧副本；保留设置，不碰其他输入法。安装到唯一系统级路径。
2. 在登录用户的 GUI 会话中注册输入源、启用、选中，并读回校验。文件拷贝成功不等于安装成功。失败必须明确报告，不能忽略退出码。
3. 首次引导显示四个检查项：输入源可见、已选中、麦克风授权、模型准备好。缺哪一项就提供对应修复；最后在引导内的测试输入框完成一次实际听写。
4. 用户选择“说话语言”“输出语言”。相同时直接听写，完全跳过翻译模型。第一版是显式选择说话语言，不假装已有自动语言检测。
5. 未选中本输入法时明确显示“切换到 Saylane”，不偷偷依赖全局键盘监听权限。先保证选中输入法的路径稳定；任意输入法下全局唤起另列功能。
6. 在目标应用聚焦普通文本框，按住用户设定的快捷键。底部居中显示无边框、不可拖的波形胶囊；不抢焦点、不展示识别或译文。
7. 同语言：partial 通过 IMK setMarkedText 直接更新目标输入框。不同语言：短语级节流翻译，更新同一段 marked text；中间稿可变，不逐条追加，也不承诺中英翻译零延迟逐字同步。
8. 松开：停止采集，排空已采集音频，等待最终识别；必要时做最后一次翻译，只 insertText 提交一次，然后 HUD 消失。
9. Esc：取消会话和在途结果，清除本会话 marked text；不提交、不删用户原有文字。
10. 中途换应用/输入源/光标目标：取消当前会话，禁止把剩余文字送进新输入框。错误保留在设置状态中，可查看原因和重试，不可静默消失。

## 3. 模型与兼容性决策

当前工程：macOS 26.0+、arm64-only；不是“所有 Mac”。即使系统和架构符合，也要调用 SpeechTranscriber.isAvailable，再检查语言与资产状态。

### 推荐候选（需实测后定默认，不能靠名字保证效果）

- Apple SpeechTranscriber：现有后端；受系统、硬件和语言支持限制。模型资产由系统管理。先修通这个后端作为基线。
- sherpa-onnx + 中英 streaming Zipformer：优先评估的可下载流式后端。运行时支持 macOS、Swift，提供中英流式模型；适合持续 partial 的交互。运行时与具体模型权重分别核验许可证。
- whisper.cpp + multilingual base/small：多语言兼容后端。项目支持 Intel/Arm Mac，提供实时分窗示例，但不能把反复解码窗口冒充原生增量流式。small 官方表格约 466 MiB 磁盘、852 MB 内存，只是模型估算，不是整个应用峰值；中文不能选 .en 模型。
- SenseVoice：短句可用。0.2.64 用前缀重识别刷新 marked text，仍不是常驻流式后端；不得把它宣传成逐字原生流式。

目标兼容范围拟定为 macOS 14+ / Intel + Apple Silicon，但尚未实现/验证。需要拆掉当前全局 macOS 26 API 依赖、做后端 availability 隔离、构建 universal binary、实测低配机器，不能只改 deployment target。

语音识别与翻译是两个独立能力。引入开源 ASR 不会自动补齐旧系统翻译能力。旧系统跨语言方案尚待选择独立本地翻译后端或用户明确开启的云端后端；无法翻译时不得把中文误当英文成功提交。

## 4. 目标架构

Settings/Onboarding -> CapabilityProbe / InputSourceInstaller / ModelStore
IME Controller -> SessionCoordinator -> AudioCapture -> ASRProvider
ASR partial/final -> OutputPipeline (same language bypass / TranslationProvider) -> captured IMK client
SessionCoordinator -> bottom HUD (phase + audio level only)

- IMEController：唯一主热键入口；请求 keyDown、keyUp、flagsChanged，区分左右修饰键。事件监听备份不能与 IME 抢吞同一热键。
- SessionCoordinator：单一会话 ID，idle -> preparing -> listening -> finalizing -> idle；cancel/error 路径幂等。每个异步结果校验 ID；press/release/cancel 都只能处理一次。
- AudioCapture：音频回调内立即复制 PCM；有界队列、单消费者，禁止 UI/MainActor 状态直接跨音频线程访问。overflow 必须报告，不能无声丢掉句首。
- ASRProvider：capabilities、prepare、start、appendPCM、partial/final/error、finish、cancel；识别结果带会话 ID 和源文本 revision。
- OutputPipeline：同语言不进翻译；翻译严格按 revision 更新，取消和旧结果不能覆盖新输入。失败不能提交旧译文。
- IME client：录音开始绑定目标，直到结束，不随最新 attach 改变。client 消失即取消。
- ModelStore：固定官方来源、版本与 SHA256、架构/系统限制、磁盘预检、进度/取消/重试、临时文件下载、校验后原子落盘、卸载与损坏修复。用户主动下载，不静默下载大模型。
- 能力诊断：installed/enabled/selected/clientAttached、模型状态、最近错误、会话阶段耗时。不记录用户音频和转写原文。

## 5. 当前修改与尚缺的工作

本轮已改源码：TIS 返回值所有权转换；注册/选中错误退出码；安装脚本 GUI 会话与错误传播；受限旧版清理；SpeechTranscriber 可用性检查；finish 前过早失效 final 结果；暂存音频复制；无效采集格式报错；重复 press/finalize 的部分防重。

尚未完成：完整 coordinator 重构、输入目标绑定、音频队列串行化与排空、热键唯一事件入口、onboarding 自检页、模型下载器和第二后端、旧系统支持、安装签名公证、端到端验收。不能以本轮局部修复代表 V2 完成。

## 6. 交付门槛

- 干净安装：旧副本清理后安装，系统输入法列表真实可见，选中可读回；重启/重登后仍可用。
- 中文->中文：边说边在目标框组字，松开句尾不丢字、只提交一次。
- 中文->英文：实时短语更新，最终英文只提交一次；同语言测试必须证明翻译调用次数为零。
- 连续 20 次按住/松开；短按、长句、快速重按、Esc 在准备/录音/收尾各阶段；不能重复提交或卡死。
- 修改快捷键：设置、菜单、HUD 一致；旧快捷键不触发。
- TextEdit、浏览器 textarea/contenteditable、至少一个 Electron 输入框；目标切换不能串字。
- 无麦克风权限、模型缺失、模型下载中断、无音频设备、翻译失败：明确原因，可恢复，不静默退出。
- 延迟指标记录：按下到采集、首次 partial、最后音频到提交，先记录基线再定预算。
- 构建成功、安装脚本语法成功只是静态/构建验证，不替代以上实测。

## 7. 资料（本轮抓取官方内容核对，非第三方测评）

- Apple SpeechAnalyzer WWDC：https://developer.apple.com/videos/play/wwdc2025/277/
- whisper.cpp：https://github.com/ggml-org/whisper.cpp
- sherpa-onnx：https://github.com/k2-fsa/sherpa-onnx
- 豆包仅核对本机安装的 Info.plist：IMK 配置、最低版本字段；未据此推断其模型、私有实现或所有权限。
- TypeLess 本轮没有取得可核验的交互文档；交互契约以用户明确描述为准，不冒称已完整对照。

## 2026-09-07 本轮实现与验证补充

- 已落地 SessionCoordinator、固定 CompositionTarget、串行 PCM 消费/排空、取消失效保护、翻译单任务合并、收尾超时、IME-only 快捷键、准备检查和测试输入框。
- 删除旧的剪贴板注入、全局 event tap 与未使用的转写桥接代码。
- 注册对照实验：相同安装目录与程序，普通 Bundle ID 注册返回 0 但不可枚举；含 `.inputmethod.` 的 ID 可枚举父输入法与子模式。迁移至 `com.rtranslate.inputmethod.rtranslate`，保留旧域的语言、快捷键、HUD 设置（系统麦克风授权不能迁移）。
- TIS 安装逻辑：检查合法目录；先启用父输入法，再启用/选择可选择模式；读回 enabled/selected。构建目录中的“注册并启用”已禁用。
- 安装包禁止 BundleIsRelocatable，避免 Installer 根据旧副本自动更改安装位置；preinstall 兼容新旧 ID，仅清理本产品。
- 验证：6 种 PCM 格式/布局测试、12 个热键断言、11 类会话场景（含连续 20 次提交）通过。
- 真实 Apple ASR 文件输入：合成中文音频产生 33 次 partial，最终识别完整两句；真实本机翻译模型返回英文。不是麦克风/IME 端到端验证。
- 本机 root 拥有的旧版位于用户 Input Methods，普通用户无权移除，sudo -n 不可用。因此尚不能完成遵守“先清旧版”的实机安装；需要用户在 Installer 授予管理员权限。没有绕过这个权限边界。
- 开源模型、Intel/旧系统、签名公证仍未实现；当前包是验收候选，不宣称已通过完整生产验收。

## 2026-09-07 registration flow correction (0.2.1)

The 0.2.0 installer failed after placing the payload: register=0, enable=0,
select=-50. A default-enabled child mode incorrectly caused the application to
report enablement while its parent remained disabled. This is not a usable IME.

Reference inspected: rime/squirrel `sources/Main.swift`, `sources/InputSource.swift`,
`scripts/postinstall` (upstream master fetched September 7, 2026). Used as a lifecycle
and installer reference, not copied as an implementation or proof this fix works.

Changes:
- Explicit product-only uninstall, including the two diagnostic probe identities.
- Machine-level registration is separated from logged-in user's activation.
- GUI activation keeps a live main run loop for 60 seconds and re-queries exact
  parent/mode identities. Selection requires both enabled flags and exact current ID.
- IMKServer is retained and established before starting the SwiftUI app lifecycle.
- Input mode has a localized display name, intended language, and no default-enabled
  flag that can disguise a disabled parent.
- The package installs files and launches `--setup`; it does not claim that file
  installation completes user activation. No preferences hacks or unrelated IME toggles.

Release build and pre-existing PCM/hotkey/session tests passed. Actual system
activation and target-client composition remain separate acceptance checks.

## 0.2.3 — live composition and double-tap language switch

- Right Command double-tap toggles two configurable output languages (default zh-Hans/en), never the recognition language. It is disableable and does not switch during recording/model downloads.
- If hold-to-talk is also right Command, a 180ms hold threshold distinguishes it from taps. The inter-tap window is 320ms. Command+letter chords and focus changes invalidate pending gestures. This threshold means recording does not include the first 180ms of the press; start speaking when listening begins.
- Translation previews start immediately on the first nonempty partial; subsequent full hypotheses are deduplicated/coalesced, with a 120ms inter-request cadence. No per-word translation queue. The IMK target receives marked attributed text; actual client styling may vary. Final translation of the complete recognized utterance replaces the marked text once, on release.
- No general LLM correction pass has been implemented. ASR interim/final revisions and whole-utterance translation are not a guarantee of correcting proper names, numbers, or meaning. Already committed text outside this dictation is never rewritten.
- Metadata-only diagnostics now distinguish marked previews and final commits without storing recognized/translated text.
- Tests: PCM, hotkey, double-tap/hold/chord, and 14 coordinator scenarios pass. Added assertions prove preview-before-release and final-once at the fake-client boundary, not real app compatibility.

## Optional final AI editing

Default OFF. Ordinary recognition and live translation do not invoke the editor.
When explicitly enabled, the final stage receives original recognized text, its
source language, the requested target language, and the complete ordinary draft.
The configured Chat Completions-compatible endpoint is called once on release,
including for same-language editing. No microphone audio, other input-field text,
or prior committed paragraphs is read or sent by this stage.

No provider/model/credential is preselected. Remote endpoints require HTTPS and a
saved key; HTTP and keyless use are limited to loopback. Credentials are keyed by
exact endpoint in macOS Keychain, never persisted in preferences. Redirects are
rejected; the ephemeral session does not store cookies/cache. Request and response
sizes are bounded, and errors never include provider response bodies.

The eight-second editing deadline commits the ordinary draft without waiting for
an uncooperative provider. Error/empty/refusal/truncated responses also fall back.
Esc or target loss cancels rather than submitting a fallback. Late responses cannot
modify the original or a subsequent session. Polishing is not a factual guarantee;
the prompt preserves names, numbers, negation, uncertainty, and meaning.

Validation: release build, request/response validation tests without external
network, and coordinator tests for editor inputs, no pre-release call, fallback,
timeout/late response, Esc and target loss. Real provider quality/latency and Keychain
access across signed releases remain unverified until a user configures a provider.

## 0.2.5 — single system input-method icon

Removed the standalone SwiftUI MenuBarExtra and its view. The existing retained
IMKServer now runs under NSApplication with an app delegate; SwiftUI settings remain
hosted in NSHostingController. The normal settings window retains its Edit menu.
The IMK controller supplies the native input-source menu with current language,
Saylane settings (`showPreferences:`), and target-language switching commands.
Opening the installed app directly also opens settings.

The menu icon is now native 16pt PDF vector artwork: an outlined speech bubble
with three waveform strokes and transparent background, not a scaled app icon.
All three IME icon keys reference a new filename `VoiceInputMenu-v1.pdf` to avoid
reusing the old cached raster path. `scripts/generate-input-icon.swift` reproduces
the asset. Tests validate dimensions, transparent corners, and bounded ink coverage.
Application launcher icon is unchanged. Native menu appearance/action dispatch
must still be checked separately from compilation and resource tests.

## 0.2.6 — transient target-language switch feedback

A successful quick target-language change displays old target → new target in the
existing bottom-centered, nonactivating waveform panel for 1.5 seconds. It is
confirmation of the target selection, not a claim that its model is ready. This
feedback also appears when the recording waveform preference is off. No text is
inserted into the client, no microphone opens, and the panel ignores mouse input.
Repeated switches replace the current notice and restart its lifetime. Starting
recording clears the notice even when the recording overlay preference is disabled.
Identity checks plus task cancellation prevent an old expiry from hiding newer UI.

Validation: release build and all regression tests, including notice lifetime,
repeat replacement, recording priority and hide; own SwiftUI notice rendered to
build/diagnostics/language-switch-toast.png for visual inspection. Pending 0.2.5
administrator installer was cancelled before replacement; 0.2.6 incorporates both
the single-input-icon change and the notice.

## 0.2.7 — explicit first-run completion, denied-microphone recovery, icon decoding

The installed 0.2.6 TIS icon URL was confirmed to reference VoiceInputMenu-v1.pdf;
the user's black-square screenshot is therefore not explained by an old package.
The shipped menu resource is now VoiceInputMenu-v2.tiff with independent 16px and
32px alpha representations, both with a 16pt logical size. All IME icon keys refer
to that file. InfoPlist.strings now includes CFBundleName/CFBundleDisplayName as
well as the exact mode IDs, addressing the literal CFBundleName menu heading.
Resource tests check both alpha representations, ink coverage and localization.
System menu rendering still needs direct post-install verification.

Setup now starts visibly on first run or when microphone permission is absent.
The app requests undecided microphone permission only after presenting setup;
macOS consent is still the user's decision. After approval, setup proceeds to
input-source activation and model preparation. A successful actual text commit
is required to persist setupVerifiedV3. Blocked press-to-talk opens a specific
recovery step instead of a generic hidden error; granting consent never resumes
that old press. Denied access links to Microphone settings. Models may require
separate Apple download confirmation and cannot be marked ready prematurely.

Global activation remains unimplemented: existing right-Command hold/double-tap
handling is IMK-local and requires this input method to be selected. This is now
explicit in setup; microphone permission does not provide global keyboard access.
No input monitoring or Accessibility authorization has been requested implicitly.

A separate packaging defect was found: 0.2.6 had a cdhash-only ad-hoc designated
requirement. Release packaging now uses one available Developer ID Application
identity (or explicit SAYLANE_SIGNING_IDENTITY), enables hardened runtime with
audio-input entitlement, verifies the signature and rejects cdhash-only releases.
The resulting DR is identifier + Apple chain + team, not binary content hash.
This is a stable signing foundation, not evidence of cross-version TCC persistence
on all Macs and not a claim of notarization. One-time consent migration may occur.

## 0.2.8 — reduce live hypothesis latency (2026-09-07)

- SpeechEngine enables both volatileResults and fastResults for model preparation and live transcription. Apple's fastResults documentation describes a smaller context window: lower latency can reduce recognition accuracy. This is not a guarantee of word-by-word timing or a new full-audio second pass.
- SessionCoordinator no longer sleeps an additional 120 ms after each preview translation. It still serializes requests and coalesces pending input to the newest whole hypothesis, allowing corrections to replace marked text without queuing stale words.
- Added a test delivering four successive/revised hypotheses while the key remains held; each replaces marked text before release and no text commits early. Existing cancellation, target-loss and final-commit tests remain in place.
- Automated tests and Release build passed. Synthetic partial-result tests prove scheduling, not actual microphone/model latency. Real continuous-speech latency and recognition quality still require verification. TranslationSession remains a whole-response translation call, not token streaming.

## 0.2.9 — visible AI polish lifecycle (2026-09-07)

- Distinguish finalizing from polishing. Bottom nonactivating capsule displays “正在整理” or “AI 润色中 · Esc 取消”; no duplicated transcript.
- Completion feedback is emitted after commit: ordinary (AI disabled), polished, AI checked unchanged, failure fallback, timeout fallback. Success lasts 1.5 seconds, fallback warnings 4 seconds. New recording cancels notice expiry; stale notice timers cannot hide active processing.
- Diagnostics record outcome enum only, not dictated text or provider output. Existing optional HTTPS/Keychain handling and no-network-until-opted-in behavior are unchanged.
- Added coverage for all five outcomes and feedback-after-commit ordering, polishing state, notice expiry and new-session priority. Tests use fake providers; no real external model invocation was used to verify this UI change.

## 0.2.10 — failure-only notices (2026-09-07)

- Keep finalizing and AI-polishing progress in the bottom capsule. Successful commits (ordinary, polished, unchanged) now dismiss silently, with no completion toast.
- AI failure/timeout retains the specific ordinary-result fallback notice. Terminal recognition/translation errors show a short conversion-failed notice; recoverable preview errors do not prematurely announce terminal failure. Detailed errors remain in settings.
- Added tests for silent success, terminal failure expiry, AI notice priority, and cancellation of an old failure timer when a new session starts.

## 0.2.11 — swap the translation direction

User clarified that double-tap means exchanging source and target, not cycling output languages. This supersedes previous target-only behavior. English→Chinese now becomes Chinese→English, and a second swap restores it. Same-language dictation is unchanged. Removed the redundant quick-target pair selectors; existing stored source/target choices are preserved on upgrade.

Both language values are persisted before one model reconfiguration, avoiding an intermediate same-language configuration. Overlay, native menu and settings describe the actual source→target direction. Recording/model-download guards remain. Pure tests cover every language pair and reversing twice; actual speech language switching still requires live validation.

## 0.2.12 — native sidebar settings redesign

Replaced segmented navigation with a 200pt sidebar and grouped detail cards. Added real direction-swap button, compact shortcut row, switches and collapsed advanced shortcut guidance; retained permissions/model setup and all existing AI controls. Adaptive light/dark backgrounds. Default window 800×680 content, minimum 760pt width.

Release build, test suite and signed packaging passed. Installer reported success and the running window reported 0.2.12. CUA verified sidebar navigation and voice-page controls; screenshot capture failed with ScreenCaptureKit -3811, so pixel-level live visual inspection was not completed. Further UI operations stopped when user-driven window changes were detected.

## 0.2.13 — system input-source identity compatibility work

User reports black symbol in menu and caret switch indicator, plus raw bundle naming in system switch UI. Current live TIS query before patch resolves Saylane and v2 TIFF, whereas supplied screenshot still shows older menu action wording. Root cause is not yet proven; neither asset alpha tests nor TIS URLs establish actual rendering.

Add root Resources/InfoPlist.strings fallback with bundle and mode names. Set explicit development region, increment internal build to 13 (previous releases reused 9). Use a separate ICNS input-method fallback and single Retina 16pt TIFF for mode menu/palette/alternate keys, following the resource split and TIFF representation of upstream google/mozc src/mac/Info.plist and src/data/images/mac/hiragana.tiff. Artwork remains our speech outline, no third-party artwork copied. Added fallback-name and resource-key validation. This is a compatibility patch pending real system menu/caret/switch-panel visual acceptance, not a confirmed fix.

## 0.2.14 — test luminance-based system icon rendering

User screenshots after 0.2.13 still show a solid square in dark menu and empty caret badge. Name is now Saylane in provided menu screenshot. Prior transparency fixes did not solve the visual defect.

Comparison: our v3 TIFF has 582 fully transparent pixels with black RGB and black artwork; upstream Mozc hiragana TIFF has 992 fully opaque pixels out of 1024. Hypothesis: system template conversion consumes RGB/luminance rather than the alpha-only shape. New v4 mask explicitly encodes black artwork on opaque white; all parent/mode/palette/alternate references use this mask. Added luminance contrast assertions instead of treating alpha transparency as acceptance evidence. This is a targeted hypothesis pending actual system rendering; don't call it confirmed from build/tests alone.

## 0.2.15 — revert incorrect opaque-mask change, add actual template rendering regression

After user reported v4 still broken, ran a five-way SwiftUI ImageRenderer template comparison on original PDF, v3 transparent TIFF, v4 opaque TIFF, installed resource and Doubao reference. Saved build/diagnostics/template-comparison.png. v4 and installed resource reproducibly render as white squares; v1/v3 retain silhouette. This disproves v4's luminance hypothesis. Does not explain all earlier system-cache/rendering behavior.

Restored transparent single-Retina artwork under VoiceInputTemplate-v5.tiff for all input-source icon keys. Removed opaque-mask generation. Regression test now renders the icon in template mode, asserting visible silhouette and transparent corners, not merely decoding or comparing luminance. System menu/caret verification remains distinct from renderer test. Previous TextInputMenuAgent restart produced PID42521 yet v4 remained broken; do not claim restart alone fixed it.

## 2026-09-07 follow-up — isolate all three system UI owners before another package

User screenshot after v5 shows an unattractive white-backed bubble and reports caret icon still wrong. Installed v5 resource is alpha-transparent; screenshot white backing differs from the file. Not proof of caching, but UI processes had persisted across asset versions: CursorUIViewService since Sep3, TextInputSwitcher since Sep5, TextInputMenuAgent since v4. Sent TERM only to these exact current-user processes (959,41571,42521), preserving settings and other IMEs. System visual outcome not yet confirmed.

Added scripts/generate-waveform-icon.swift to render an uncluttered five-bar 16pt alpha waveform candidate, with light/dark template preview at build/diagnostics/waveform-candidate-preview.png. Candidate is diagnostic-only; no new package installed and no production icon keys changed during this follow-up. Do not mistake its preview for a screenshot of the system menu or caret UI.
Read-back showed only TextInputMenuAgent restarted; CursorUIViewService and TextInputSwitcher retained original PIDs after TERM. Sent KILL to those exact current-user UI-service PIDs after confirming they ignored TERM. No input-method host or settings service terminated. Need subsequent PID/visual verification.

## 0.2.16 — user-approved five-bar waveform replacement

Wired scripts/generate-waveform-icon.swift into Sources/Resources/VoiceWaveformTemplate-v6.tiff; updated every parent/mode menu/palette/alternate icon reference. Kept transparent 16pt silhouette, no bubble border. Full tests (including white template rendering), Release build and signed package passed. Installer succeeded; installed resource SHA256 exactly matches source, and TIS parent/mode URLs resolve v6. Requested TERM of the current user's three input UI services to refresh caches. No changes to voice/translation processing. Actual light/dark system-menu and caret appearance still require live visual verification; native renderer preview is not that proof.
PID read-back showed switcher46684 and cursor46787 retained pre-install start times after TERM; ended these exact current-user UI processes with KILL, as they ignored TERM. Menu agent restarted as47371.

## 0.2.65 — 听写修正与个人词库（Typeless 式准确率 / 纠错，2026-09-17）

目标是接近 Typeless 的"说什么就写对什么"，而不是让 AI 重新组织内容。全部默认在本机同步完成，不依赖网络，对实时预览和最终结果一致生效。

- `Sources/Services/DictationCleanup.swift`：确定性文本修正，对每次 partial 和 final 都运行。
  - 标点归一：中文语境把 `,?!;:.` 转全角、去掉汉字间空格、合并重复标点、去掉首尾悬空逗号；英文补齐逗号后空格并修句首大写。不碰 `3.5`、`gmail.com`。
  - 口头填充：句首/子句首的「嗯、呃、唔」直接删；「那个，」「啊，」「就是说，」只在作为独立引导语时删（「那个东西」「额度」不受影响）。英文删 `um/uh/er/hmm/ah` 及其两侧因停顿产生的逗号；`I mean` 不当填充词处理，留给纠错。
  - 口吃重复：中文三连字、代词/虚词二连字、带逗号的同字重复（「我，我想」）、常见双字词重复（「我们我们」）；保留「看看」「谢谢」「研究研究」等合法重叠。英文合并连续重复单词，`had had`、`that that` 等二连保留。
  - 自我纠正：「不对，X」「不对不对，是 X」「说错了，X」「不对我是说 X」以及 `no, I mean X` / `scratch that, X`，用 X 改写前一子句。对齐策略依次为：前缀锚点（去北京→去上海）、后缀锚点（三点开会 ← 四点）、等长尾替换（北京→上海）。「不是 A，是 B」只在 A 确实出现在前文时才替换。标记词必须处于子句边界且后跟逗号或「我是说」类短语，因此「不对称」「这个答案不对，我们再看看」「你听我说」不会被改。句首没有可改对象时不动。
- `Sources/Services/DictationVocabulary.swift` + `SpeechHotwords.entries`：个人词库对所有引擎生效。
  - 词条格式 `写法|常见误听1|误听2`（如 `Saylane|赛兰|塞蓝`）。首项为标准写法，同时作为 Apple `AnalysisContext.contextualStrings` 和 Qwen prompt 的识别偏置；FunASR 两个 CLI 没有热词参数，只靠识别后修正。
  - 中文按逐字拼音匹配（`CFStringTransform`，zh/z、ch/c、sh/s、n/l、ing/in、eng/en、ang/an 模糊），标准写法比对带声调（「微信」不会吞掉「为新」），误听别名不看声调。单字词不按音匹配。
  - 英文按去空格小写键比对，≥5 字母容忍 1 处、≥9 字母容忍 2 处编辑距离，允许被拆成两个词（`say lane`）；带后缀的词（`cursors`）和多词候选不做模糊匹配。
- `SessionCoordinator.start(refine:)`：新增同步 `refine` 钩子，先于翻译和 AI 润色对 partial/final 生效；修正后为空则仍提交原识别结果。
- `FinalPolishService`：同语言时切换为 `dictationInstruction` 校对提示（只改同音错字、口误、标点，不改措辞），请求体新增 `vocabulary` 字段；翻译提示也补充了口头纠正与词库要求。默认仍关闭，作为规则修正之上的可选增强。
- 设置：原「AI 润色」页改为「AI 修正」，集中所有识别后修正：本地修正（「自动修正口误」默认开，键 `dictationCleanupEnabled`；「个人词库」沿用 `speechHotwordsEnabled/speechHotwords`）、大模型校对开关（语音 `finalPolishEnabled`、截屏 `screenPolishEnabled`）和共用的模型连接。「本地模型」页的 Qwen 热词和「截屏翻译」页的润色开关都并入此页。
- 测试：`Tests/DictationCleanupTests.swift`、`Tests/DictationVocabularyTests.swift` 已加入 `scripts/test.sh`；`SessionCoordinatorTests` 新增 refine 用例；`FinalPolishTests` 覆盖校对提示与 vocabulary 字段。
- 已知边界：无锚点且长度不同的替换（「明天下午三点，不对，四点半」）只能按等长尾替换，结果可能不理想；这类情况开启 AI 校对可兜底。所有规则均未做真人语料 WER 评估。

## 0.2.66 — 校对不再被「仅识别」跳过、改写保护、设置控制台（2026-09-17）

- 用户诊断：偏好里 `recognitionOnly = 1` 导致 `finalPolishEnabled = 1` 也从不请求模型（日志只有 `completion ordinary`，无 `polishing`）。现在「仅识别，不翻译」只跳过翻译；大模型校对只听自己的开关。
- SenseVoice 的"边说边出字"是对累计音频的反复整段重解码，各次结果互不约束，松手后的完整解码也可能与最后一次预览不同；这是引擎特性，Apple 真流式不会整句翻转。已在对话中向用户说明，文档记录于此。
- 改写保护：同语言校对返回后，用去标点/空白的字符编辑距离和长度比检查（长度比 0.5–1.6，距离占比 ≤ 0.45）；不通过则抛 `PolishRejected`，提交本地结果并提示「AI 改动过大 · 已保留本地结果」（`CompletionFeedback.polishRejected`）。翻译模式不做此检查。
- 设置窗口改为固定深色控制台风格（`Theme.Console` 调色板，`SettingsCard/SettingsRow/StatusChip/InfoTip/Eyebrow/ConsoleFieldStyle` 组件）：长说明收进 (i) 弹层，标题栏加 MIC/IME/MODEL/WAKE 状态灯，侧栏带编号与 READY/KBD/ASR 遥测，「AI 修正」页顶部用 ASR → RULES → VOCAB → LLM → COMMIT 流水线展示各级开关状态。候选条与 HUD 仍跟随系统外观。
- Debug 工具：`--snapshot out.png all` 渲染五页；`--preview-models --preview-tab N` 打开真实窗口，`--preview-shot dir` 逐页写出 `settings-N.png`。

## 0.2.68 — 设置窗口不再把输入法变成前台应用（2026-09-17）

安装后 `--setup` 会打开「开始使用」窗口，并曾把宿主切成 `NSApplicationActivationPolicy.regular`。Launch Services 随后把 Saylane 报成 Foreground 应用：菜单栏仍勾着 Saylane，但很多目标软件不再调用 `activateServer`，拼音和语音一起失效。设置窗口现在始终保持 accessory，关闭后也回到后台输入法。

## 0.2.67 — 设置界面回到系统设置（2026-09-17）

0.2.66 的深色控制台（等宽英文码、状态灯、网格、流水线胶囊）观感过重。设置窗口改为 `NavigationSplitView` + 分组 `Form`，跟随系统外观，长说明放在页脚和 tooltip，不再单独做一套视觉语言。功能与 0.2.66 相同：仅识别不再跳过校对、改写保护、AI 修正集中配置。
