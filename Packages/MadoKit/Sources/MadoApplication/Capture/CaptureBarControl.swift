public enum CaptureBarIdentity {
    public static let bundleID = "io.github.anzchy.mado.capture-helper"
    public static let appGroupID = "GRT84NAK4T.io.github.anzchy.mado.capture"
    public static let enabledKey = "captureBar.enabled.v1"
    public static let permissionKey = "captureBar.permission.v1"
    public static let permissionRequestedKey = "captureBar.permissionRequested.v1"
    public static let switchChangedNotification = "io.github.anzchy.mado.capture.switchChanged"
}

public enum CapturePermissionState: String, Sendable {
    case granted, denied, notAsked
}

public protocol CaptureBarPreferencePort: Sendable {
    func isCaptureBarEnabled() async -> Bool
    func setCaptureBarEnabled(_ enabled: Bool) async
    func capturePermissionState() async -> CapturePermissionState?
}

public extension CaptureBarPreferencePort {
    func capturePermissionState() async -> CapturePermissionState? { nil }
}

public protocol CaptureBarExitPort: Sendable {
    func exitCaptureBar() async
}

public actor CaptureHelperLifecycle {
    private let preferences: any CaptureBarPreferencePort
    private let exit: any CaptureBarExitPort

    public init(preferences: any CaptureBarPreferencePort, exit: any CaptureBarExitPort) {
        self.preferences = preferences
        self.exit = exit
    }

    public func switchChanged() async {
        if !(await preferences.isCaptureBarEnabled()) { await exit.exitCaptureBar() }
    }
}

public protocol CaptureBarProcessPort: Sendable {
    func startCaptureBar() async throws
    func stopCaptureBar() async throws
}

public actor CaptureBarControl {
    private let preferences: any CaptureBarPreferencePort
    private let process: any CaptureBarProcessPort
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    private func release() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().resume() }
    }

    public init(preferences: any CaptureBarPreferencePort, process: any CaptureBarProcessPort) {
        self.preferences = preferences
        self.process = process
    }

    public func setEnabled(_ enabled: Bool) async throws {
        await acquire()
        defer { release() }
        await preferences.setCaptureBarEnabled(enabled)
        if enabled {
            do {
                try await process.startCaptureBar()
            } catch {
                await preferences.setCaptureBarEnabled(false)
                throw error
            }
        } else {
            do {
                try await process.stopCaptureBar()
            } catch {
                await preferences.setCaptureBarEnabled(true)
                throw error
            }
        }
    }

    public func restoreOnMadoLaunch() async throws {
        await acquire()
        defer { release() }
        if await preferences.isCaptureBarEnabled() {
            try await process.startCaptureBar()
        } else {
            try await process.stopCaptureBar()
        }
    }
}
