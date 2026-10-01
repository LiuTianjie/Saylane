import ServiceManagement

/// The main program as a login item. Only needed for the global talk key: when
/// Saylane is the selected input method, the input method starts it anyway.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns the error text when the system refused.
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        guard enabled != isEnabled else { return nil }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
