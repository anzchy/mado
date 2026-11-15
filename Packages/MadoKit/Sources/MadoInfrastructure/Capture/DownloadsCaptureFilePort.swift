import Foundation
import MadoApplication

/// Writes Captures into a fixed folder or, with `folder:`, into the Capture Folder resolved before each write (#685).
public struct DownloadsCaptureFilePort: CaptureFilePort {
    private let directory: @Sendable () async -> URL
    private let display: (@Sendable () async -> String)?

    public init(directory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]) {
        self.directory = { directory }
        self.display = nil
    }

    public init(folder: @escaping @Sendable () async -> URL, display: @escaping @Sendable () async -> String) {
        self.directory = folder
        self.display = display
    }

    public func folderDisplay() async -> String? { await display?() }

    public func writeNewPNG(_ data: Data, named: String) async throws -> URL {
        let url = await directory().appendingPathComponent(named, isDirectory: false)
        do {
            try data.write(to: url, options: .withoutOverwriting)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            throw CaptureFileError.alreadyExists
        }
        return url
    }
}
