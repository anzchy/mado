import Foundation
import Observation
import MadoCore

public struct InspectorMetadata: Equatable, Sendable {
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public let typeIdentifier: String?
    public let creationDate: Date?
    public let modificationDate: Date?
    public let byteSize: Int64?
    public let thumbnailData: Data?
    public init(pixelWidth: Int? = nil, pixelHeight: Int? = nil, typeIdentifier: String? = nil,
                creationDate: Date? = nil, modificationDate: Date? = nil, byteSize: Int64? = nil,
                thumbnailData: Data? = nil) {
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.typeIdentifier = typeIdentifier
        self.creationDate = creationDate; self.modificationDate = modificationDate; self.byteSize = byteSize
        self.thumbnailData = thumbnailData
    }
}

public enum InspectorReadError: Error, Equatable, Sendable { case noPermission, unreadable }
public protocol InspectorMetadataReading: Sendable {
    func read(_ url: URL, access: AccessRequest) async throws -> InspectorMetadata
}

public enum InspectorValue: Equatable, Sendable {
    case loading, known(InspectorMetadata), unknown, unreadable, noPermission
}

@MainActor @Observable public final class InspectorModel {
    public private(set) var name: String?
    public private(set) var value: InspectorValue = .unknown
    @ObservationIgnored public var onReadFailure: (@MainActor (URL, AccessRequest, any Error) -> Void)?
    private let reader: any InspectorMetadataReading
    private var key: Key?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private struct Key: Equatable {
        let id: ItemID?
        let url: URL
        let access: AccessRequest
        let revision: String?
    }
    public init(reader: any InspectorMetadataReading) { self.reader = reader }
    public func select(itemID: ItemID?, url: URL?, access: AccessRequest?, revision: String? = nil, refresh: Bool = false) {
        guard let url, let access else {
            key = nil; generation = UUID(); task?.cancel(); task = nil; name = nil; value = .unknown
            return
        }
        let next = Key(id: itemID, url: url, access: access, revision: revision)
        guard refresh || key != next else { return }
        key = next; generation = UUID(); task?.cancel()
        name = url.lastPathComponent; value = .loading
        let token = generation
        let failureCallback = onReadFailure
        task = Task {
            do {
                let metadata = try await reader.read(url, access: access)
                guard generation == token, !Task.isCancelled else { return }
                value = .known(metadata)
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                value = (error as? InspectorReadError) == .noPermission ? .noPermission : .unreadable
                failureCallback?(url, access, error)
            }
        }
    }
}
