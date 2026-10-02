import AppKit
import Foundation
import Observation

/// The main program's side of the bridge to the input method. It keeps what is
/// known about the other process, pushes the context whole whenever it changes
/// and writes dictations through the attached client. See `docs/DESIGN_0.3.md`.
@MainActor @Observable
final class IMEBridgeClient {
    /// What the input method last reported. Nil while it is not running.
    private(set) var status: BridgeIMEStatus?
    /// The application whose client the input method is attached to.
    private(set) var attachedBundleID: String?
    /// The client the talk key last went down in, and when (system uptime).
    @ObservationIgnored private var talkKey: (bundleID: String, at: TimeInterval)?
    @ObservationIgnored private let sender = BridgeSender(name: Bridge.imePortName)
    @ObservationIgnored private var listener: BridgeListener?
    @ObservationIgnored private let receiveQueue = DispatchQueue(label: "saylane.bridge.receive", qos: .userInteractive)
    @ObservationIgnored private var context = BridgeContext()
    @ObservationIgnored private var pinyin: BridgePinyinPreferences?
    @ObservationIgnored private var watch: DispatchSourceProcess?
    @ObservationIgnored private var watchedPID: Int32 = 0
    @ObservationIgnored private var markedSeq: UInt64 = 0
    @ObservationIgnored var onEvent: ((BridgeEvent) -> Void)?

    var isConnected: Bool { status != nil }
    /// The two processes were built from different versions of the contract.
    var protocolMismatch: Bool { status.map { $0.protocolVersion != Bridge.protocolVersion } ?? false }
    var pinyinError: String? { status?.pinyinError }

    /// How long the final text may take to be written before another route is used.
    static let insertTimeout: TimeInterval = 1.5

    func start() {
        // Events are taken off the port at once and handled in order on the
        // main actor: a busy main thread must not fill the input method's port.
        listener = BridgeListener(name: Bridge.appPortName, queue: receiveQueue) { [weak self] data in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(data) } }
            return nil
        }
        if listener == nil { InputDiagnostics.record("bridge-port-taken", Bridge.appPortName) }
        refreshStatus()
    }

    /// Ask the input method who it is. Cheap; also the way to find it after it restarted.
    func refreshStatus() {
        guard case .status(let status)? = ask(.status, timeout: 0.3) else {
            if self.status != nil { disconnected() }
            return
        }
        connected(status)
    }

    // MARK: - Context

    /// Change what the input method knows. Pushed whole, and only when it differs.
    func update(_ mutate: (inout BridgeContext) -> Void) {
        var next = context
        mutate(&next)
        next.appPID = getpid()
        next.revision = context.revision
        guard next != context else { return }
        next.revision = context.revision + 1
        context = next
        if isConnected { post(.context(next)) }
    }

    func push(pinyin preferences: BridgePinyinPreferences) {
        guard preferences != pinyin else { return }
        pinyin = preferences
        if isConnected { post(.pinyin(preferences)) }
    }

    // MARK: - Dictation

    /// The application a dictation started now belongs to. A panel — Spotlight,
    /// a launcher, a quick-entry window — takes the keyboard without becoming
    /// the application in front. When this press of the talk key arrived
    /// through the client the input method is attached to, that client has the
    /// keyboard and the dictation is its application's.
    func keyboardOwner(front bundleID: String?) -> String? {
        guard isConnected, !protocolMismatch, let attachedBundleID, let talkKey,
              talkKey.bundleID == attachedBundleID,
              ProcessInfo.processInfo.systemUptime - talkKey.at <= Bridge.talkKeyFreshness,
              !Bridge.client(attachedBundleID, belongsTo: bundleID) else { return bundleID }
        return attachedBundleID
    }

    /// The input method is selected and attached to a client of this application.
    func canWrite(inFront bundleID: String?) -> Bool {
        guard isConnected, !protocolMismatch, attachedBundleID != nil else { return false }
        return Bridge.client(attachedBundleID, belongsTo: bundleID)
    }

    /// Show a preview at the caret. The answer is not awaited: the newest text wins.
    func setMarked(_ text: String, session: UUID, inFront bundleID: String?) -> Bool {
        guard canWrite(inFront: bundleID) else { return false }
        markedSeq += 1
        post(.voiceMarked(session: session, seq: markedSeq, text: text))
        return true
    }

    func clearMarked(session: UUID) {
        guard isConnected else { return }
        post(.voiceClear(session: session))
    }

    /// Write the final text. True only when the input method says it did.
    func insert(_ text: String, session: UUID, inFront bundleID: String?) -> Bool {
        guard canWrite(inFront: bundleID) else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + Self.insertTimeout
        guard case .done(let written)? = ask(.voiceInsert(session: session, text: text, deadline: deadline),
                                             timeout: Self.insertTimeout + 0.2) else {
            InputDiagnostics.record("bridge", "insert got no answer")
            return false
        }
        return written
    }

    func end(session: UUID) {
        guard isConnected else { return }
        post(.voiceEnd(session: session))
    }

    /// Nothing more is to be learned from this dictation: the input method stops reading it back.
    func forget(session: UUID) {
        guard isConnected else { return }
        post(.voiceForget(session: session))
    }

    // MARK: - Transport

    private func post(_ request: BridgeRequest) { sender.post(Bridge.encode(request)) }

    private func ask(_ request: BridgeRequest, timeout: TimeInterval) -> BridgeReply? {
        Bridge.decode(BridgeReply.self, from: sender.request(Bridge.encode(request), timeout: timeout))
    }

    private func receive(_ data: Data) {
        guard let event = Bridge.decode(BridgeEvent.self, from: data) else { return }
        switch event {
        case .hello(let status):
            connected(status)
        case .attachment(let bundleID):
            attachedBundleID = bundleID
            // An event from a process we have not heard a hello from: find out who it is.
            if status == nil { refreshStatus() }
        case .talkKey(let bundleID, let at):
            talkKey = bundleID.map { ($0, at) }
        default:
            break
        }
        onEvent?(event)
    }

    private func connected(_ next: BridgeIMEStatus) {
        let isNewProcess = next.pid != status?.pid
        status = next
        attachedBundleID = next.attachedBundleID
        guard isNewProcess else { return }
        InputDiagnostics.record("input-method", "connected version=\(next.version) pid=\(next.pid) protocol=\(next.protocolVersion)")
        watchProcess(next.pid)
        // A new process knows nothing: tell it everything.
        if let pinyin { post(.pinyin(pinyin)) }
        context.appPID = getpid()
        context.revision += 1
        post(.context(context))
    }

    private func disconnected() {
        InputDiagnostics.record("input-method", "gone")
        status = nil
        attachedBundleID = nil
        talkKey = nil
        watch?.cancel()
        watch = nil
        watchedPID = 0
    }

    private func watchProcess(_ pid: Int32) {
        guard pid > 0, pid != watchedPID else { return }
        watch?.cancel()
        watchedPID = pid
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.watchedPID == pid else { return }
                self.disconnected()
            }
        }
        watch = source
        source.resume()
    }
}
