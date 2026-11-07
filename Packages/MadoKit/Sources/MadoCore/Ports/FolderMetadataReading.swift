import Foundation

/// Called off the main actor while an authorized root lease is held.
public protocol FolderMetadataReading: Sendable {
    func read(_ url: URL) throws -> FolderImageMetadata
}
