import Foundation
import Testing
import MadoCore
@testable import MadoApplication

private struct StatusExample: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let phase: ViewerImagePhase
    let name: String
    let failure: (any Error)?
    let expected: ViewerImageStatus
    // Keep NSError system descriptions out of runner diagnostics.
    var description: String { "\(phase) \(name) → \(expected)" }
    var debugDescription: String { description }
}

private struct UntypedStatusError: Error {}

private let statusExamples: [StatusExample] = [
    .init(phase: .idle, name: "A.png", failure: nil, expected: .empty),
    .init(phase: .opening, name: "A.png", failure: nil, expected: .loading("A.png")),
    .init(phase: .opening, name: "B.jpg", failure: nil, expected: .loading("B.jpg")),
    .init(phase: .refining, name: "A.png", failure: nil, expected: .showing),
    .init(phase: .settled, name: "B.jpg", failure: nil, expected: .showing),
    .init(phase: .detailLimited, name: "A.png", failure: ImageLoadError(.resourceLimit), expected: .detailLimited),
    .init(phase: .failed, name: "B.jpg", failure: ImageLoadError(.corruptImage), expected: .failed(.corruptImage, "B.jpg")),
    .init(phase: .failed, name: "A.png", failure: ImageLoadError(.unsupportedFormat), expected: .failed(.unsupportedFormat, "A.png")),
    .init(phase: .failed, name: "B.jpg", failure: ImageLoadError(.resourceLimit), expected: .failed(.resourceLimit, "B.jpg")),
    .init(phase: .failed, name: "A.png", failure: ImageLoadError(.sourceChanged), expected: .failed(.sourceChanged, "A.png")),
    .init(phase: .failed, name: "B.jpg", failure: FileAccessError.startFailed, expected: .failed(.access, "B.jpg")),
    .init(phase: .failed, name: "B.jpg", failure: UntypedStatusError(), expected: .failed(.corruptImage, "B.jpg")),
    .init(phase: .failed, name: "B.jpg", failure: nil, expected: .failed(.corruptImage, "B.jpg")),
    .init(phase: .failed, name: "B.jpg", failure: NSError(domain: "unrelated", code: 13), expected: .failed(.corruptImage, "B.jpg")),
    .init(phase: .failed, name: "B.jpg", failure: NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError), expected: .failed(.corruptImage, "B.jpg")),
    .init(phase: .failed, name: "B.jpg", failure: NSError(domain: NSPOSIXErrorDomain, code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing image fixture"]), expected: .failed(.corruptImage, "B.jpg")),
    .init(phase: .failed, name: "A.png", failure: NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError), expected: .failed(.access, "A.png")),
    .init(phase: .failed, name: "A.png", failure: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError), expected: .failed(.access, "A.png")),
    .init(phase: .failed, name: "B.jpg", failure: NSError(domain: NSPOSIXErrorDomain, code: 13), expected: .failed(.access, "B.jpg")),
    .init(phase: .failed, name: "B.jpg", failure: NSError(domain: NSPOSIXErrorDomain, code: 1), expected: .failed(.access, "B.jpg")),
    .init(phase: .failed, name: "B.jpg", failure: ImageLoadError(.cancelled), expected: .empty)
]

@Test(arguments: statusExamples) private func statesStatusPhaseAndFailureTable(_ example: StatusExample) {
    #expect(ViewerImageStatus(phase: example.phase, fileName: example.name, failure: example.failure) == example.expected)
}

@Test(.timeLimit(.minutes(2))) @MainActor func statesStatusNeverPresentsPreviousImage() async {
    let session = ViewerSession(), pipeline = LoadPipeline(), access = LoadLeases(), host = LoadHost()
    session.imageLoader.host = host
    #expect(session.imageStatus == .empty)
    let a = URL(fileURLWithPath: "/A.png")
    session.openImage(a, maximumPixelSize: 512) {
        try await AccessImageSource.open(.fileGrant(a), access: access, pipeline: pipeline)
    }
    #expect(session.imageStatus == .loading("A.png"))
    await session.imageLoader.loadTask?.value
    #expect(session.imageStatus == .showing)
    #expect(session.imageLoader.presented?.fileURL == a)
    let generationA = session.imageLoader.generation

    let b = URL(fileURLWithPath: "/B.jpg")
    session.openImage(b, maximumPixelSize: 512) { throw ImageLoadError(.corruptImage) }
    #expect(session.imageStatus == .loading("B.jpg"))
    #expect(session.imageLoader.presented == nil)
    #expect(session.imageLoader.generation != generationA)
    await session.imageLoader.loadTask?.value
    #expect(session.imageStatus == .failed(.corruptImage, "B.jpg"))
    #expect(session.imageLoader.presented == nil)
    #expect(host.names == ["A.png", "A.png"])
    #expect(host.failures == 1)

    session.closeImage()
    #expect(session.imageStatus == .empty)
    #expect(session.imageLoader.presented == nil)
    #expect(session.imageLoader.failure == nil)

    let c = URL(fileURLWithPath: "/C.png")
    session.openImage(c, maximumPixelSize: 512) {
        try await AccessImageSource.open(.fileGrant(c), access: access, pipeline: pipeline)
    }
    #expect(session.imageStatus == .loading("C.png"))
    await session.imageLoader.loadTask?.value
    #expect(session.imageStatus == .showing)
    #expect(session.imageLoader.presented?.fileURL == c)
    #expect(host.names == ["A.png", "A.png", "C.png", "C.png"])
    session.closeImage()
}
