# Qwen3-ASR 0.6B 本地识别

更新：2026-09-08。

## 产品边界

- 默认仍是 Apple 系统识别。设置 → 本地模型，提供 4-bit / 6-bit 两个独立可选下载项。
- 用户主动点击下载，完成后点击使用；不会在首次启动、切换输入法或录音时下载权重。
- 首版是最终稿识别：按住说话、松开后识别。没有伪装成原生流式，不输出模拟 partial。
- 单次最多 30 秒，超过时明确取消并报错，不截断后悄悄提交。后续长语音分段不在本轮范围。
- 两种量化都覆盖应用当前的中（简繁）、英、日、韩、法、西、德语言选项。中文按用户选择转换简繁字形；不是地区词汇本地化。
- 同语言直接输入；跨语言仍走现有 Apple 翻译；可选 AI 润色、目标绑定、取消保护、最终仅提交一次均复用现有 SessionCoordinator。
- 语音在本机识别。用户启用现有 AI 润色时，文字仍会按其润色配置发送给对应服务，不能因此宣称整个输出流程必然离线。

## 下载内容与来源

| 版本 | 完整下载字节数 | 来源快照 |
|---|---:|---|
| 4-bit | 724,209,413（约 724 MB / 691 MiB） | mlx-community/Qwen3-ASR-0.6B-4bit @ 313d850181767edf09f00a9c289becca70e58cd0 |
| 6-bit | 873,205,701（约 873 MB / 833 MiB） | mlx-community/Qwen3-ASR-0.6B-6bit @ 468b9b6d692d3397d5d17b84a1166876a00c9bfa |

这是社区转换的 MLX 量化权重，不是 Qwen 官方原始精度权重。
Swift tokenizer 还需要 tokenizer.json，来自官方 Qwen/Qwen3-ASR-0.6B-hf
@ 7f1569a48a89f3e3f4dc3a5c9d28bddd903bc76c；已逐项核对 vocab 与 62 个 added token 的 ID/内容
与量化包一致。上述大小包含这个文件（11,429,653 字节）。

清单位于 Sources/Resources/ASR。每个文件固定来源、revision、长度与 SHA256；仅 HTTPS。
模型存储于 ~/Library/Application Support/RTranslate/ASRModels/<variant>/<revision>，不在 .app 内。

下载流程：空间预检 → 版本级进程锁 → .partial 暂存 → 分文件校验 → 完整标记 → 目录落盘。
取消/网络中断不产生已安装状态；重试复用已完整下载且重新校验通过的文件，不承诺单个大文件断点续传。
加载前再做全量 SHA256 校验；已安装模型有重新下载修复、删除入口。删除当前模型会切回 Apple。
删除不触碰另一量化版本、翻译资产或用户其他设置。两份权重可同时保留，但运行时只缓存当前一种。

scripts/assert-no-model-weights.sh 是打包门禁，检查 .app 内没有 safetensors/GGUF/ONNX/PyTorch 权重。
应用仍需包含 Swift/MLX/Metal 推理运行库，不能把“无模型权重”解释为安装包完全不增大。

## 接入架构

- SpeechModel：两个固定清单、语言映射和简繁转换。
- ASRModelInstaller / ASRModelStore：下载、进度、取消、重试、校验及删除。
- QwenRuntime / LocalSpeechRuntime：串行管理单一模型生命周期，合并重复准备请求，生命周期 Task 不持有模型返回值。
- QwenWorkerModel：通过当前应用可执行文件的私有 `--qwen-worker` 模式启动独立子进程，用 stdin/stdout 传递有界 PCM 和结果。无监听端口、无录音临时文件；子进程不注册输入法、不显示窗口。
- 模型加载、预热与推理仅在子进程执行；切回 Apple 时先回收子进程，再等待其他翻译模型准备。4/6-bit 互切先回收旧进程再启动新的，避免双份权重同时驻留。
- QwenSpeechEngine：实现 SpeechRecognizing；只接收内存 PCM，不保存录音或转写历史。
- QwenAudioBuffer：复制并转换成 16 kHz / Float32 / 单声道；30 秒有界缓存。
- AppModel：通过所选模型创建后端。准备失败不自动发到云端，不假装就绪。

运行库来自 ontypehq/mlx-swift-asr，固定源码 revision 见 Vendor/MLXASR/UPSTREAM.md。
上游依赖 main 已转向 Swift 6.3，因此 vendor 约 108 KB 运行源码并固定可兼容 Xcode 26.2 的依赖。
没有 vendored 权重。所有许可证见 Sources/Resources/ThirdPartyNotices.txt 和上游 LICENSE。

## 构建与验证

- Xcode 26.2 / Swift 6.2，macOS 26+ / Apple Silicon（本轮不扩展旧系统或 Intel）。
- MLX 构建需要 Metal Toolchain：`xcodebuild -downloadComponent MetalToolchain`（仅开发机）。
- `make build` 使用 scripts/generate-project.sh 恢复固定 Package.resolved。
- `make test` 包含清单/哈希/取消/安装状态/语言/音频转换/30 秒上限以及原有 coordinator 回归测试。
- 显式诊断下载：`RTranslate --download-speech-model qwen3-asr-0.6b-4bit`（或 6bit）。
- 文件识别：`RTranslate --recognize-file /absolute/path/audio.wav zh-CN --speech-model qwen3-asr-0.6b-4bit`。
  不传 --speech-model 时诊断仍用 Apple。仅此显式文件诊断打印转写文字。
- Debug 专用 `--preview-models` 展示真实设置视图，但不注册 IMK server，也不启用全局热键。

构建/文件样本测试不等于跨 App 真实输入验收；实时麦克风、目标切换、Esc、中文→英文输入以及长时间运行需分别记录。

## 上游资料

- https://github.com/QwenLM/Qwen3-ASR
- https://github.com/ontypehq/mlx-swift-asr
- https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-4bit
- https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-6bit
- https://huggingface.co/Qwen/Qwen3-ASR-0.6B-hf

## 本轮验证记录

- Debug 构建通过；模型管理单测通过：固定来源与尺寸、同尺寸文件损坏检测、半成品不可选、取消、拒绝坏下载、符号链接、语言映射、PCM 复制/重采样和 30 秒上限。
- 两份权重的 SHA256 均与清单一致。开发验证中对大权重使用同源分段传输后交给应用安装器复验；UI 的 6-bit 安装流程、修复下载实时进度（观察到 66 / 873 MB）、取消后保留已安装模型均已实测。
- 真实设置窗口已验证 4-bit、6-bit 选择/加载就绪以及切回 Apple；已检查原生窗口布局。预览不注册第二个 IMK server，不修改现有安装。
- 官方 asr_zh.wav（4.20 秒 / 16 kHz）两版均输出：`甚至出现交易几乎停滞的情况。`
- 官方 asr_en.wav（15.05 秒 / 48 kHz / 24-bit PCM）两版均输出连续英文句子，结果略有口头词差异；这不是 WER 排名或大样本精度结论。
- 4-bit 一秒纯静音输出空文字（诊断返回 1，正常空结果语义），不产生幻觉提交。
- 文件诊断均为 `partials=0`，符合最终稿后端的约定。冷启动/预热包含在进程耗时中，不以这些数字承诺交互时延。
- 未验证真实麦克风跨 App 输入、长时间内存稳定性、打包签名/安装升级；此项为发布前的开发验证。
- 最终 `make test` 全部通过，Debug / Release 构建通过；Release 运行同一中文样本时两个版本均返回上述文字。
- Release `.app` 的本机 `du -sh` 结果约 45 MiB（不是 PKG 下载大小）；打包门禁确认没有可选权重，且对伪造的带权重测试包确实返回失败。
- UI 回归发现 async convenience download 的文件内进度没有上报，已改用 delegate 驱动下载，并复验 66 / 873 MB 的实时进度及取消恢复。

## 内存生命周期与卡顿验证（2026-09-08）

- 仅将 Swift 模型引用置空并清理 MLX cache 不够：初次实测 MLX active 降到约 0.13 MB 后，主进程仍有明显总内存残留。因此最终采用独立 worker 隔离整个 MLX/Metal/tokenizer 生命周期，而不是把 MLX 计数当成进程内存已回收的证明。
- 选择千问期间保持当前模型热启动；不每句话卸载重载。识别完成后清理临时 MLX 缓存，复用缓存上限 128 MiB（不是总内存上限）。
- 切回 Apple、删除当前模型或替换量化版本时，释放 worker owner，终止并等待该进程退出。正常仅用 Apple 的用户不会启动识别子进程或初始化 MLX。
- 取消/失败的推理会使当前 worker 失效并回收，下次准备重新加载。加载/推理 IPC 有 120 秒兜底超时；超时终止 worker，不无限等待。主进程关闭后 worker 从管道读到 EOF 会退出。
- 生命周期测试覆盖重复准备合并、取消单个等待者、推理期间切换/卸载、20 次快速 4→6→卸载、旧加载不复活，以及释放时模型对象数量归零。
- 显式诊断：`RTranslate --asr-memory-check /absolute/path/audio.wav`。仅使用已下载模型，不更改偏好；两轮加载/识别/释放，并检查每个 worker PID 确实消失，另测加载中断后的恢复。诊断输出内存和时延，不输出录音文本。

本机 Apple M3 Max / 36 GiB，Debug 构建，官方 4.20 秒中文音频，两轮测量：

| 指标 | 4-bit | 6-bit |
|---|---:|---:|
| worker 加载后物理占用 | 约 1.04 GiB | 约 1.18 GiB |
| 加载、校验及预热 | 1.98–2.40 秒 | 2.04–2.26 秒 |
| 已加载后的识别（含 IPC） | 0.22–0.26 秒 | 0.23–0.26 秒 |
| 结束并回收 worker | 0.06–0.07 秒 | 0.04–0.14 秒 |

释放后 worker 均已退出；诊断父进程从约 7.1 MiB 到约 10.6 MiB，MLX active/cache 始终为 0，没有把 GB 级权重留在父进程。父进程数字是无 GUI 的诊断模式，**不是完整输入法 + Apple 识别/翻译的总占用**。上述数值不是低配设备、首次系统 shader 编译或长录音的性能承诺；真实麦克风、跨 App 输入和长时间运行仍需独立验收。

最终 Release 回归补充：连续三次运行两轮模型生命周期诊断均通过，每次卸载都检查旧 worker PID 已不存在；加载中途卸载后可正常加载另一量化版本。Release 的 4.20 秒样本识别约 0.13–0.15 秒，加载/校验/预热约 1.1–1.4 秒，进程回收约 0.03–0.06 秒。两版文件转写均维持正确结果。另测真实 worker 推理取消并确认其退出。

进程退出等待使用 `terminationHandler` 通知，避免跨 Swift executor 线程使用 Foundation `waitUntilExit` 的 RunLoop 等待问题；取消回调只发送终止信号，不在 UI 调用线程等待退出。IPC 小消息不等待填满缓冲区或 EOF 的回归测试通过。最终 Release 构建与无权重打包门禁通过，完整原有单测及新增生命周期/IPC 单测通过；此阶段未签名发布或替换已安装输入法，发布验证见下文。

## v0.2.46 发布验证

- 版本号与 build 为 0.2.46 / 46，PKG 不含 4-bit / 6-bit 权重。
- 包内应用采用 Developer ID Application 签名、Hardened Runtime 与可信时间戳；严格签名校验通过。
- 对打包暂存目录中的实际已签名应用验证：两个量化版本文件识别、worker 内存释放、加载中断恢复和推理取消。
- 保持上一版发布边界：PKG 安装器本身未签名，未完成 Apple 公证；不保证免安全提示安装，不建议关闭安全保护。
- 本次发布不安装或替换开发机正在使用的输入法；真实麦克风、跨 App 输入和长时间运行仍不属于此次验收结论。

## v0.2.47 发布说明

- 修复点按说话与双击切换源语言/目标语言的快捷键冲突：当点按模式使用右 Command 时，第一次点击先进入双击判定窗口，双击优先切换语言，确认单击后才开始录音。
- 录音中的点击仍用于结束录音；其他快捷键与重置焦点会取消待处理的单击。
- 单击因此增加约 320ms 的判定等待；使用其他语音快捷键时不增加该等待。
