import Foundation

/// Sends the whole-screen request (`PreciseTranslation`) and reads the answer: one
/// request for an ordinary capture, a few at a time for a very large one, and never
/// longer than `timeout` for all of them together. No windows and no state; what
/// comes back is laid over the quick translation by `ScreenTranslateController`.
struct ScreenPreciseTranslator: Sendable {
    /// The system and the user message in, the model's text out. In the application this is the
    /// endpoint configured under Text Correction; tests and the scoring harness bring their own.
    typealias Transport = @Sendable (_ system: String, _ user: String) async throws -> String

    enum Failure: Sendable, Equatable {
        case timeout
        /// An answer came, with nothing in it that could be used: a refusal, prose, the wrong language.
        case unusable
        /// The request itself failed: no key, no connection, an HTTP error.
        case endpoint(String)

        /// For the diagnostics log: which kind, without what the endpoint said.
        var name: String {
            switch self { case .timeout: "timeout"; case .unusable: "unusable"; case .endpoint: "endpoint" }
        }
    }

    struct Outcome: Sendable {
        var accepted = PreciseTranslation.Accepted()
        /// Why some of it, or all of it, is missing. What was accepted is good all the same.
        var failure: Failure?
        var requests = 0
        var seconds = 0.0
    }

    /// Seconds for all requests of one capture together. A model writes a screenful of
    /// short translations in a few seconds; the quick picture is on screen meanwhile.
    static let patience = 30.0

    var transport: Transport
    var timeout = ScreenPreciseTranslator.patience
    /// Requests in flight at once, when a capture needs more than one.
    var concurrent = 3

    func translate(_ requests: [[PreciseTranslation.Item]], source: AppLanguage, target: AppLanguage,
                   app: String? = nil) async -> Outcome {
        guard !requests.isEmpty else { return Outcome() }
        enum Event: Sendable {
            case answered(Int, Result<String, any Error>)
            case deadline, cancelled
        }
        let transport = transport, timeout = timeout
        let messages = requests.map { PreciseTranslation.message($0, source: source, target: target, app: app) }
        let start = Date()
        var outcome = await withTaskGroup(of: Event.self) { group -> Outcome in
            var outcome = Outcome(requests: requests.count)
            group.addTask {
                do { try await Task.sleep(for: .seconds(timeout)); return .deadline } catch { return .cancelled }
            }
            func send(_ index: Int, in group: inout TaskGroup<Event>) {
                let message = messages[index]
                group.addTask {
                    do { return .answered(index, .success(try await transport(PreciseTranslation.instruction, message))) }
                    catch { return .answered(index, .failure(error)) }
                }
            }
            var next = 0, waiting = requests.count
            while next < min(concurrent, requests.count) { send(next, in: &group); next += 1 }
            while waiting > 0, let event = await group.next() {
                switch event {
                case .cancelled:
                    continue
                case .deadline:
                    // What has not answered by now is not waited for.
                    outcome.failure = .timeout
                    waiting = 0
                case .answered(let index, .success(let content)):
                    waiting -= 1
                    let answers = PreciseTranslation.parse(content)
                    let accepted = PreciseTranslation.accept(answers, for: requests[index], source: source, target: target)
                    outcome.accepted.translations.merge(accepted.translations) { first, _ in first }
                    outcome.accepted.kept.formUnion(accepted.kept)
                    outcome.accepted.rejected += accepted.rejected
                    outcome.accepted.long += accepted.long
                    if accepted.isEmpty, outcome.failure == nil { outcome.failure = .unusable }
                case .answered(_, .failure(let error)):
                    waiting -= 1
                    if !Task.isCancelled, outcome.failure == nil { outcome.failure = .endpoint(error.localizedDescription) }
                }
                if waiting > 0, next < requests.count { send(next, in: &group); next += 1 }
            }
            group.cancelAll()
            return outcome
        }
        outcome.seconds = Date().timeIntervalSince(start)
        return outcome
    }

    /// A transport that answers from a table — source text to translation, nil for "keep" — in
    /// the form a model is asked for. The scoring harness and the design preview run the whole
    /// path with it, without an endpoint.
    static func canned(_ table: [String: String?]) -> Transport {
        { _, user in
            let request = try JSONSerialization.jsonObject(with: Data(user.utf8)) as? [String: Any]
            var answer: [String: Any] = [:]
            for block in request?["blocks"] as? [[String: Any]] ?? [] {
                guard let id = block["id"] as? Int, let text = block["text"] as? String, let entry = table[text] else { continue }
                answer[String(id)] = entry ?? NSNull()
            }
            return String(data: try JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys]), encoding: .utf8) ?? "{}"
        }
    }
}
