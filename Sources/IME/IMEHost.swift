import AppKit
import Foundation

/// The input-method process: InputMethodKit, pinyin and the bridge to the main
/// program. It asks for no permission, opens no window of its own and is
/// expected to live until the next upgrade — see `docs/DESIGN_0.3.md`.
@MainActor
final class IMEHost {
    static let shared = IMEHost()

    let pinyin = PinyinEngine()
    private lazy var core: InputMethodCore = {
        let core = InputMethodCore(manager: IMEManager.shared, pinyin: pinyin) { [weak self] event in
            self?.post(event)
        }
        core.trace = { InputDiagnostics.record($0, $1) }
        return core
    }()
    private var listener: BridgeListener?
    private let app = BridgeSender(name: Bridge.appPortName)
    private var appWatch: DispatchSourceProcess?
    private var watchedPID: Int32 = 0
    private(set) var pinyinPreferences = BridgePinyinPreferences()
    private var lastLaunchAttempt: TimeInterval = -.infinity
    /// This process's own domain. A test home has its own: a self-test must
    /// neither read nor change what the installed input method remembers.
    private let defaults: UserDefaults = TestHome.isActive
        ? UserDefaults(suiteName: Bridge.defaultsSuite) ?? .standard : .standard

    private enum Key {
        static let trigger = "pushToTalkHotkey"
        static let englishMode = "pinyinEnglishMode"
        static let fuzzy = "pinyinFuzzyEnabled"
        static let barPreedit = "pinyinBarPreeditEnabled"
        /// Set by the main program when the user quits it; it is then not restarted behind their back.
        static let quitByUser = "mainProgramQuitByUser"
    }

    var menu: BridgeMenuState { core.context.menu }
    var isDictating: Bool { core.context.phase != .idle }
    var trigger: PushToTalkHotkey { core.trigger }
    var englishMode: Bool { pinyin.englishMode }
    var mainProgramConnected: Bool { watchedPID != 0 }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    private var status: BridgeIMEStatus {
        BridgeIMEStatus(version: version, pid: getpid(), attachedBundleID: IMEManager.shared.clientBundleID,
                        attachedFresh: IMEManager.shared.hasClient, pinyinError: pinyin.initializationError)
    }

    // MARK: - Start

    func start() {
        InputDiagnostics.record("ime-start", "version=\(version) pid=\(getpid())")
        pinyinPreferences = BridgePinyinPreferences(
            englishMode: defaults.object(forKey: Key.englishMode) as? Bool ?? false,
            fuzzy: defaults.object(forKey: Key.fuzzy) as? Bool ?? true,
            barPreedit: defaults.object(forKey: Key.barPreedit) as? Bool ?? false)
        pinyin.applyPreferences(pinyinPreferences)
        InputDiagnostics.record(pinyin.initializationError == nil ? "pinyin-ready" : "pinyin-init-failed",
                                pinyin.initializationError ?? "librime")
        pinyin.onEnglishModeChanged = { [weak self] english in self?.englishModeChanged(english) }
        // Until the main program says otherwise, the stored talk key decides
        // whether Shift toggles Chinese and English.
        var initial = BridgeContext()
        initial.trigger = defaults.string(forKey: Key.trigger) ?? initial.trigger
        core.apply(initial)

        IMEManager.shared.onWillSwitchClient = { [weak self] controller in
            self?.pinyin.switchClient(to: controller?.sessionID)
        }
        IMEManager.shared.onAttachmentChanged = { [weak self] bundleID in
            InputDiagnostics.record("client", bundleID ?? "none")
            self?.post(.attachment(bundleID: bundleID))
            if bundleID != nil { self?.startMainProgram(reason: "client attached") }
        }
        // InputMethodKit may have activated a client before this ran.
        pinyin.switchClient(to: IMEManager.shared.controller?.sessionID)

        listener = BridgeListener(name: Bridge.imePortName) { [weak self] data in
            MainActor.assumeIsolated { self?.answer(data) }
        }
        if listener == nil { InputDiagnostics.record("bridge-port-taken", Bridge.imePortName) }
        post(.hello(status))
        startMainProgram(reason: "input method started")
    }

    // MARK: - InputMethodKit

    func handle(_ event: NSEvent) -> Bool { core.handle(event) }

    func commitPinyin() {
        // Caps Lock often makes IMK call commitComposition before flagsChanged.
        // Commit the typed letters, not the highlighted Chinese candidate.
        if NSEvent.modifierFlags.contains(.capsLock) { pinyin.commitRaw() } else { pinyin.commit() }
    }

    func forgetClient(_ leaseID: UUID) { pinyin.forgetClient(leaseID) }

    func toggleEnglishMode() {
        pinyinPreferences.englishMode.toggle()
        pinyin.applyPreferences(pinyinPreferences)
        englishModeChanged(pinyinPreferences.englishMode)
    }

    /// A command from the input-method menu. Opening the settings starts the
    /// main program if it is not running, whatever the reason it stopped.
    func perform(_ action: BridgeMenuAction) {
        if action == .openSettings, !mainProgramRunning {
            startMainProgram(reason: "settings", arguments: ["--settings"], activates: true, force: true)
            return
        }
        post(.menu(action))
    }

    private func englishModeChanged(_ english: Bool) {
        pinyinPreferences.englishMode = english
        defaults.set(english, forKey: Key.englishMode)
        post(.pinyinMode(english: english))
    }

    // MARK: - Bridge

    private func post(_ event: BridgeEvent) { app.post(Bridge.encode(event)) }

    private lazy var responder = BridgeResponder(
        core: core,
        status: { [unowned self] in self.status },
        applyPinyin: { [unowned self] preferences in
            guard preferences != self.pinyinPreferences else { return }
            self.pinyinPreferences = preferences
            self.pinyin.applyPreferences(preferences)
        },
        mainProgramSeen: { [unowned self] pid in self.watchMainProgram(pid) },
        trace: { InputDiagnostics.record($0, $1) })

    private func answer(_ data: Data) -> Data? { responder.answer(data) }

    // MARK: - Main program

    private var mainProgramRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Bridge.appBundleID).isEmpty
    }

    /// Know when the main program dies: whatever it promised will not arrive.
    private func watchMainProgram(_ pid: Int32) {
        guard pid > 0, pid != watchedPID else { return }
        appWatch?.cancel()
        watchedPID = pid
        InputDiagnostics.record("main-program", "connected pid=\(pid)")
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.watchedPID == pid else { return }
                self.appWatch?.cancel()
                self.appWatch = nil
                self.watchedPID = 0
                InputDiagnostics.record("main-program", "exited pid=\(pid)")
                self.core.appExited()
            }
        }
        appWatch = source
        source.resume()
    }

    /// Dictation, screen translation and settings live in the main program.
    /// Start it quietly when typing begins and it is not there.
    private func startMainProgram(reason: String, arguments: [String] = ["--background"],
                                  activates: Bool = false, force: Bool = false) {
        // A test home never starts the installed product.
        guard !TestHome.isActive else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastLaunchAttempt > 30 else { return }
        guard !mainProgramRunning else { return }
        guard force || !defaults.bool(forKey: Key.quitByUser) else { return }
        lastLaunchAttempt = now
        // The installed copy first: LaunchServices also knows every build and
        // staging copy with the same identifier on a developer's Mac.
        let installed = URL(fileURLWithPath: "/Applications/Saylane.app")
        guard let url = (FileManager.default.fileExists(atPath: installed.path) ? installed : nil)
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: Bridge.appBundleID) else {
            InputDiagnostics.record("main-program", "not installed")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates
        configuration.addsToRecentItems = false
        configuration.arguments = arguments
        InputDiagnostics.record("main-program", "starting (\(reason))")
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            guard let error else { return }
            let message = error.localizedDescription
            Task { @MainActor in InputDiagnostics.record("main-program", "start failed: \(message)") }
        }
    }
}
