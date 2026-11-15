import Foundation

public protocol CaptureScreenPort: Sendable {
    func captureCurrentDisplayPNG() async throws -> Data
    func capturePNG(request: CaptureRequest) async throws -> Data
}

public protocol CaptureFilePort: Sendable {
    /// Creates a new file. An existing name must throw `CaptureFileError.alreadyExists`.
    func writeNewPNG(_ data: Data, named: String) async throws -> URL
}

public enum CaptureFileError: Error, Equatable, Sendable {
    case alreadyExists
}

public enum CaptureSessionError: Error, Equatable, Sendable {
    case busy
}

public struct CaptureResult: Sendable {
    public let url: URL
    public let png: Data
}

public actor CaptureSession {
    private let screen: any CaptureScreenPort
    private let files: any CaptureFilePort
    private let now: @Sendable () -> Date
    private let timeZone: TimeZone?
    private var isCapturing = false
    /// The Capture Folder as the thumbnail's status line shows it, with the home folder as `~`.
    public nonisolated let folderDisplay: String

    public init(screen: any CaptureScreenPort, files: any CaptureFilePort,
                now: @escaping @Sendable () -> Date = Date.init,
                timeZone: TimeZone? = nil, folderDisplay: String = "~/Downloads") {
        self.folderDisplay = folderDisplay
        self.screen = screen
        self.files = files
        self.now = now
        self.timeZone = timeZone
    }

    public func capture() async throws -> URL {
        try await captureResult(request: nil).url
    }

    public func capture(request: CaptureRequest) async throws -> URL {
        try await captureResult(request: request).url
    }

    /// One Capture under the 「截图之后」 switches: writes a file only when saving is on and touches the
    /// clipboard only when copying is on. A failed write still returns the Capture, unsaved.
    public func capture(request: CaptureRequest?, policy: CaptureOutputPolicy,
                        clipboard: any CaptureClipboardPort) async throws -> CaptureThumbnailState {
        try await admitted {
            let png = try await self.grab(request)
            var state = CaptureThumbnailState(png: png, savedURL: nil, clipboard: .notCopied,
                                              folderDisplay: self.folderDisplay)
            if policy.savesToFolder {
                do { state.savedURL = try await self.writeUniquePNG(png) }
                catch { try Task.checkCancellation(); state.saveFailed = true }
            }
            if policy.copiesToClipboard {
                state.clipboard = await clipboard.writePNG(png) ? .copied : .copyFailed
            }
            return state
        }
    }

    /// Saves an unsaved Capture with the same naming rule as a Capture.
    public func save(_ png: Data) async throws -> URL {
        try await writeUniquePNG(png)
    }

    public func captureResult(request: CaptureRequest?) async throws -> CaptureResult {
        try await admitted {
            let png = try await self.grab(request)
            return CaptureResult(url: try await self.writeUniquePNG(png), png: png)
        }
    }

    /// One Capture at a time.
    private func admitted<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        guard !isCapturing else { throw CaptureSessionError.busy }
        isCapturing = true
        defer { isCapturing = false }
        return try await body()
    }

    private func grab(_ request: CaptureRequest?) async throws -> Data {
        let png: Data
        if let request { png = try await screen.capturePNG(request: request) }
        else { png = try await screen.captureCurrentDisplayPNG() }
        try Task.checkCancellation()
        return png
    }

    /// `mado-YYYYMMDDHHMMSS.png`, then `-2`, `-3` … in the same second; never overwrites (#682).
    private func writeUniquePNG(_ png: Data) async throws -> URL {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone ?? .current
        formatter.dateFormat = "yyyyMMddHHmmss"
        let stem = "mado-\(formatter.string(from: now()))"
        var suffix = 1
        var saved: URL?
        repeat {
            try Task.checkCancellation()
            let name = suffix == 1 ? "\(stem).png" : "\(stem)-\(suffix).png"
            do {
                saved = try await files.writeNewPNG(png, named: name)
            } catch CaptureFileError.alreadyExists {
                suffix += 1
            }
        } while saved == nil
        return saved!
    }
}
