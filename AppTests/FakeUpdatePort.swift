import Foundation
import PicseeApplication

/// In-memory stand-in for the Sparkle updater; the real path is device-verified (#223).
@MainActor final class FakeUpdatePort: AppUpdatePort {
    var isAvailable: Bool { true }
    var versionInfo: AppVersionInfo
    var automaticallyChecksForUpdates: Bool
    var lastUpdateCheckDate: Date?
    var canCheckForUpdates = true
    var nextCheckDate: Date?
    private(set) var checkCount = 0
    private(set) var startCount = 0
    /// Runs inside `start()`, so a test can look at the windows at the moment the updater starts.
    var onStart: (@MainActor () -> Void)?
    private var observers: [@MainActor () -> Void] = []

    init(version: String? = "2.0.0", build: String? = "40", automatic: Bool = false,
         lastCheck: Date? = nil, nextCheckDate: Date? = nil) {
        var info: [String: Any] = [:]
        info["CFBundleShortVersionString"] = version
        info["CFBundleVersion"] = build
        versionInfo = AppVersionInfo(infoDictionary: info)
        automaticallyChecksForUpdates = automatic
        lastUpdateCheckDate = lastCheck
        self.nextCheckDate = nextCheckDate
    }

    func checkForUpdates() {
        checkCount += 1
        lastUpdateCheckDate = nextCheckDate
        notify()
    }

    func start() {
        startCount += 1
        onStart?()
    }

    func observe(_ onChange: @escaping @MainActor () -> Void) {
        observers.append(onChange)
    }

    /// A change made outside Settings (Sparkle's own prompt, an update cycle), announced to observers.
    func simulateExternal(automatic: Bool? = nil, date: Date?? = nil, canCheck: Bool? = nil) {
        if let automatic { automaticallyChecksForUpdates = automatic }
        if let canCheck { canCheckForUpdates = canCheck }
        if let date { lastUpdateCheckDate = date }
        notify()
    }

    private func notify() { observers.forEach { $0() } }
}
