import MadoApplication
import ServiceManagement

/// Start at login for the embedded capture helper (#685, ADR-0018): an `SMAppService` login item, so turning it on
/// never keeps the viewer itself running.
struct SMAppServiceCaptureLoginItem: CaptureLoginItemPort {
    private var service: SMAppService { .loginItem(identifier: CaptureBarIdentity.bundleID) }

    func status() async -> CaptureLoginItemStatus {
        switch service.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        default: .notRegistered
        }
    }

    func register() async throws { try service.register() }

    func unregister() async throws { try await service.unregister() }

    func openLoginItemsSettings() async { SMAppService.openSystemSettingsLoginItems() }
}
