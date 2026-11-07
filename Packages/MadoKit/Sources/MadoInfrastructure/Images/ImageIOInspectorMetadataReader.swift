import Foundation
import ImageIO
import MadoApplication
import MadoCore
import UniformTypeIdentifiers

/// Header and file attributes are read under the same security scope used for image decoding.
public struct ImageIOInspectorMetadataReader: InspectorMetadataReading {
    private let access: any AccessLeasing
    private let pipeline: (any ImagePipeline)?
    private let accessPermit: AccessWorkPermit?
    private let workerStarted: (@Sendable () -> Void)?
    public init(access: any AccessLeasing, pipeline: (any ImagePipeline)? = nil, accessPermit: AccessWorkPermit? = nil) {
        self.access = access; self.pipeline = pipeline; self.accessPermit = accessPermit; self.workerStarted = nil
    }
    init(access: any AccessLeasing, workerStarted: @escaping @Sendable () -> Void) {
        self.access = access; self.pipeline = nil; self.accessPermit = nil; self.workerStarted = workerStarted
    }
    public func read(_ url: URL, access request: AccessRequest) async throws -> InspectorMetadata {
        do {
            return try await access.withLease(request) { lease in
                try accessPermit?.check()
                let worker = Task.detached(priority: .utility) {
                    try Task.checkCancellation()
                    let attributes: URLResourceValues
                    do { attributes = try url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey]) }
                    catch {
                        let ns = error as NSError
                        throw ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoPermissionError
                            ? InspectorReadError.noPermission : InspectorReadError.unreadable
                    }
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                          CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
                          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
                        throw InspectorReadError.unreadable
                    }
                    let width = properties[kCGImagePropertyPixelWidth] as? Int
                    let height = properties[kCGImagePropertyPixelHeight] as? Int
                    let size = attributes.fileSize.map(Int64.init)
                    try Task.checkCancellation()
                    return InspectorMetadata(pixelWidth: width, pixelHeight: height,
                        typeIdentifier: CGImageSourceGetType(source) as String?, creationDate: attributes.creationDate,
                        modificationDate: attributes.contentModificationDate, byteSize: size)
                }
                workerStarted?()
                let metadata = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                let thumbnail = try await thumbnail(url, lease: lease, metadata: metadata)
                try Task.checkCancellation()
                try accessPermit?.check()
                return InspectorMetadata(pixelWidth: metadata.pixelWidth, pixelHeight: metadata.pixelHeight,
                    typeIdentifier: metadata.typeIdentifier, creationDate: metadata.creationDate,
                    modificationDate: metadata.modificationDate, byteSize: metadata.byteSize, thumbnailData: thumbnail)
            }
        } catch FileAccessError.needsReconnection, FileAccessError.outsideRoot, FileAccessError.startFailed {
            throw InspectorReadError.noPermission
        } catch let error as InspectorReadError {
            throw error
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? ImageLoadError)?.kind == .cancelled {
                throw CancellationError()
            }
            throw InspectorReadError.unreadable
        }
    }

    private func thumbnail(_ url: URL, lease: AccessLease, metadata: InspectorMetadata) async throws -> Data? {
        guard let pipeline, let width = metadata.pixelWidth, let height = metadata.pixelHeight,
              width > 0, height > 0, Int64(width) <= 40_000_000 / Int64(height) else { return nil }
        do {
            let root = lease.rootID.map { ItemIdentityRoot(id: $0, url: lease.url) }
            let prepared = try await pipeline.request(for: url, maximumPixelSize: 240, identityRoot: root)
            let request = ImageDecodeRequest(fileURL: url, maximumPixelSize: 240, renderKey: prepared.renderKey,
                priority: .visible, identityRoot: root, accessPermit: accessPermit)
            let decoded = try await pipeline.image(for: request)
            // The cache accounts for resident pixels while PNG encoding consumes them.
            let pinning = pipeline as? any ImagePresentationPinning
            let acquiredKey: RenderKey?
            if let key = request.renderKey, let pinning {
                guard await pinning.pin(key, image: decoded) else { throw CancellationError() }
                acquiredKey = key
            } else { acquiredKey = nil }
            let data = NSMutableData()
            let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
            let thumbnail: Data?
            if let destination {
                CGImageDestinationAddImage(destination, decoded.image, nil)
                thumbnail = CGImageDestinationFinalize(destination) ? data as Data : nil
            } else { thumbnail = nil }
            if let acquiredKey { await pinning?.unpin(acquiredKey) }
            try Task.checkCancellation()
            try accessPermit?.check()
            return thumbnail
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? ImageLoadError)?.kind == .cancelled {
                throw CancellationError()
            }
            if let accessError = error as? FileAccessError { throw accessError }
            if AccessReadFailure.isPermissionDenied(error) {
                throw InspectorReadError.noPermission
            }
            return nil
        }
    }
}
