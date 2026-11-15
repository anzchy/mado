/// `SMAppService.Status` for the helper's login item, without importing ServiceManagement here.
public enum CaptureLoginItemStatus: Equatable, Sendable {
    case enabled, notRegistered, requiresApproval, notFound
}

/// Start at login for the capture helper (#685, ADR-0018: an `SMAppService` login item).
public protocol CaptureLoginItemPort: Sendable {
    func status() async -> CaptureLoginItemStatus
    func register() async throws
    func unregister() async throws
    /// `SMAppService.openSystemSettingsLoginItems()`, the only System Settings link on the tab.
    func openLoginItemsSettings() async
}

/// What the 「登录时启动」 row shows. The switch reflects the system's status, not a stored flag; it is greyed while
/// the bar is off (grilling 5.2).
public struct CaptureLoginPresentation: Equatable, Sendable {
    public let isOn: Bool
    public let isEditable: Bool
    public let needsApproval: Bool
    public let removalFailed: Bool

    public init(isOn: Bool, isEditable: Bool, needsApproval: Bool, removalFailed: Bool = false) {
        self.isOn = isOn
        self.isEditable = isEditable
        self.needsApproval = needsApproval
        self.removalFailed = removalFailed
    }

    /// `removalFailed`: the bar is off but the item is still registered (turning the bar off could not remove it),
    /// so the helper may still start at login. Settings says so and offers a retry (#685 fix r1).
    public static func make(status: CaptureLoginItemStatus, barEnabled: Bool) -> CaptureLoginPresentation {
        let registered = status == .enabled || status == .requiresApproval
        return CaptureLoginPresentation(isOn: registered,
                                        isEditable: barEnabled && status != .notFound,
                                        needsApproval: barEnabled && status == .requiresApproval,
                                        removalFailed: !barEnabled && registered)
    }
}
