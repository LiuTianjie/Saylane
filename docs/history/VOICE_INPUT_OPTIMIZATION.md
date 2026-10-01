# 语音输入体验优化（2026-09-20）

本轮落地实时显示、终稿收尾和可重复评测；沿用现有 Apple / Qwen / SenseVoice / Fun-ASR 模型，不改变模型选择、快捷键、翻译和润色开关。

## 中间稿与终稿

- 识别接口传 `SpeechHypothesis(stableText, volatileText)`，Apple 的最终片段与可修订末尾分别传递。本地批量模型全部标为可修订，不凭“出现两次”虚构稳定结果。
- 第一条非空识别结果立即显示；之后同一 80 ms 窗口内只显示最新结果。使用固定刷新截止点，持续说话不会不断重置计时而饿死预览。
- 预览直接使用识别结果，不做删口头禅、口误合并、同音词替换。`makeRefine` 仅在最终识别成功后执行一次，再进入原有翻译/可选润色。
- 所有内容仍由原会话绑定的 IMK 目标持有 marked text；稳定段不提前上屏，Esc 可以取消整次输入。取消/松手/目标丢失会丢弃待刷新的预览。
- 保留原有终稿规则整理能力；这次只是移出不稳定的中间稿，未宣称现有规则具备可靠的语义理解能力。

## 本地识别收尾

- 将推理运行时构造移到 `QwenRuntime.swift`，`QwenSpeechEngine` 接受注入的运行时，可以真实测试调度而无需加载 GPU 权重。
- 收尾立即取消空闲的预览轮询，不额外等 280/450 ms。
- 保存最近成功识别的音频样本数及结果。只有结果非空且样本数与最终录音**完全相等**，才直接复用。仍在运行、但覆盖完整录音的推理也可复用；多出一帧就必须重新识别，避免丢句尾。
- Native CLI 可以中断旧前缀；Qwen 必须排空在途预览，避免为了收尾杀掉常驻模型。取消会话会使旧结果失效；取消后的 Qwen worker 不再被视为已就绪，下次输入重新加载。
- 全静音/近机器零值的录音不发起预览推理；这不是语音活动检测或降噪，不会按普通环境音量阈值裁掉轻声。
- Apple 文件回放实测发现全零 PCM 被识别成 `you`。增加覆盖各 PCM 格式的全零检测：全零输入不展示假设、不接受终稿；任何非零微弱信号仍交给 Apple 识别，不按响度剪裁录音。
- 这仍是累计录音的批量重识别，不是增量流式。30 秒单次本地录音限制仍保留；长语音分段需要独立的边界与上下文验收。

## 日常诊断

每个会话只写一次 `speech-metrics` 汇总，包含模型、结果状态、音频时长、预览次数、修订字数，以及以下相对会话开始的单调时钟毫秒值：

`captureStarted`、`recognizerReady`、`firstAudioFed`、`firstHypothesis`、`firstPreview`、`released`、`recognitionFinished`、`committed`、`ended`。

差值 `committed - released` 是松手到上屏，包含已启用的翻译/润色；`recognitionFinished - released` 更接近识别收尾。首次结果从会话触发计时，不是从真实语音起点计时（目前没有 VAD 起点标注）。缺失阶段保持缺失，不能当成 0 ms。

日常诊断不写录音或转写文本；不再逐条预览同步写磁盘。元数据合并后在独立 actor 写盘，保留最近 60 条事件。

## 录音回放与准确率评测

显式命令使用指定文件，不开麦克风、不切换输入源、不发起云端请求：

```bash
build/Build/Products/Debug/Saylane.app/Contents/MacOS/Saylane \
  --recognize-file /absolute/path/sample.wav zh-CN \
  --speech-model sensevoice-small-q8 --realtime --asr-repeat 2 \
  --asr-report /absolute/path/report.json
```

`--realtime` 按音频时钟回放，缺省则尽快送入。报告含转写文本、模型准备时长、回放开始到首个假设、最后一帧送完到终稿、修订字数。重复在同一进程进行，可以区分首次使用和后续使用；不要把后续使用都标成“常驻模型热启动”，Native CLI 仍每次启动进程。

语料 JSON 格式：

```json
[
  {"id":"mixed-001","audio":"audio/mixed-001.wav","reference":"把 React Native 组件改一下。","locale":"zh-CN","terms":["React Native"],"category":"mixed-language"},
  {"id":"silence-001","audio":"audio/silence-001.wav","reference":"","locale":"zh-CN","category":"silence"}
]
```

音频路径相对语料 JSON 所在目录；`reference` 应由人工核对，不能拿模型自己的输出当准确率真值。

```bash
python3 scripts/benchmark-asr.py \
  --app build/Build/Products/Debug/Saylane.app \
  --corpus /absolute/path/corpus.json \
  --models apple sensevoice-small-q8 qwen3-asr-0.6b-4bit \
  --repeat 2 --output build/asr-benchmark
```

报告为 `results.json`：逐条结果与 CER、完全匹配率、术语召回、静音误识别次数，以及 p50/p95。CER 统一 NFKC/大小写并忽略标点与空白；保留文字与数字差异。静音样本单独统计，不用零分母稀释 CER。没有首字的样本不伪造 0 ms；执行失败单独计数。

建议真实语料覆盖短句、连续口语、自我纠正、数字日期、专业词、中英混输、轻声、噪声、不同麦克风，以及 1/5/15/30 秒长度。开发样例仅验证链路，不能据此判断对齐豆包或排列模型准确率。

## 验证

- `make test` 全部通过，包含 32 组会话场景、13 组本地识别场景、8 种 PCM 格式/布局的静音与微弱信号检查，以及运行时生命周期、评测计分和原有拼音回归；Debug 构建通过。
- Apple / SenseVoice / Qwen 4-bit 各使用已有 4.2 秒中文和 1 秒静音开发样例，按真实音频速度回放，每条两轮；中文终稿均保持原句。报告在 ignored 的 `build/voice-audit/benchmark`。
- 这条中文样例的识别收尾观察值：Apple 约 25–42 ms，SenseVoice 约 155–157 ms，Qwen 约 240–243 ms；不包含模型准备、翻译、润色和 IMK 上屏，不是大样本 p95，也没有据此宣称相对旧版的速度提升。
- 首轮回放发现 Apple 全零静音两轮都输出 `you`；增加保护后，两轮均无预览、终稿为空，中文样例仍正确。修复后 Apple 报告在 `build/voice-audit/benchmark-apple-silence-fix`，保留前后证据。
- 未更换系统安装；微信、浏览器、编辑器中的实时麦克风与 IMK 手感需要安装后验收。纯文件回放不包含麦克风启动、用户语音起点及跨应用上屏耗时。
