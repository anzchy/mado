public enum CaptureBarIdentity {
    public static let bundleID = "io.github.anzchy.mado.capture-helper"
    public static let appGroupID = "GRT84NAK4T.io.github.anzchy.mado.capture"
    public static let enabledKey = "captureBar.enabled.v1"
}

public protocol CaptureBarPreferencePort: Sendable {
    func isCaptureBarEnabled() async -> Bool
    func setCaptureBarEnabled(_ enabled: Bool) async
}

public protocol CaptureBarProcessPort: Sendable {
    func startCaptureBar() async throws
    func stopCaptureBar() async throws
}

public actor CaptureBarControl {
    private let preferences: any CaptureBarPreferencePort
    private let process: any CaptureBarProcessPort

    public init(preferences: any CaptureBarPreferencePort, process: any CaptureBarProcessPort) {
        self.preferences = preferences
        self.process = process
    }

    public func setEnabled(_ enabled: Bool) async throws {
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
        if await preferences.isCaptureBarEnabled() {
            try await process.startCaptureBar()
        } else {
            try await process.stopCaptureBar()
        }
    }
}
