import Foundation
import Testing
import MadoCore
@testable import MadoApplication

@MainActor final class PreviewRecorder: FirstPreviewTracing {
    var starts: [UUID] = []
    var ends: [(UUID, FirstPreviewOutcome)] = []
    func begin(_ id: UUID, fileURL: URL) { starts.append(id) }
    func end(_ id: UUID, outcome: FirstPreviewOutcome) { ends.append((id, outcome)) }
}
@MainActor @Test func loadFirstPreviewBalancesSuccessSupersededAndFailure() async {
    let trace = PreviewRecorder(), loader = ViewerImageLoader(trace: trace), host = LoadHost()
    let session = ViewerSession(imageLoader: loader), pipeline = LoadPipeline(), access = LoadLeases()
    loader.host = host
    let file = URL(fileURLWithPath: "/trace.png")
    let opener: ViewerImageLoader.Opener = { try await AccessImageSource.open(.fileGrant(file), access: access, pipeline: pipeline) }
    session.openImage(file, maximumPixelSize: 512, opener: opener)
    await loader.loadTask?.value
    session.openImage(file, maximumPixelSize: 512, opener: opener)
    let superseded = loader.loadTask
    session.openImage(file, maximumPixelSize: 512) { throw FileAccessError.startFailed }
    await loader.loadTask?.value; await superseded?.value
    #expect(trace.starts.count == 3)
    #expect(Set(trace.starts).count == 3)
    #expect(trace.ends.map(\.1) == [.success, .cancelled, .failed])
    #expect(trace.starts == trace.ends.map(\.0))
    session.closeImage()
    #expect(trace.ends.count == 3)
}
