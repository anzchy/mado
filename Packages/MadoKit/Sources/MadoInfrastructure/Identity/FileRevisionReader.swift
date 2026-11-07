import Foundation
import MadoCore

/// Filesystem reads run on the header/decoder executor. No watcher generation or content hashing.
enum FileRevisionReader {
    static func read(_ url: URL) throws -> FileRevision {
        // Match identity resolution: lstat of a symlink describes the link, not the decoded image.
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let attributes = try FileManager.default.attributesOfItem(atPath: canonical.path)
        guard let size = attributes[.size] as? NSNumber else { throw ImageDecodeError.unreadableImage }
        let resource = try URLIdentityResourceReader().identity(for: canonical)
        let token = resource.map { ItemID.resource(volumeUUID: $0.volumeUUID, fileIdentifier: $0.fileIdentifier).stableEncoding }
        return FileRevision(byteCount: size.intValue, modificationDate: attributes[.modificationDate] as? Date,
                            resourceIdentifier: token)
    }
}
