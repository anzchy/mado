import Foundation
import Observation
import MadoCore

public enum ViewerImagePhase: Sendable { case idle, opening, refining, settled, detailLimited, failed }
public struct PresentedImage: Sendable {
    public let fileURL: URL
    public let key: RenderKey
    public var name: String { fileURL.lastPathComponent }
}

/// One per Session; shared decoding and lease services arrive through the opener.
@MainActor @Observable public final class ViewerImageLoader {
    public typealias Opener = @MainActor @Sendable () async throws -> AccessImageSource
    public weak var host: (any ViewerImageHost)?
    public private(set) var generation = UUID()
    public private(set) var phase: ViewerImagePhase = .idle
    public private(set) var presented: PresentedImage?
    public private(set) var failure: (any Error)?
    public private(set) var preparedKey: RenderKey?
    private let binding = UUID()
    private var source: AccessImageSource?
    var loadTask: Task<Void, Never>?
    private var firstPreview: UUID?
    private let trace: (any FirstPreviewTracing)?
    private let presentation: (any ImagePresentationPinning)?
    public convenience init() { self.init(trace: nil) }
    public init(trace: (any FirstPreviewTracing)?, presentation: (any ImagePresentationPinning)? = nil) {
        self.trace = trace; self.presentation = presentation
    }
    private var revisionRetryUsed = false
    private var deliveredDetailMaximum = 0
    private var desiredMaximum = 0
    private var progress = CanvasDecodeProgress()
    private var loading = false
    public private(set) var fileURL: URL?
    private var opener: Opener?
    public func open(_ fileURL: URL, maximumPixelSize: Int, opener: @escaping Opener) {
        finishFirstPreview(.cancelled)
        retire()
        generation = UUID()
        firstPreview = generation
        trace?.begin(generation, fileURL: fileURL)
        loading = false; revisionRetryUsed = false
        phase = .opening; presented = nil; failure = nil; preparedKey = nil
        source = nil
        self.fileURL = fileURL; self.opener = opener
        desiredMaximum = max(1, maximumPixelSize); progress = CanvasDecodeProgress(); deliveredDetailMaximum = 0
        host?.beginImageOpening()
        schedule()
    }
    private func schedule() {
        guard let fileURL, let opener else { return }
        loading = true
        let token = PresentationToken(binding: binding, generation: generation)
        loadTask = Task { await load(fileURL, opener: opener, token: token) }
    }
    private func load(_ fileURL: URL, opener: Opener, token: PresentationToken) async {
        while true {
            do {
                let source: AccessImageSource
                if let existing = self.source { source = existing }
                else {
                    source = try await opener()
                    guard token.generation == generation else { await source.close(); return }
                    self.source = source
                }
                while let maximum = progress.nextMaximum(desired: desiredMaximum),
                      !progress.previewCompleted || deliveredDetailMaximum == 0 || maximum > max(progress.completedMaximum, deliveredDetailMaximum) {
                    let preview = !progress.previewCompleted
                    let (request, image) = try await source.image(maximumPixelSize: maximum, isPreview: preview)
                    guard token == PresentationToken(binding: binding, generation: generation) else { return }
                    preparedKey = request.renderKey
                    guard let key = preparedKey, image.itemID == key.itemID, image.revision == key.revision else {
                        throw ImageLoadError(.sourceChanged, itemID: preparedKey?.itemID, revision: image.revision)
                    }
                    await presentation?.pin(key, image: image)
                    guard token.generation == generation, !Task.isCancelled else {
                        await presentation?.unpin(key)
                        return
                    }
                    let previous = presented?.key
                    progress.completed(image, isPreview: preview)
                    if !preview { deliveredDetailMaximum = max(deliveredDetailMaximum, maximum) }
                    presented = PresentedImage(fileURL: fileURL, key: key)
                    host?.installImage(image, fileURL: fileURL)
                    guard token.generation == generation else {
                        if let previous { await presentation?.unpin(previous) }
                        return
                    }
                    finishFirstPreview(.success)
                    phase = .refining
                    if let previous {
                        await presentation?.unpin(previous)
                        guard token.generation == generation else { return }
                    }
                }
                phase = .settled
                break
            } catch {
                guard token.generation == generation else { return }
                if (error as? ImageLoadError)?.kind == .sourceChanged, !revisionRetryUsed {
                    revisionRetryUsed = true
                    releasePresentation()
                    preparedKey = nil; presented = nil; progress = CanvasDecodeProgress(); deliveredDetailMaximum = 0
                    phase = .opening
                    host?.beginImageOpening()
                    let old = source; source = nil
                    await old?.close()
                    guard token.generation == generation else { return }
                    continue
                }
                if (error as? ImageLoadError)?.kind == .resourceLimit, presented != nil {
                    failure = error; phase = .detailLimited
                    // AccessImageSource closes on an error. Renew the display lease without decoding again.
                    do {
                        let replacement = try await opener()
                        guard token.generation == generation else { await replacement.close(); return }
                        self.source = replacement
                    } catch {
                        guard token.generation == generation else { return }
                        releasePresentation()
                        failure = error; presented = nil; phase = .failed
                        host?.imageLoadFailed(error)
                    }
                    break
                }
                releasePresentation()
                failure = error; presented = nil; phase = .failed
                finishFirstPreview(.failed)
                host?.imageLoadFailed(error)
                break
            }
        }
        if token.generation == generation { loading = false }
    }
    public func requireResolution(_ maximum: Int) {
        guard phase != .idle, phase != .failed, phase != .detailLimited else { return }
        desiredMaximum = max(1, maximum)
        guard progress.previewCompleted, deliveredDetailMaximum == 0 || desiredMaximum > max(progress.completedMaximum, deliveredDetailMaximum) else { return }
        phase = .refining
        if !loading { schedule() }
    }
    private func retire() {
        loadTask?.cancel()
        releasePresentation()
        let old = source; source = nil
        Task { await old?.close() }
    }
    private func releasePresentation() {
        guard let key = presented?.key, let presentation else { return }
        presented = nil
        Task { await presentation.unpin(key) }
    }
    private func finishFirstPreview(_ outcome: FirstPreviewOutcome) {
        guard let id = firstPreview else { return }
        firstPreview = nil
        trace?.end(id, outcome: outcome)
    }
    public func close() {
        finishFirstPreview(.cancelled)
        retire()
        generation = UUID(); loading = false
        desiredMaximum = 0; fileURL = nil; opener = nil
        presented = nil; preparedKey = nil; failure = nil; phase = .idle
    }

}

extension ViewerSession {
    public func openImage(_ fileURL: URL, maximumPixelSize: Int, opener: @escaping ViewerImageLoader.Opener) {
        imageLoader.open(fileURL, maximumPixelSize: maximumPixelSize, opener: opener)
    }
    public func requireImageResolution(_ maximum: Int) { imageLoader.requireResolution(maximum) }
    public func closeImage() { imageLoader.close() }
}
