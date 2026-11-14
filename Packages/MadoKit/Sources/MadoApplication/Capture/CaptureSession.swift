import Foundation

public protocol CaptureScreenPort: Sendable {
    func captureCurrentDisplayPNG() async throws -> Data
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

public actor CaptureSession {
    private let screen: any CaptureScreenPort
    private let files: any CaptureFilePort
    private let now: @Sendable () -> Date
    private let timeZone: TimeZone?
    private var isCapturing = false

    public init(screen: any CaptureScreenPort, files: any CaptureFilePort,
                now: @escaping @Sendable () -> Date = Date.init,
                timeZone: TimeZone? = nil) {
        self.screen = screen
        self.files = files
        self.now = now
        self.timeZone = timeZone
    }

    public func capture() async throws -> URL {
        guard !isCapturing else { throw CaptureSessionError.busy }
        isCapturing = true
        defer { isCapturing = false }

        let png = try await screen.captureCurrentDisplayPNG()
        try Task.checkCancellation()
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

public struct DownloadsCaptureFilePort: CaptureFilePort {
    private let directory: URL

    public init(directory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]) {
        self.directory = directory
    }

    public func writeNewPNG(_ data: Data, named: String) async throws -> URL {
        let url = directory.appendingPathComponent(named, isDirectory: false)
        do {
            try data.write(to: url, options: .withoutOverwriting)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            throw CaptureFileError.alreadyExists
        }
        return url
    }
}
