import Foundation
import PicseeApplication
import Sparkle

/// Untested native forwarding to Sparkle (network, XPC installer); the Settings side is covered with a fake
/// port, and the real path is checked on a device with a test appcast (#223). Excluded from PicseeAppTests; a source
/// guard there pins that the controller is built stopped and `start()` goes through `startUpdater()`, so a start
/// failure still shows Sparkle's own alert (#359).
@MainActor final class SparkleUpdatePort: NSObject, AppUpdatePort, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController!
    private var observers: [@MainActor () -> Void] = []
    private var observations: [NSKeyValueObservation] = []

    override init() {
        super.init()
        // Built stopped: start() runs after the first window is front, or Sparkle's second-launch question opens
        // behind it (#359).
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        // Sparkle's second-launch question and Settings both change the automatic flag, and a running check
        // makes canCheckForUpdates false; both are KVO-compliant on the main thread. lastUpdateCheckDate is not,
        // so the update-cycle callback below covers it.
        let updater = controller.updater
        observations = [
            updater.observe(\.automaticallyChecksForUpdates) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.notify() }
            },
            updater.observe(\.canCheckForUpdates) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.notify() }
            },
        ]
    }

    var versionInfo: AppVersionInfo { AppVersionInfo(infoDictionary: Bundle.main.infoDictionary ?? [:]) }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastUpdateCheckDate: Date? { controller.updater.lastUpdateCheckDate }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    func checkForUpdates() { controller.checkForUpdates(nil) }

    func start() { controller.startUpdater() }

    func observe(_ onChange: @escaping @MainActor () -> Void) { observers.append(onChange) }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        notify()
    }

    private func notify() { observers.forEach { $0() } }
}
