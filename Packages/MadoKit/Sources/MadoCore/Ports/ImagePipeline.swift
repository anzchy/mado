import CoreGraphics
import Foundation

public enum DecodePriority: Int, Sendable { case prefetch, visible, current }

public struct ImageDecodeRequest: Sendable {
    public let accessPermit: AccessWorkPermit?
    public let identityRoot: ItemIdentityRoot?
    public let isPreview: Bool
    /// Pixel allocation ceiling for this admitted decode, rechecked against its own header.
    public let sourceByteBudget: Int?
    public let renderKey: RenderKey?
    public let priority: DecodePriority
    public let fileURL: URL
    /// Longest edge in pixels; callers convert viewport points using backing scale.
    public let maximumPixelSize: Int

    public init(fileURL: URL, maximumPixelSize: Int, renderKey: RenderKey? = nil, priority: DecodePriority = .current, sourceByteBudget: Int? = nil, isPreview: Bool = false, identityRoot: ItemIdentityRoot? = nil, accessPermit: AccessWorkPermit? = nil) {
        self.accessPermit = accessPermit
        self.identityRoot = identityRoot
        self.isPreview = isPreview
        self.sourceByteBudget = sourceByteBudget
        // The render identity includes the mode because embedded previews and image-derived pixels differ.
        self.renderKey = renderKey.map { RenderKey(itemID: $0.itemID, revision: $0.revision,
            maximumPixelSize: $0.maximumPixelSize, isPreview: isPreview, frameIndex: $0.frameIndex,
            policy: $0.policy, decoderVersion: $0.decoderVersion, purpose: $0.purpose) }
        self.priority = priority
        self.fileURL = fileURL
        self.maximumPixelSize = maximumPixelSize
    }
}

public struct DecodedImage: Sendable {
    public let accessPermit: AccessWorkPermit?
    public let itemID: ItemID?
    public let revision: FileRevision?
    public let formatIdentifier: String?
    public let image: CGImage
    public let sourcePixelSize: CGSize

    public init(image: CGImage, sourcePixelSize: CGSize, formatIdentifier: String? = nil, revision: FileRevision? = nil, itemID: ItemID? = nil, accessPermit: AccessWorkPermit? = nil) {
        self.accessPermit = accessPermit
        self.itemID = itemID
        self.revision = revision
        self.formatIdentifier = formatIdentifier
        self.image = image
        self.sourcePixelSize = sourcePixelSize
    }
}

/// Request boundary: admission/cancellation policy can replace the first executor.
public protocol ImagePipeline: Sendable {
    func request(for fileURL: URL, maximumPixelSize: Int) async throws -> ImageDecodeRequest
    func request(for fileURL: URL, maximumPixelSize: Int, identityRoot: ItemIdentityRoot?) async throws -> ImageDecodeRequest
    func image(for request: ImageDecodeRequest) async throws -> DecodedImage
}

// Existing non-scoped pipelines remain source compatible.
extension ImagePipeline {
    public func request(for fileURL: URL, maximumPixelSize: Int, identityRoot: ItemIdentityRoot?) async throws -> ImageDecodeRequest {
        try await request(for: fileURL, maximumPixelSize: maximumPixelSize)
    }
}
