# 普通键盘输入与语音共存：技术调研

日期：2026-09-07。仅调研；未修改运行中的输入逻辑。

## 结论

- 如果产品要求用户一直选中 RTranslate，它就应提供完整键盘输入体验，而不仅是语音。
- 可以通过公开 TIS API 切换到已启用的系统拼音/ABC 输入源，但这会取消选中原键盘输入源，不是把系统拼音引擎嵌入自己的 IMK 控制器。
- 在所核查的 InputMethodKit 与 Text Input Sources 公开接口中，没有找到可把拼音字符串交给 Apple 拼音并取得候选列表的受支持接口。此结论限于公开接口调研，不主张系统内部不存在相关实现。
- IMKCandidates 提供候选窗，候选内容仍由自己的 controller 提供；它不是拼音转换引擎。

## 当前代码证据

Sources/IME 内的 RTranslateInputController.handle 将事件交给 AppModel.consumeIMEEvent；其调用快捷键状态机后返回 consumed。普通按键不消费，交回客户端；当前没有拼音组词、词典、候选选择、用户词频或中英文模式控制器。普通拉丁字母输入有透传路径，但尚未跨 App 实测所有布局、Caps Lock 和 Shift 行为，不能宣称完整键盘输入已支持。

## 两条产品路线

### A：复用用户当前输入法（推荐优先完成）

平时保持系统拼音/ABC/用户输入法。用户主动启用全局语音快捷键后，记录原输入源与目标应用，临时选择 RTranslate，等待 IMK client 附着再开始语音合成；提交或取消后，在原应用/焦点没有改变且输入源仍归本次会话所有时恢复原输入法。不要用剪贴板替代 IMK。

必要边界：全局独立修饰键的权限与引导；切入前松手取消；全局/本地按键去重；同一个按键被其他语音软件占用；原输入法有未提交拼音时切换可能改变其组字状态（必须实测，不能承诺无损恢复）；窗口或输入框切换不写错目标；密码框不强行注入；用户手动切输入法后不抢回；Esc 取消；录音结束才恢复，避免 IMK 脱离客户端时丢失 marked text。

此路线保留用户已有拼音、词库、中英文与大小写习惯，但不是 RTranslate 自带拼音。目前全局唤起尚未实现。

### B：完整输入法（常驻选中 RTranslate）

IMK 壳 + 独立文字组字状态机 + librime 拼音后端 + 候选 UI + 现有语音会话。

至少覆盖：全拼/整句候选、空格/数字选词、翻页、退格、Esc、标点与全半角、中文/英文模式、Shift/Caps Lock、应用快捷键、词频与用户词库、语音与未完成拼音的互斥和交接。英文模式应尊重实际键盘布局，不只按美式 keyCode 硬编码字符。中英文键盘模式与语音目标语言是两个独立设置；双击 Command 切翻译语言不能意外改变键盘模式。

librime 上游 README 标为 BSD-3-Clause；Squirrel（鼠须管）上游 README 标为 GPL v3。集成引擎、复制前端代码和附带词库是不同依赖选择，发布前需逐项核查许可，不能笼统称“Rime 全部 BSD”。

## 豆包证据边界

只读检查本机 /Library/Input Methods/DoubaoIme.app/Contents/Info.plist：输入模式 ID 为 com.bytedance.inputmethod.doubaoime.pinyin。Frameworks 下含 OimeEngine.framework、OimeCommon.framework。这证明本机安装物注册了拼音模式并携带引擎组件；仅凭文件名不能确认其内部算法、是否使用系统私有组件或候选数据来源。

豆包官网 /pc 页面同时出现“macOS版敬请期待”和“macOS版语音输入”，是混合/可能滞后的发布信息，不用它覆盖本机安装物事实，也不能从跨平台宣传推断本机版全部功能。

## 验收建议

路线 A：在系统拼音输入一句中文→保留选词体验→在干净插入点按语音键→逐步显示英文 marked text→松开提交→恢复原拼音→继续键入中文。另测未提交拼音、按住 Shift/Caps Lock、ABC、取消、权限拒绝、快捷键冲突与焦点改变。

路线 B：除上述语音用例外，增加拼音候选、修正、词频和各类编辑快捷键矩阵；不把拼音最小示例当作可用的完整输入法。

## 资料与获取方式

web 搜索工具本轮返回空结果；通过 HTTPS 直接取得 Apple 官方文档、上游仓库 README，并检查本机 SDK 头文件与安装物。未执行未知下载代码，未修改豆包。

- Apple IMKInputController: https://developer.apple.com/documentation/inputmethodkit/imkinputcontroller
- Apple IMKCandidates: https://developer.apple.com/documentation/inputmethodkit/imkcandidates
- Apple Xcode macOS SDK: Carbon.framework/Frameworks/HIToolbox.framework/Headers/TextInputSources.h，TISSelectInputSource、TISCopyCurrentKeyboardInputSource。
- librime 上游：https://github.com/rime/librime （README 特性与许可）
- Squirrel 上游：https://github.com/rime/squirrel （README macOS 输入法与许可）
- 豆包官方：https://shurufa.doubao.com/pc （只作为产品入口，不作为本机实现证明）
