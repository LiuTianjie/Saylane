import Foundation

private final class Meter: @unchecked Sendable {
    private let lock = NSLock()
    private var live = 0, peak = 0, loads = 0, flushes = 0
    func add() { lock.lock(); defer { lock.unlock() }; live += 1; loads += 1; peak = max(peak, live) }
    func remove() { lock.lock(); defer { lock.unlock() }; live -= 1 }
    func flush() { lock.lock(); defer { lock.unlock() }; precondition(live == 0, "flush retained a model"); flushes += 1 }
    func values() -> (Int, Int, Int, Int) { lock.lock(); defer { lock.unlock() }; return (live, peak, loads, flushes) }
}
private final class FakeModel: LoadedSpeechModel {
    let meter: Meter
    init(_ meter: Meter) { self.meter = meter; meter.add() }
    deinit { meter.remove() }
    func transcribe(_ audio: [Float], language: String) async throws -> String {
        try await Task.sleep(for: .milliseconds(60)); return "recognized"
    }
}
@main struct LocalSpeechRuntimeTests {
    static func main() async throws {
        let meter = Meter()
        let runtime = LocalSpeechRuntime(factory: { _ in
            // Intentionally ignore cancellation while constructing a model.
            try? await Task.sleep(for: .milliseconds(40))
            return FakeModel(meter)
        }, flushMemory: { meter.flush() })
        await runtime.unload()
        precondition(meter.values().3 == 0, "Apple-only initialized allocator")
        async let first: Void = runtime.prepare(.qwen4bit)
        async let second: Void = runtime.prepare(.qwen4bit)
        _ = try await (first, second)
        precondition(meter.values().2 == 1, "duplicate load")
        try await runtime.prepare(.qwen6bit)
        precondition(meter.values().1 == 1, "overlapping weights")
        let result = try await runtime.transcribe([], language: "Chinese", variant: .qwen6bit)
        precondition(result == "recognized")
        let inference = Task { try await runtime.transcribe([], language: "Chinese", variant: .qwen6bit) }
        try await Task.sleep(for: .milliseconds(10))
        try await runtime.prepare(.qwen4bit)
        _ = await inference.result
        // A cancelled inference must not leave a busy marker on the new model.
        _ = try await runtime.transcribe([], language: "Chinese", variant: .qwen4bit)
        await runtime.unload()
        precondition(meter.values().0 == 0)
        for _ in 0..<20 {
            let old = Task { try await runtime.prepare(.qwen4bit) }
            try await Task.sleep(for: .milliseconds(2))
            let next = Task { try await runtime.prepare(.qwen6bit) }
            try await Task.sleep(for: .milliseconds(2))
            await runtime.unload()
            _ = await old.result; _ = await next.result
            precondition(meter.values().0 == 0, "stale load resurrected")
        }
        let cancelled = Task { try await runtime.prepare(.qwen4bit) }
        try await Task.sleep(for: .milliseconds(2))
        let survivor = Task { try await runtime.prepare(.qwen4bit) }
        cancelled.cancel()
        _ = await cancelled.result
        try await survivor.value
        let active = Task { try await runtime.transcribe([], language: "Chinese", variant: .qwen4bit) }
        try await Task.sleep(for: .milliseconds(5))
        await runtime.unload(); _ = await active.result
        precondition(meter.values().0 == 0 && meter.values().1 == 1)
        print("Local speech lifetime: coalescing, cancellation, 20 rapid switches, inference drain and zero retained models passed")
    }
}
