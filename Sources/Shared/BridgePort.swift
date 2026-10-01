import Foundation

/// A named local message port. Requests are answered on the run loop of the
/// thread that created the listener, or on `queue` when one is given: a port
/// only holds a few messages, so a receiver that may be busy should drain it
/// somewhere that is not.
final class BridgeListener {
    private var port: CFMessagePort?
    private var source: CFRunLoopSource?
    private let handler: (Data) -> Data?

    /// Fails when the name is already taken by another process.
    init?(name: String, queue: DispatchQueue? = nil, handler: @escaping (Data) -> Data?) {
        self.handler = handler
        var context = CFMessagePortContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: CFMessagePortCallBack = { _, _, data, info in
            guard let info else { return nil }
            let listener = Unmanaged<BridgeListener>.fromOpaque(info).takeUnretainedValue()
            guard let reply = listener.handler((data as Data?) ?? Data()) else { return nil }
            return Unmanaged.passRetained(reply as CFData)
        }
        guard let port = CFMessagePortCreateLocal(nil, name as CFString, callback, &context, nil) else { return nil }
        self.port = port
        if let queue {
            CFMessagePortSetDispatchQueue(port, queue)
        } else {
            let source = CFMessagePortCreateRunLoopSource(nil, port, 0)
            self.source = source
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
    }

    func invalidate() {
        if let port { CFMessagePortInvalidate(port) }
        port = nil
        source = nil
    }

    deinit { invalidate() }
}

/// Sends to a named port of the other process. Everything goes through one
/// serial queue, so a request is never overtaken by an earlier post.
final class BridgeSender: @unchecked Sendable {
    private let name: String
    private let queue: DispatchQueue
    private var remote: CFMessagePort?
    private var suspendedUntil: TimeInterval = 0
    /// A post must never hold the caller up; a hung peer costs at most this.
    private let postTimeout: TimeInterval = 0.02
    /// A private run-loop mode: waiting for a reply runs nothing else on the thread.
    private static let replyMode = "com.rtranslate.saylane.bridge.reply"

    init(name: String) {
        self.name = name
        queue = DispatchQueue(label: "saylane.bridge.\(name)", qos: .userInteractive)
    }

    /// Fire and forget, in order.
    func post(_ data: Data) {
        queue.async { [self] in
            let now = ProcessInfo.processInfo.systemUptime
            guard now >= suspendedUntil else { return }
            if send(data, wait: nil) == .timeout {
                // The peer is not draining its port: stop queueing behind it for a while.
                suspendedUntil = now + 1
            }
        }
    }

    /// Wait for the answer. Nil when the peer is absent, late or gave no reply.
    func request(_ data: Data, timeout: TimeInterval) -> Data? {
        queue.sync { [self] in
            if case .reply(let reply) = send(data, wait: timeout) { return reply }
            return nil
        }
    }

    /// The peer's port exists right now.
    var isReachable: Bool { queue.sync { connect() != nil } }

    private enum Outcome: Equatable { case sent, reply(Data), timeout, unreachable }

    private func connect() -> CFMessagePort? {
        if let remote, CFMessagePortIsValid(remote) { return remote }
        remote = CFMessagePortCreateRemote(nil, name as CFString)
        return remote
    }

    private func send(_ data: Data, wait: TimeInterval?) -> Outcome {
        // The cached port goes stale when the peer restarts: try once more with a fresh one.
        for attempt in 0..<2 {
            guard let port = connect() else { return .unreachable }
            var reply: Unmanaged<CFData>?
            let status = CFMessagePortSendRequest(port, 0, data as CFData, wait == nil ? postTimeout : min(0.25, wait!),
                                                  wait ?? 0, wait == nil ? nil : Self.replyMode as CFString, &reply)
            switch status {
            case Int32(kCFMessagePortSuccess):
                guard wait != nil else { return .sent }
                guard let reply else { return .sent }
                return .reply(reply.takeRetainedValue() as Data)
            case Int32(kCFMessagePortSendTimeout), Int32(kCFMessagePortReceiveTimeout):
                return .timeout
            default:
                remote = nil
                if attempt == 1 { return .unreachable }
            }
        }
        return .unreachable
    }
}
