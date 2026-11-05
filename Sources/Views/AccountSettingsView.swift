import SwiftUI

/// 账号与会员: the iTool account, and what the membership includes.
struct AccountSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var email = ""
    @State private var password = ""
    @State private var browserSignIn: Task<Void, Never>?

    var body: some View {
        let membership = model.membership
        if let session = membership.session {
            signedIn(session, membership)
        } else {
            signIn(membership)
        }
        included
    }

    // MARK: Signed in

    @ViewBuilder private func signedIn(_ session: AccountSession, _ membership: MembershipController) -> some View {
        let access = membership.access
        SettingsSection {
            LabeledContent(String(localized: "账号")) {
                HStack(spacing: 10) {
                    Text(session.email ?? String(localized: "已登录")).foregroundStyle(.secondary).textSelection(.enabled)
                    Button(String(localized: "退出登录")) { Task { await membership.signOut() } }.controlSize(.small)
                        .selfTestAnchor("account-sign-out")
                }
            }
            LabeledContent {
                HStack(spacing: 10) {
                    if membership.isChecking { ProgressView().controlSize(.small) }
                    Button(String(localized: "刷新会员状态")) { Task { await membership.revalidate(force: true) } }
                        .controlSize(.small).disabled(membership.isChecking)
                        .selfTestAnchor("account-refresh")
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "会员"))
                    StatusText(text: Self.status(access, tier: membership.tier, record: membership.record),
                               ready: access.allowsMembershipFeatures)
                }
            }
            if !access.allowsMembershipFeatures {
                LabeledContent {
                    Button(membership.tier == .monthly ? String(localized: "升级年度会员")
                                                       : String(localized: "开通 iTool 年度会员（¥99/年，含全部 iTool 产品）")) {
                        model.openMembershipPurchase()
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .selfTestAnchor("account-buy")
                } label: {
                    Text(String(localized: "所见即译和 AI 校对与精翻需要年度会员")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            if let message = membership.message {
                Text(message).font(.system(size: 12)).foregroundStyle(.orange)
            }
        } header: {
            Text(String(localized: "iTool 账号"))
        } footer: {
            Text(String(localized: "在 itool.tech 开通或续费后，回到这里点「刷新会员状态」；Saylane 回到前台时也会自动确认。离线时最多继续使用 7 天。"))
        }
    }

    // MARK: Signed out

    @ViewBuilder private func signIn(_ membership: MembershipController) -> some View {
        let client = AccountClient(configuration: .from(bundle: .main))
        SettingsSection {
            LabeledContent(String(localized: "用第三方账号")) {
                if browserSignIn != nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(String(localized: "请在浏览器中完成登录")).font(.system(size: 12)).foregroundStyle(.secondary)
                        Button(String(localized: "取消")) { browserSignIn?.cancel() }.controlSize(.small)
                    }
                } else {
                    HStack(spacing: 8) {
                        Button("Google") { signInInBrowser("google", membership, client) }
                            .controlSize(.small).selfTestAnchor("account-google")
                        Button("GitHub") { signInInBrowser("github", membership, client) }
                            .controlSize(.small).selfTestAnchor("account-github")
                    }
                    .disabled(membership.isSigningIn)
                }
            }
            LabeledContent(String(localized: "邮箱")) {
                TextField(String(localized: "邮箱"), text: $email, prompt: Text(verbatim: "name@example.com"))
                    .labelsHidden().textContentType(.username).frame(maxWidth: 260)
            }
            LabeledContent(String(localized: "密码")) {
                SecureField(String(localized: "密码"), text: $password)
                    .labelsHidden().textContentType(.password).frame(maxWidth: 260)
                    .onSubmit(signInWithEmail)
            }
            LabeledContent {
                HStack(spacing: 10) {
                    if membership.isSigningIn { ProgressView().controlSize(.small) }
                    Button(String(localized: "登录")) { signInWithEmail() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(membership.isSigningIn || email.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
                        .selfTestAnchor("account-email-sign-in")
                }
            } label: {
                Link(String(localized: "还没有账号？在 itool.tech 注册"), destination: URL(string: "https://itool.tech/register")!)
                    .font(.system(size: 12))
            }
            if let message = membership.message {
                Text(message).font(.system(size: 12)).foregroundStyle(.orange)
            }
        } header: {
            Text(String(localized: "登录 iTool 账号"))
        } footer: {
            Text(String(localized: "和 itool.tech 是同一个账号。听写、拼音和边说边译不需要登录。"))
        }
    }

    /// The sign-in page opens as a tab in the default browser; the row waits and can cancel.
    private func signInInBrowser(_ provider: String, _ membership: MembershipController, _ client: AccountClient) {
        browserSignIn = Task { @MainActor in
            defer { browserSignIn = nil }
            await membership.signIn { try await client.signIn(provider: provider) }
        }
    }

    private func signInWithEmail() {
        let client = AccountClient(configuration: .from(bundle: .main))
        let email = email, password = password
        Task {
            await model.membership.signIn { try await client.signIn(email: email, password: password) }
            if model.membership.isSignedIn { self.password = "" }
        }
    }

    // MARK: What is included

    private var included: some View {
        SettingsSection {
            row(String(localized: "听写（按住说话）"), free: true)
            row(String(localized: "拼音输入"), free: true)
            row(String(localized: "边说边译"), free: true)
            row(String(localized: "所见即译"), free: false)
            row(String(localized: "AI 校对与精翻"), free: false)
            LabeledContent {
                Button(String(localized: "了解 iTool 会员")) { model.openMembershipPurchase() }.controlSize(.small)
            } label: {
                Text(String(localized: "年度会员 ¥99/年，含全部 iTool 产品；月度会员 ¥9.9 只含 iTool 官网和 LinkShell。"))
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(String(localized: "免费与会员"))
        }
    }

    private func row(_ title: String, free: Bool) -> some View {
        LabeledContent(title) {
            if free {
                Text(String(localized: "免费，无需登录")).foregroundStyle(.secondary)
            } else {
                MembershipBadge()
            }
        }
    }

    static func status(_ access: MembershipAccess, tier: MembershipTier, record: EntitlementRecord?) -> String {
        switch access {
        case .signedOut:
            return String(localized: "未登录")
        case .active(let validUntil, _):
            if let validUntil { return String(localized: "年度会员，\(Self.day(validUntil)) 到期") }
            return String(localized: "年度会员")
        case .notIncluded(.monthly):
            if let until = record?.memberUntil { return String(localized: "月度会员，\(Self.day(until)) 到期；不含 Saylane 会员功能") }
            return String(localized: "月度会员；不含 Saylane 会员功能")
        case .notIncluded:
            return String(localized: "免费账号")
        case .unverified(.neverChecked):
            return String(localized: "正在确认…")
        case .unverified(.offlineTooLong):
            return String(localized: "超过 7 天没能确认，请联网后刷新")
        case .unverified(.clockChanged):
            return String(localized: "系统时间被调回过，请联网后刷新")
        case .unverified(.expired):
            return String(localized: "年度会员已到期")
        }
    }

    private static func day(_ date: Date) -> String {
        date.formatted(date: .long, time: .omitted)
    }
}

/// The small mark on a feature that comes with the iTool yearly membership.
struct MembershipBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let unlocked = model.membership.access.allowsMembershipFeatures
        Button { model.openSettings(tab: 6) } label: {
            Label(unlocked ? String(localized: "年度会员") : String(localized: "需要年度会员"),
                  systemImage: unlocked ? "checkmark.seal.fill" : "lock.fill")
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .foregroundStyle(unlocked ? Theme.ready : Theme.accent)
                .background((unlocked ? Theme.ready : Theme.accent).opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(String(localized: "所见即译和 AI 校对与精翻包含在 iTool 年度会员中"))
    }
}

/// Shown above a gated feature's settings while the membership does not include it.
struct MembershipPrompt: View {
    @Environment(AppModel.self) private var model
    let feature: MembershipFeature

    var body: some View {
        let membership = model.membership
        let access = membership.access
        if !access.allowsMembershipFeatures {
            SettingsSection {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "lock.fill").foregroundStyle(Theme.accent).accessibilityHidden(true)
                    Text(MembershipCopy.prompt(for: feature, access: access))
                        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if membership.isSignedIn {
                        if case .notIncluded = access {
                            Button(membership.tier == .monthly ? String(localized: "升级年度会员") : String(localized: "开通年度会员")) {
                                model.openMembershipPurchase()
                            }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                        } else {
                            Button(String(localized: "刷新会员状态")) { Task { await membership.revalidate(force: true) } }
                                .controlSize(.small).disabled(membership.isChecking)
                        }
                    } else {
                        Button(String(localized: "登录")) { model.openSettings(tab: 6) }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
            }
        }
    }
}
