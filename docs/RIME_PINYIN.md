# Rime 拼音内核接入（2026-09-09，0.2.52）

## 架构

生产输入链路：

```
InputMethodKit / AppModel
  → PinyinEngine（现有 UI、语音快捷键互斥）
  → RimePinyinSession（按键适配、中英模式、候选高亮）
  → SaylaneRime.c（librime 版本化 C API、内存所有权）
  → librime 1.17.0（音节切分、组词、排序、选词、用户词库）
```

- 候选窗保留现有 9 候选一页、展开、点击、数字选择、方向键和翻页交互。
- 组词与候选选择均使用 Rime session。没有用旧 Swift 解码器再次排序，也没有初始化失败时静默回退到旧引擎。
- 原 `PinyinSession` / `PinyinDecoder` / `PinyinLexicon` / `PinyinLanguageModel` / `PinyinSyllable` 仅保留历史回归源码，已经从应用 target 排除；旧 TSV 不进入 app bundle。
- 运行时调用在输入法主线程串行执行；Rime 返回的文本在桥接层复制，原生 context、commit 和 iterator 均及时释放。
- `applicationWillTerminate` 结束 Rime service，关闭用户词库。跨进程测试验证选词学习可以恢复。

## 数据与运行时

- `Vendor/Rime/dependencies.lock.json` 固定 librime 1.17.0 官方 macOS universal archive、雾凇词库和 rime-essay 的版本与 SHA-256。
- 词库采用雾凇 `8105`、`base`、`ext`、`others` 四个表；不复制鼠须管前端，也不加载雾凇整套 Lua 配置。
- `scripts/rime` 是 Saylane 自己的轻量 Rime 配置。标准/模糊音两套 prism 共用词典及 `saylane` 用户词库；模糊音在精确翻译器之外附加一条统一降权路径：任意模糊对（z/zh、an/ang、in/ing 等）都保持精确拼写的首选，模糊结果只作补充。 中文模式另挂英文词表和 echo：词典英文可进候选，未收录字母串仍可原样选择；拼音首选仍是中文。
- 没有搭载额外神经语言模型、octagram、Lua、predict 插件。整句能力来自 Rime 的 script translator 和配套词典，不声称已接入这些扩展。
- 词后联想暂不支持，设置页已明确提示，不再展示无效开关。保留原联想偏好值，方便以后增加该能力。
- 拼音运行不发送网络请求。首次源码构建会下载固定依赖，日常输入不下载或编译词库。
- 原生 dylib 内部依赖检查只允许 macOS 系统库。app 内嵌 `@rpath/librime.1.dylib`，发布打包时先签嵌套 dylib，再签外层 app。

## 用户数据和升级

新词库在 `~/Library/Application Support/Saylane/Rime`。
旧的 `~/Library/Application Support/RTranslate` 词频 JSON、模型和诊断不删除、不覆盖。
旧自研学习数据未自动转换进 Rime；新引擎从新用户词库开始学习。格式和评分语义不同，不能简单把旧“置顶分数”导入成 Rime 词频。

Rime session 的局部选词保留在 marked text 中，直到整段完成；并非每选一个词都立刻往宿主输入框插入一次。用户可继续退格撤回选词。

## 中英切换契约

- `nihao` + 单按 Shift → 上屏原始 `nihao`，切英文；左右 Shift 都支持。
- `nihao` + Caps Lock 开启 → 上屏原始 `nihao`，后续大写字母/ASCII 标点由宿主处理；Caps Lock 关闭回到原来的中英模式。
- 已显式选中“你”，剩余 `hao` → 切英文时上屏 `你hao`；不能接受未确认的“好”，也不能把确认的“你”变回 `ni`。
- Return 使用同样的“保留已确认段、剩余原样字母”行为，不改变中英模式。
- Rime express editor 的 Return 负责这一行为；不调用普通候选提交，也不把英文余串伪装成中文学习。
- Shift 被语音快捷键占用时不切中英；组合快捷键与英文模式按键透传。
- 设置中途更改模糊音方案前先原样提交当前段，避免 Rime 切方案丢字。

## 构建与复现

```
python3 scripts/prepare-rime.py  # 校验下载、部署两个方案
scripts/test-rime.sh            # 真实引擎测试 + 跨进程学习
make test                      # 原测试与 Rime 新测试
make build                     # 包含依赖准备、工程生成与 Debug 构建
make release                   # Release 构建，不安装
build/Build/Products/Release/Saylane.app/Contents/MacOS/Saylane --pinyin-self-test
```

生成目录 `Vendor/Rime/Downloads`、`Runtime`、`Rime` 不提交 Git；固定来源、配置与准备脚本提交 Git。
Python 需要支持 `tarfile.extractall(filter='data')`（建议 Python 3.12+）。

`--pinyin-self-test` 使用 app bundle 内真实 dylib 和资源、隔离的临时用户目录，不注册 IMK、不抢输入源、不动用户词库、不请求语音权限。

## 许可材料

`Resources/Rime` 一并提供：
- librime 及 native dependencies 许可文本；
- 雾凇词典原始源码、原始词库来源头、GPL-3.0 文本；
- rime-essay 原始文本、AUTHORS、LGPL-3.0 文本（GPL-3.0 正文也包含在目录内）；
- 修改后的 Saylane schema / dictionary 配置、准确的来源和校验清单。

词库许可独立于引擎许可，不笼统宣称“Rime 相关内容全部 BSD”。本次没有执行发布。

## 验证边界

- 真实 librime 首选、整句、简拼/混拼、分页、数字选词、局部选词、退格、取消、Shift/Caps Lock/Return、语音占键避让、快捷键透传、模糊音以及跨进程用户学习均有回归测试。
- 热路径 75 次按键的观测 p95 约 0.4 ms，是当前开发机上的小样本 native/frontend 测试，不是跨应用实测延迟或全量准确率指标。
- 完整旧测试通过；Debug 和 Release 构建通过。
- 仍需实际安装后逐一验收浏览器、编辑器、聊天框的 marked text、候选点击、焦点切换、系统输入法切换和语音交接。源码/自检通过不代表这些已验证。


## 手动检查词库更新（0.2.50）

设置 → 键盘 → 词库更新：显示当前打包的雾凇 commit，点击后才请求 GitHub 官方 API。
先取得 main 的准确 commit，再按这个不可变 commit 读取 cn_dicts 目录；仅比较应用使用的
8105 / base / ext / others 四份词表。上游改 README、Lua 或未启用词表不会误报更新。
本地原文用打包清单中的 SHA-256 验证，再计算 Git blob ID 比较远端目录元数据。

支持检查中、已是最新、发现变化、断网、超时、限流和无效数据的独立提示，可取消并重试。
检查不上传输入内容，不使用个人词库、Cookie 或 GitHub token；不在启动时或定时后台检查。
此功能目前只检查和打开上游版本，**不下载/安装词库更新**，安装新词库仍需新版应用。
没有写入当前 app bundle 或用户词库，也不会热重载 Rime。

验证：`scripts/test-rime-updates.sh`（隔离模拟 API；取消、重复点击、固定版本比较和无写入）；
`build/tests/rime-updates --live "$PWD/Vendor/Rime/Rime"` 可只读验证真实上游 API。
