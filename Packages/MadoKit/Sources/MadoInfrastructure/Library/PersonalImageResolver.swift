import Foundation
import MadoCore

/// Checks a remembered image against its Access Root on every call; nothing is memoized, so a
/// revoked root or a moved file is reported as such and never answered from an earlier result.
public struct PersonalImageResolver: Sendable {
    private let access: FileAccess
    public init(access: FileAccess) { self.access = access }

    /// Throws only `CancellationError`.
    public func resolve(_ ref: PersonalImageRef) async throws -> PersonalImageAvailability {
        do {
            let root = try await access.probeRootURL(ref.rootID)
            return try await access.withLease(.root(ref.rootID, file: root)) { lease in
                // A scope can still start for a deleted root's bookmark; the root itself must be a folder.
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: lease.url.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { return .revoked }
                let file = lease.url.appendingPathComponent(ref.relativePath)
                // A different file at the path has another file number: missing, never its pixels.
                // A delete-and-create that reuses the number can still pass as present (GRID-12 limit).
                guard AccessBoundary.contains(file, in: lease.url), let number = Self.fingerprint(of: file),
                      number == ref.fileNumber else { return .missing }
                return .present(file)
            }
        } catch is CancellationError {
            // A superseded resolution has no answer; it never reports the root as revoked.
            throw CancellationError()
        } catch {
            return .revoked
        }
    }

    /// The regular file's number at the link-resolved path, or nil. The caller holds a lease covering it.
    public static func fingerprint(of fileURL: URL) -> UInt64? {
        let path = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    }
}
