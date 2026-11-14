import Foundation
import MadoApplication

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
