import Foundation
import Observation
import Speech

/// Owns the lifecycle of the speech and translation models for the current
/// language pair: checking, downloading, loading and unloading. It reports
/// readiness through events and never touches windows or preferences.
@MainActor @Observable
final class ModelCoordinator {
    struct Configuration: Equatable {
        var source: AppLanguage
        var target: AppLanguage
        var speechModel: SpeechModel
        var passthrough: Bool

        init(_ p: Preferences) {
            source = p.sourceLanguage
            target = p.targetLanguage
            speechModel = p.speechModel
            passthrough = p.translationIsPassthrough
        }
    }

    let asrModels = ASRModelStore()
    let translation: TranslationProvider
    var onReadiness: ((ReadinessEvent) -> Void)?
    var onNotice: ((UserNotice) -> Void)?

    private(set) var configuration: Configuration
    private(set) var isPreparing = false { didSet { onReadiness?(.modelsPreparing(isPreparing)) } }
    private var checkingSettings = false { didSet { publishChecking() } }
    private var statusChecks = 0 { didSet { publishChecking() } }
    private var revision = 0
    private var task: Task<Void, Never>?

    var isChecking: Bool { checkingSettings || statusChecks > 0 }
    var isDownloading: Bool { asrModels.isDownloading }
    var isBusy: Bool { isChecking || isPreparing || isDownloading }

    init(preferences: Preferences, translation: TranslationProvider) {
        self.configuration = Configuration(preferences)
        self.translation = translation
    }

    private func publishChecking() { onReadiness?(.modelsChecking(isChecking)) }

    /// The language pair, model or passthrough setting changed: drop readiness and re-check.
    func apply(_ preferences: Preferences) {
        configuration = Configuration(preferences)
        revision += 1
        let current = revision
        task?.cancel()
        onReadiness?(.modelsInvalidated)
        translation.reset()
        checkingSettings = true
        task = Task { [weak self] in
            guard let self else { return }
            defer { if current == self.revision { self.checkingSettings = false } }
            if self.configuration.speechModel == .apple { await QwenRuntime.shared.unload() }
            guard current == self.revision, !Task.isCancelled else { return }
            do {
                if self.configuration.passthrough {
                    self.translation.enablePassthrough()
                } else {
                    try await self.translation.prepareInstalled(source: self.configuration.source.translationLanguage,
                                                                target: self.configuration.target.translationLanguage)
                }
                guard current == self.revision, !Task.isCancelled else { return }
            } catch {
                if current == self.revision, !Task.isCancelled {
                    self.onNotice?(.actionable(error.localizedDescription, .models))
                }
            }
            guard current == self.revision, !Task.isCancelled else { return }
            await self.refreshStatus()
        }
    }

    func refreshStatus() async {
        statusChecks += 1
        defer { statusChecks -= 1 }
        let current = revision
        let config = configuration
        asrModels.refresh()
        if config.speechModel == .apple {
            await QwenRuntime.shared.unload()
            let installed = await SpeechEngine.isInstalled(for: config.source.speechLocale)
            guard current == revision, !Task.isCancelled else { return }
            let detail = !SpeechTranscriber.isAvailable
                ? String(localized: "当前设备不支持 Apple 语音模型")
                : installed ? String(localized: "\(config.source.displayName) 语音模型已安装")
                            : String(localized: "请下载 \(config.source.displayName) 的语音模型")
            onReadiness?(.speechModel(ready: installed, detail: detail))
        } else {
            onReadiness?(.speechModel(ready: false, detail: String(localized: "正在校验并加载 \(config.speechModel.shortTitle)…")))
            if asrModels.installed.contains(config.speechModel) {
                do {
                    guard config.speechModel.supports(locale: config.source.speechLocale) else { throw ASRModelError.unsupportedLanguage }
                    _ = try QwenLanguage.name(for: config.source.speechLocale)
                    try await QwenRuntime.shared.prepare(config.speechModel)
                    guard current == revision, !Task.isCancelled else { return }
                    onReadiness?(.speechModel(ready: true, detail: String(localized: "\(config.speechModel.shortTitle) 已就绪：系统识别实时出字，它写终稿")))
                } catch {
                    guard current == revision, !Task.isCancelled else { return }
                    onReadiness?(.speechModel(ready: false, detail: String(localized: "模型未就绪，请重试或重新下载修复")))
                    onNotice?(.actionable(error.localizedDescription, .models))
                }
            } else {
                await QwenRuntime.shared.unload()
                onReadiness?(.speechModel(ready: false, detail: String(localized: "请下载 \(config.speechModel.shortTitle)")))
            }
        }
        guard current == revision, !Task.isCancelled else { return }
        let translationReady = config.passthrough || translation.isReady
        let translationDetail: String
        if configuration.passthrough {
            translationDetail = String(localized: "同语言听写，不调用翻译")
        } else {
            translationDetail = translationReady ? String(localized: "翻译模型已就绪") : String(localized: "翻译模型未准备好，请点击下载")
        }
        onReadiness?(.translationModel(ready: translationReady, detail: translationDetail))
    }

    /// Download whatever the current configuration still lacks.
    func downloadModels() async {
        guard !isBusy else { return }
        isPreparing = true
        defer { isPreparing = false }
        let config = configuration
        do {
            if config.speechModel == .apple {
                guard let locale = await SpeechEngine.resolvedLocale(for: config.source.speechLocale) else { throw SpeechEngineError.unsupportedLocale }
                try await SpeechEngine.prepareModel(for: locale)
            } else {
                if !asrModels.installed.contains(config.speechModel) { try await asrModels.download(config.speechModel) }
                // The words on screen while speaking come from the system's recognizer: have it, if it exists for the language.
                if let locale = await SpeechEngine.resolvedLocale(for: config.source.speechLocale) {
                    try? await SpeechEngine.prepareModel(for: locale)
                }
            }
            if !config.passthrough && !translation.isReady {
                try await translation.ready(source: config.source.translationLanguage, target: config.target.translationLanguage)
            }
            await refreshStatus()
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch { onNotice?(.actionable(error.localizedDescription, .models)) }
    }

    func downloadSpeechModel(_ selected: SpeechModel) async {
        guard !isBusy else { return }
        isPreparing = true
        defer { isPreparing = false }
        do {
            try await asrModels.download(selected)
            if configuration.speechModel == selected {
                await QwenRuntime.shared.unload()
                await refreshStatus()
            }
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch { onNotice?(.actionable(error.localizedDescription, .models)) }
    }

    /// Remove the weights. Returns true when the removed model was the selected one
    /// and the caller must switch the preference back to Apple.
    func removeSpeechModel(_ selected: SpeechModel) async -> Bool {
        guard !isBusy else { return false }
        let wasSelected = configuration.speechModel == selected
        if wasSelected {
            isPreparing = true
            await QwenRuntime.shared.unload()
            isPreparing = false
        }
        do { try asrModels.remove(selected) } catch { onNotice?(.actionable(error.localizedDescription, .models)) }
        return wasSelected
    }

    func canSelect(_ selected: SpeechModel) -> Bool {
        !isBusy && (selected == .apple || asrModels.installed.contains(selected))
    }
}
