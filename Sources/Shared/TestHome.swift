import Foundation

/// A build started with `SAYLANE_TEST_HOME=<directory>` keeps away from the
/// installed product: its data lives in that directory, its preferences in a
/// test domain, and its bridge ports have their own names. Used to exercise a
/// build on a machine where Saylane is installed and in use.
enum TestHome {
    static let path: String? = {
        guard let value = ProcessInfo.processInfo.environment["SAYLANE_TEST_HOME"], !value.isEmpty else { return nil }
        return value
    }()
    static var isActive: Bool { path != nil }
    static var suffix: String { isActive ? ".test" : "" }
}
