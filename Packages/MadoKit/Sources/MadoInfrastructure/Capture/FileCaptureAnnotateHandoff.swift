import Foundation
import MadoApplication

/// i694-fix1: the Annotate hand-off record as a JSON file, by default in the App Group container the capture helper
/// and Mado share. It backs up the App Group defaults (`CaptureAnnotateHandoffStores`).
public final class FileCaptureAnnotateHandoff: CaptureAnnotateHandoffPort, @unchecked Sendable {
    public static let fileName = "captureAnnotateHandoff.json"
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// The App Group container; nil when the system gives none for the group.
    public static func shared(fileManager: FileManager = .default) -> FileCaptureAnnotateHandoff? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: CaptureBarIdentity.appGroupID)
            .map(FileCaptureAnnotateHandoff.init(directory:))
    }

    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    /// Replaces the file atomically; a failure (no container, no space) leaves no record and is not reported.
    public func write(_ record: CaptureAnnotateHandoffRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Empties the file in place: Capture modules never delete files (#684), and an empty file holds no record.
    public func clear() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try? Data().write(to: fileURL, options: .atomic)
    }

    /// Reads and empties the record; a file that does not decode as one is emptied and ignored.
    public func take() -> CaptureAnnotateHandoffRecord? {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return nil }
        clear()
        return try? JSONDecoder().decode(CaptureAnnotateHandoffRecord.self, from: data)
    }
}

extension CaptureAnnotateHandoffStores {
    /// The App Group defaults and the App Group container file, whichever exist.
    public static func shared() -> CaptureAnnotateHandoffStores {
        CaptureAnnotateHandoffStores(defaults: UserDefaultsCaptureAnnotateHandoff.shared(), file: FileCaptureAnnotateHandoff.shared())
    }
}
