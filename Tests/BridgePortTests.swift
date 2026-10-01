import Foundation

/// Two real processes talking over the bridge ports: order, replies, a slow or
/// absent peer, and a peer that restarts.
@main struct BridgePortTests {
    static func serve(_ name: String) -> Never {
        var log: [String] = []
        let listener = BridgeListener(name: name) { data in
            let text = String(decoding: data, as: UTF8.self)
            if text.hasPrefix("echo:") { return Data(text.dropFirst(5).utf8) }
            if text.hasPrefix("post:") { log.append(String(text.dropFirst(5))); return nil }
            if text == "log" { return Data(log.joined(separator: ",").utf8) }
            if text == "slow" { Thread.sleep(forTimeInterval: 0.5); return Data("late".utf8) }
            return nil
        }
        guard listener != nil else { exit(3) }
        // Never outlive the test.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { exit(0) }
        withExtendedLifetime(listener) { RunLoop.main.run() }
        exit(0)
    }

    static func spawn(_ name: String) -> Process {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["serve", name]
        try! child.run()
        return child
    }

    static func main() {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "serve" { serve(CommandLine.arguments[2]) }
        let name = "com.rtranslate.saylane.tests.bridge.\(getpid())"
        let sender = BridgeSender(name: name)
        func ask(_ text: String, timeout: TimeInterval = 1) -> String? {
            sender.request(Data(text.utf8), timeout: timeout).map { String(decoding: $0, as: UTF8.self) }
        }
        func elapsed(_ work: () -> Void) -> TimeInterval {
            let start = ProcessInfo.processInfo.systemUptime
            work()
            return ProcessInfo.processInfo.systemUptime - start
        }

        // Nobody is listening: a request answers nil at once and a post is dropped.
        var answer: String? = "unset"
        precondition(elapsed { answer = ask("echo:x") } < 0.2 && answer == nil)
        precondition(!sender.isReachable)
        sender.post(Data("post:lost".utf8))

        var server = spawn(name)
        var ready = false
        for _ in 0..<60 where !ready {
            ready = sender.isReachable
            if !ready { Thread.sleep(forTimeInterval: 0.05) }
        }
        precondition(ready, "server did not come up")
        precondition(ask("echo:你好") == "你好")

        // The same name cannot be claimed twice.
        precondition(BridgeListener(name: name) { _ in nil } == nil)

        // Posts arrive in order, and a request never overtakes an earlier post.
        for item in ["a", "b", "c"] { sender.post(Data("post:\(item)".utf8)) }
        precondition(ask("log") == "a,b,c", "\(ask("log") ?? "nil")")

        // A slow peer costs the timeout and nothing more; its late answer is
        // never mistaken for the answer to the next request.
        var slow: String? = "unset"
        let waited = elapsed { slow = ask("slow", timeout: 0.1) }
        precondition(slow == nil && waited < 0.4, "\(waited)")
        precondition(ask("echo:z", timeout: 2) == "z")

        // The peer restarts: the stale connection is replaced without help.
        server.terminate(); server.waitUntilExit()
        precondition(ask("echo:gone") == nil)
        server = spawn(name)
        ready = false
        for _ in 0..<60 where !ready {
            ready = ask("echo:back", timeout: 0.2) == "back"
            if !ready { Thread.sleep(forTimeInterval: 0.05) }
        }
        precondition(ready, "did not reconnect after the peer restarted")
        precondition(ask("log") == "", "a restarted peer starts empty")
        server.terminate(); server.waitUntilExit()

        // A listener on its own queue keeps draining while the main thread is busy.
        let busy = "\(name).queue"
        let received = DispatchSemaphore(value: 0)
        let queued = BridgeListener(name: busy, queue: DispatchQueue(label: "test.receive")) { _ in
            received.signal()
            return nil
        }
        precondition(queued != nil)
        let toBusy = BridgeSender(name: busy)
        for index in 0..<40 { toBusy.post(Data("post:\(index)".utf8)) }
        // The main thread never runs its run loop here; all forty must still arrive.
        for _ in 0..<40 { precondition(received.wait(timeout: .now() + 2) == .success, "a post was dropped") }
        withExtendedLifetime(queued) {}
        print("PASS: bridge ports between two processes: absent peer, order, replies, slow peer, name collision, restart, a busy receiver")
    }
}
