# 字重小模型原型实测

2026-09-17。结论：模型体积和原生推理速度可行；准确性尚不足以默认接入。原型已训练、转换成 Core ML、运行真实截图与独立原生测试，并导出实验译图；0.2.61 安装包没有该模型；后续应用户要求接入 0.2.62 实验功能，见文末。

## 实现

- 输入是 OCR 原图文字区域，不输入识别文本、是否标题、数字前缀等语义特征。
- 原图边缘估计底色和明暗极性，裁出字形，保持横纵比例将字形高度归一到 24 像素，再取最多三个 32×128 小块。
- 三层卷积网络，17,970 个参数，只训练 regular / bold 二分类。0.1～0.9 分数作为不确定区；分数未做概率校准，不能解读成真实错误概率。
- 一行取三个小块粗体分数中位数。当前不支持同一行内不同字重的逐词还原、独立 medium 类、字体家族或字号回归。
- 使用 Core ML 原生运行，无需在应用中携带 Python、PyTorch 或 ONNX Runtime。开发依赖仅在 ignored build/font-weight-py312 中。

## 训练与泛化验证

第一轮采用 Pillow 生成 8,000 个样本。虽然未参与训练字体的合成测试表现很好，但真实 macOS 渲染和用户截图误加粗严重，所以未采用该轮权重。

第二轮使用 CoreText/NSFont 生成 7,600 个样本：6,000 训练、800 验证、800 留出字体测试。常规/粗体，12～48 像素字号，浅色/深色背景；训练加入缩放和模糊。训练字体包含 Arial、Times New Roman、Courier New、Tahoma、Trebuchet MS、Helvetica、PingFang SC；留出字体包括 Georgia、Verdana、Avenir Next。根据验证集选择 12 轮中的最佳权重。

用户截图没有进入训练集。第二轮是在发现第一轮原生测试失败后改进的，因此已看过的真实样例应视为开发集，不能当作未触碰的最终测试集。中文只有一个字体家族，不能宣称中文字体泛化已验证。

- 新文本验证集：98.0% 二分类准确率，800 个原生合成样本。
- 留出字体集：100% 二分类准确率，800 个原生合成样本。这不是截图总体准确率。
- 独立的系统字体测试图：20 行，包含中英文、浅/深色背景、14～30 像素字号。15 行明确判断正确、3 行不确定、2 行粗体误判为常规；没有常规误判粗体。仍不达标。

## 用户截图

- Codex for Open Source：13 个原始 OCR 行均判断为常规，包括 `6 months…`；没有基于数字或短句推断粗体。原图标签按提供的视觉内容人工判定，没有原网页 CSS 元数据。
- 论文：49 行中 47 regular / 2 bold；Introduction、Model Architecture 检出粗体，Background 被漏判。
- X：96 行中 78 regular / 13 bold / 5 uncertain。Home、Subscribe to Premium 和 What's happening 等检出粗体，但部分新闻粗体标题漏判。没有人工标注整页，不能给出整页准确率。
- 聊天：34 行中 31 regular / 0 bold / 3 uncertain。包含侧栏和中英文混排，尚未完整人工标注，不能认定全图通过。

离线实验预览通过 `SAYLANE_FONT_WEIGHT_EXPERIMENT` 读取预测结果，仅存在于 Tests/ScreenTranslationPreview.swift。生产应用不读取该变量。字号和位置仍由现有排版计算，只有高分或低分预测替换字重；不确定保留原样。该实验预览不等于已集成应用。

## 体积与耗时

- FP16 权重文件：36,672 字节；mlpackage 在当前文件系统占用约 52 KB。不是安装包增量测量。
- Core ML CPU，Codex 页面 39 个小块：加载约 26.9 ms，首次预测约 6.6 ms，预热后中位数约 3.1 ms。
- Core ML CPU，X 页 288 个小块：加载约 22.9 ms，首次预测约 26.3 ms，预热后中位数约 22.1 ms。
- 上述模型预测时间不包含 OCR、裁图归一化、UI 更新，也不是完整首屏延迟。每个场景 1 次首次预测 + 11 次预热运行，中位数不称 p95。
- 编译模型耗时在 benchmark JSON 单列记录；正式应用应打包编译后的模型，不在每次截屏时编译或加载。
- Torch 与 Swift/Core ML 原生的 327 个小块 argmax 一致；最大 logit 差约 0.0109。转换库提示 PyTorch 2.7.1 不在其官方测试版本中，已用实际输出核对，未据此宣称其他平台一致。

## 文件与复现

源码：
- scripts/font-weight/experiment.py：训练、转换、截图推理。
- scripts/font-weight/report.py：原图字形与预测的 HTML 对照。
- Tests/FontWeightTrainingSamples.swift：带真实字体标签的原生训练数据生成器。
- Tests/FontWeightNativeFixture.swift：独立系统字体对照图。
- Tests/FontWeightCoreMLBenchmark.swift：独立 Swift/Core ML 推理与计时。

结果均在 ignored build/font-weight：training.json、conversion.json、native-parity.json、evaluation-summary.json、coreml-*.json、review.html、FontWeight.mlpackage、translated-open-source/translated.png。第一轮结果保存在 pillow-first。字体文件本身未复制入模型或应用，用户截图未上传。

使用 Python 3.12 虚拟环境，安装 torch==2.7.1、coremltools==8.3.0、Pillow、numpy；本机解析后的依赖版本在 build/font-weight/requirements-resolved.txt。先用 `swiftc -parse-as-library -framework AppKit` 编译并运行训练样本生成器，再执行 `python scripts/font-weight/experiment.py train-native`。原生 fixture 同样编译运行；eval 子命令参数是原图路径、OCR 文本坐标文件、输出名称。

## 下一步

优先补充小字号、抗锯齿与 OCR 边界扰动样本；建立新的、未用于开发选择的真实截图标签集。加入字形渲染比对，验证是否能修正小字号粗体漏判，而不是继续添加数字/标题规则。必须同时测普通文字误加粗率和真实粗体召回率，不能通过“全部判常规”取得好看的单张结果。准确性过关后再把预处理搬到 Swift，并测整条流水线增量耗时与内存。

## 0.2.62 安装试用版

用户明确要求将原型接入最新版安装包。模型现已进入截图 OCR 后、段落分组前的正式流程。设置 → 截屏翻译 → 本地字重识别（实验），默认开启，可关闭，下次划选生效。不确定结果及模型失败回退到原有样式；仍可能漏判小字号粗体，不宣称准确性已全面达标。

- ScreenFontWeightService actor 将裁图、归一化与 CPU 推理放在主线程之外；模型只加载一次。取消逐行/逐小块检查，控制器仍检查 generation，避免过期截图结果更新界面。
- 每行保留模型分数，段落取中位分数；仅改变显示字重，不改变标题分组身份、字号或源图位置。
- 原生 Swift 预处理与离线 Python 对照：四张用户图片合计 192 行的 regular/bold/uncertain 决策全部一致。最大分数差约 0.00345。
- 包含裁图、归一化、Core ML 的重复调用实测：Codex 13 行约 10.2 ms；X 96 行约 54.9 ms；论文 49 行约 46.7 ms；聊天 34 行约 23.2 ms。首轮含加载分别约 40.3 / 105.7 / 80.9 / 59.4 ms。这些是单次采样，不是 p95。
- 模型通过 Xcode 编译为 FontWeight.mlmodelc 随包分发，不在用户机器运行 Python 或训练程序，也不另行下载模型。
- 集成检查包含实际推理、离线决策对照、缺失模型回退、重复运行稳定性、段落显示字重传播。脚本 scripts/test-font-weight.sh 可复现。
