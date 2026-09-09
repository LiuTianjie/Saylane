import Foundation
import Observation

@MainActor
@Observable
final class RimeDictionaryUpdateModel {
    enum State: Equatable {
        case idle, checking, checked(RimeDictionaryUpdateResult), failed(String)
    }
    private(set) var state: State = .idle
    let currentVersion: String
    private let resource: URL?
    private let checker: any RimeDictionaryChecking
    private var task: Task<Void, Never>?
    private var generation = 0

    init(resource: URL? = Bundle.main.resourceURL?.appendingPathComponent("Rime"),
         checker: any RimeDictionaryChecking = RimeDictionaryUpdateService()) {
        self.resource = resource
        self.checker = checker
        currentVersion = resource.flatMap { try? RimeDictionaryUpdateService.installedVersion(resource: $0).shortRevision } ?? "未知"
    }
    var isChecking: Bool { state == .checking }
    var result: RimeDictionaryUpdateResult? {
        if case .checked(let result) = state { return result }
        return nil
    }
    var statusText: String {
        switch state {
        case .idle: return "手动检查雾凇词库，不会自动下载或修改个人词库。"
        case .checking: return "正在检查词库更新…"
        case .checked(let result):
            if result.hasUpdate {
                return "发现词库变化：\(result.changedTables.joined(separator: "、"))。此版本仅支持检查，安装更新仍需新版应用。"
            }
            return "当前使用的四份词表已是最新。"
        case .failed(let message): return message
        }
    }

    func check() {
        guard task == nil else { return }
        guard let resource else {
            state = .failed(RimeDictionaryUpdateError.localData.localizedDescription)
            return
        }
        generation += 1
        let token = generation
        let checker = checker
        state = .checking
        task = Task { [weak self] in
            do {
                let result = try await checker.check(resource: resource)
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.state = .checked(result)
                self.task = nil
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                if let error = error as? URLError {
                    switch error.code {
                    case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost:
                        self.state = .failed("无法连接词库服务器，请检查网络后重试。")
                    case .timedOut: self.state = .failed("检查超时，请稍后重试。")
                    case .cancelled: self.state = .idle
                    default: self.state = .failed("网络检查失败，请稍后重试。")
                    }
                } else {
                    self.state = .failed(error.localizedDescription)
                }
                self.task = nil
            }
        }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        if isChecking { state = .idle }
    }
}
