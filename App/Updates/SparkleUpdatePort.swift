import Foundation
import PicseeApplication
import Sparkle

/// Boundary for Sparkle's native controller. Tests replace only the external framework operations.
@MainActor protocol SparkleController: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var lastUpdateCheckDate: Date? { get }
    var canCheckForUpdates: Bool { get }
    func checkForUpdates()
    func startUpdater()
    func observe(_ onChange: @escaping @MainActor () -> Void)
}

@MainActor final class NativeSparkleController: NSObject, SparkleController, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController!
    private var observations: [NSKeyValueObservation] = []
    private var observers: [@MainActor () -> Void] = []

    override init() {
        super.init()
        // Start only after the first main window is visible (#359).
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
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
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
    var lastUpdateCheckDate: Date? { controller.updater.lastUpdateCheckDate }
    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
    func checkForUpdates() { controller.checkForUpdates(nil) }
    func startUpdater() { controller.startUpdater() }
    func observe(_ onChange: @escaping @MainActor () -> Void) { observers.append(onChange) }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) { notify() }
    private func notify() { observers.forEach { $0() } }
}

@MainActor final class SparkleUpdatePort: AppUpdatePort {
    private let controller: (any SparkleController)?
    init(infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:],
         makeController: @MainActor () -> any SparkleController = { NativeSparkleController() }) {
        // #552 will choose Mado's feed. Sparkle reports a missing-feed error if started without one;
        // avoid constructing it at all until the app supplies a feed, including the manual-check path.
        guard let feed = infoDictionary["SUFeedURL"] as? String,
              !feed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            controller = nil
            return
        }
        controller = makeController()
    }
    var versionInfo: AppVersionInfo { AppVersionInfo(infoDictionary: Bundle.main.infoDictionary ?? [:]) }
    var isAvailable: Bool { controller != nil }
    var automaticallyChecksForUpdates: Bool {
        get { controller?.automaticallyChecksForUpdates ?? false }
        set { controller?.automaticallyChecksForUpdates = newValue }
    }
    var lastUpdateCheckDate: Date? { controller?.lastUpdateCheckDate }
    var canCheckForUpdates: Bool { controller?.canCheckForUpdates ?? false }
    func checkForUpdates() { controller?.checkForUpdates() }
    func start() { controller?.startUpdater() }
    func observe(_ onChange: @escaping @MainActor () -> Void) { controller?.observe(onChange) }
}
