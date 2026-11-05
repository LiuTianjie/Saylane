import Foundation
import Network

/// The words the gate uses, in one place.
enum MembershipCopy {
    static func featureName(_ feature: MembershipFeature) -> String {
        switch feature {
        case .translateAnywhere: return String(localized: "所见即译")
        case .aiPolish: return String(localized: "AI 校对与精翻")
        case .dictation: return String(localized: "听写")
        case .pinyin: return String(localized: "拼音")
        case .voiceTranslation: return String(localized: "边说边译")
        }
    }

    static func prompt(for feature: MembershipFeature, access: MembershipAccess) -> String {
        let name = featureName(feature)
        switch access {
        case .signedOut:
            return String(localized: "\(name)包含在 iTool 年度会员中。请在「账号与会员」里登录 iTool 账号。")
        case .notIncluded(.monthly):
            return String(localized: "\(name)包含在 iTool 年度会员中，月度会员不含。可以在「账号与会员」里升级年度会员。")
        case .notIncluded:
            return String(localized: "\(name)包含在 iTool 年度会员中（¥99/年）。可以在「账号与会员」里开通。")
        case .unverified(.offlineTooLong):
            return String(localized: "已经 7 天没能确认会员状态。联网后点「刷新会员状态」即可继续使用\(name)。")
        case .unverified(.clockChanged):
            return String(localized: "这台 Mac 的时间被调回过。联网后点「刷新会员状态」即可继续使用\(name)。")
        case .unverified(.expired):
            return String(localized: "iTool 年度会员已到期。续费后点「刷新会员状态」即可继续使用\(name)。")
        case .unverified(.neverChecked):
            return String(localized: "还没能确认会员状态。联网后点「刷新会员状态」即可使用\(name)。")
        case .active:
            return ""
        }
    }
}

/// Says when the network comes back, so a check that failed offline is repeated at once.
final class NetworkWatch: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.saylane.network-watch")
    private var wasSatisfied = true
    var onReturn: (@Sendable () -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            if satisfied, !self.wasSatisfied { self.onReturn?() }
            self.wasSatisfied = satisfied
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}
