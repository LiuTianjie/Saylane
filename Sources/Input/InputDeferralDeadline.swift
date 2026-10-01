import Foundation

/// Starts once when typing first waits behind voice finalization. Subsequent
/// keystrokes must not extend the deadline, and an old task cannot release a
/// newer session's input after cancellation.
@MainActor
final class InputDeferralDeadline {
    private let sleep: (TimeInterval) async throws -> Void
    private var task: Task<Void, Never>?
    private var generation = 0

    init(sleep: @escaping (TimeInterval) async throws -> Void = {
        try await Task.sleep(for: .seconds($0))
    }) { self.sleep = sleep }

    func arm(after delay: TimeInterval, onExpiry: @escaping () -> Void) {
        guard task == nil else { return }
        generation += 1
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            do { try await self.sleep(delay) } catch { return }
            guard !Task.isCancelled, self.generation == token else { return }
            self.task = nil
            onExpiry()
        }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
    }
}
