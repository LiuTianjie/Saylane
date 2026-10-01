import Foundation

@MainActor private final class ControlledSleep {
    var waits: [(TimeInterval, CheckedContinuation<Void, Error>)] = []
    func sleep(_ duration: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { waits.append((duration, $0)) }
    }
    func finish(_ index: Int) { waits[index].1.resume() }
}

@main struct InputDeferralDeadlineTests {
    @MainActor static func yieldUntil(_ predicate: () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            await Task.yield()
        }
        precondition(predicate(), "scheduled work did not run")
    }
    @MainActor static func main() async {
        let clock = ControlledSleep()
        let deadline = InputDeferralDeadline(sleep: clock.sleep)
        var callbacks: [String] = []
        deadline.arm(after: 0.45) { callbacks.append("first") }
        await yieldUntil { clock.waits.count == 1 }
        precondition(callbacks.isEmpty && clock.waits[0].0 == 0.45)
        // A fast sequence of printable keys has one deadline, not a sliding
        // debounce that can leave all typing blocked indefinitely.
        for _ in 0..<64 { deadline.arm(after: 0.45) { callbacks.append("extended") } }
        await Task.yield()
        precondition(clock.waits.count == 1)
        clock.finish(0)
        await yieldUntil { callbacks == ["first"] }

        deadline.arm(after: 0.45) { callbacks.append("cancelled") }
        await yieldUntil { clock.waits.count == 2 }
        deadline.cancel()
        deadline.arm(after: 0.45) { callbacks.append("new") }
        await yieldUntil { clock.waits.count == 3 }
        clock.finish(1)
        for _ in 0..<10 { await Task.yield() }
        precondition(callbacks == ["first"], "old finalization released a newer input queue")
        clock.finish(2)
        await yieldUntil { callbacks == ["first", "new"] }
        print("PASS: bounded typing deadline, repeated-key starvation, cancellation and stale-task isolation")
    }
}
