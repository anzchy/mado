import Foundation
import Testing
import PicseeCore
@testable import PicseeApplication

@MainActor final class InputFileSetHost: ViewerSessionNavigationHost, ViewerInputHost, ViewerImageHost {
    let session = ViewerSession()
    let leases = InputLeases()
    let pipeline: any ImagePipeline
    let root = AccessRootID()
    var covered = Set<URL>()
    var opens: [(URL, AccessRequest?)] = []
    var notices: [ViewerInputNotice] = []
    var folders: [URL] = []
    var navigation: [NavigationDirection] = []
    var hasImage = false
    var canNavigate = true
    var title = "Mado"
    var retry: ViewerRetryIntent?
    var appliedFocus: [FocusContext] = []
    init(pipeline: any ImagePipeline = InputPipeline()) {
        self.pipeline = pipeline
        session.host = self; session.imageLoader.host = self
    }
    func openInputImage(_ url: URL, accessRequest: AccessRequest?) {
        opens.append((url, accessRequest)); retry = ViewerRetryIntent(fileURL: url, accessRequest: accessRequest)
        let request = accessRequest ?? (covered.contains(url) ? .root(root, file: url) : .fileGrant(url))
        let leases = leases, pipeline = pipeline
        session.openImage(url, maximumPixelSize: 64) { try await AccessImageSource.open(request, access: leases, pipeline: pipeline) }
    }
    func showInputNotice(_ notice: ViewerInputNotice) { notices.append(notice) }
    func promptForInputFolder(_ folder: URL) { folders.append(folder) }
    func beginImageOpening() { hasImage = false; title = "Mado" }
    func installImage(_ image: DecodedImage, fileURL: URL) { hasImage = true; title = fileURL.lastPathComponent }
    func imageLoadFailed(_ error: any Error) { hasImage = false; title = "Mado"; _ = session.dismissCancelledImageFailure(error) }
    func navigate(_ direction: NavigationDirection) { navigation.append(direction) }
    func performCanvas(_ command: CommandID, from entry: CommandEntry) { }
    func performCanvasZoom(_ command: CommandID, from entry: CommandEntry) -> Double? { nil }
    func requestOpen() { }
    func applyFocus(_ focus: FocusContext) { appliedFocus.append(focus) }
    func showInspector(_ visible: Bool) { }
    var admission: ViewerInputAdmission { ViewerInputAdmission(access: leases, pipeline: pipeline, maximumPixelSize: 64, rootCovering: { _ in nil }) }
    func input(_ urls: [URL], intent: AccessIntent) async {
        await session.openInput(urls, operation: intent.begin(), admission: admission, host: self)
        await session.imageLoader.loadTask?.value
    }
    func move(_ command: CommandID, entry: CommandEntry = .key) async {
        _ = CommandRouter().route(command, from: entry, to: session)
        await session.imageLoader.loadTask?.value
    }
    func finish() async { session.closeImage(); await leases.waitForDrain() }
}
private let setA = URL(fileURLWithPath: "/photos/A.png")
private let setB = URL(fileURLWithPath: "/photos/B.jpg")
private let setC = URL(fileURLWithPath: "/photos/C.png")
private let setD = URL(fileURLWithPath: "/photos/D.png")
private let setE = URL(fileURLWithPath: "/photos/E.png")

@Test func inputFileSetValueBoundsAndTraversalInvariant() {
    var empty = FilePreviewSet(files: [])
    #expect(empty.current == nil)
    #expect(empty.canMove(forward: true) == false)
    #expect(empty.canMove(forward: false) == false)
    #expect(empty.move(forward: true) == nil)
    #expect(empty.move(forward: false) == nil)
    var single = FilePreviewSet(files: [setA])
    #expect(single.current == setA)
    #expect(single.canMove(forward: false) == false)
    #expect(single.canMove(forward: true) == false)
    #expect(single.move(forward: true) == nil)
    #expect(single.move(forward: false) == nil)
    #expect(single.index == 0 && single.members == [setA])
    for count in 2...8 {
        let members = (0..<count).map { URL(fileURLWithPath: "/photos/image\($0).png") }
        var value = FilePreviewSet(files: members)
        for index in 1..<count {
            #expect(value.move(forward: true) == members[index])
            #expect(value.index == index)
            #expect(value.members == members)
        }
        #expect(value.move(forward: true) == nil)
        #expect(value.index == count - 1)
        for index in (0..<(count - 1)).reversed() {
            #expect(value.move(forward: false) == members[index])
            #expect(value.index == index)
            #expect(value.members == members)
        }
        #expect(value.current == members[0])
        #expect(value.move(forward: false) == nil)
        #expect(value.index == 0)
    }
}

@Test @MainActor func inputFileSetMovesEnabledAndNeverFallsBackToFolderNavigation() async {
    for entry in [CommandEntry.key, .menu, .button] {
        let pipeline = InputPipeline(), host = InputFileSetHost(pipeline: pipeline), intent = AccessIntent()
        await host.input([setC, setB, setA], intent: intent)
        #expect(host.session.filePreviewSet?.members == [setA, setB, setC])
        #expect(host.session.filePreviewSet?.index == 0)
        #expect(host.session.isEnabled(.previous) == false)
        #expect(host.session.isEnabled(.next) == true)
        #expect(host.session.isEnabled(.escape) == false)
        #expect(host.session.imageLoader.presented?.fileURL == setA)
        await host.move(.next, entry: entry)
        #expect(host.session.filePreviewSet?.index == 1)
        #expect(host.session.isEnabled(.previous) && host.session.isEnabled(.next))
        #expect(host.session.imageLoader.presented?.fileURL == setB)
        await host.move(.next, entry: entry)
        #expect(host.session.filePreviewSet?.index == 2)
        #expect(host.session.isEnabled(.previous) == true)
        #expect(host.session.isEnabled(.next) == false)
        await host.move(.next, entry: entry)
        await host.move(.previous, entry: entry)
        await host.move(.previous, entry: entry)
        await host.move(.previous, entry: entry)
        #expect(host.opens.map(\.0) == [setA, setB, setC, setB, setA])
        #expect(host.opens.allSatisfy { $0.1 == nil })
        #expect(host.session.filePreviewSet?.members == [setA, setB, setC])
        #expect(host.session.filePreviewSet?.index == 0)
        #expect(host.navigation.isEmpty && host.folders.isEmpty && host.notices.isEmpty)
        #expect(await pipeline.headers.count == 10)
        await host.finish()
    }
    let host = InputFileSetHost()
    host.session.filePreviewSet = FilePreviewSet(files: [setA])
    #expect(host.session.isEnabled(.previous) == false)
    #expect(host.session.isEnabled(.next) == false)
    #expect(host.session.isEnabled(.escape) == false)
}

@Test @MainActor func inputFileSetEscapePrecedenceAndLifetimePreserveFrozenMembers() async {
    let host = InputFileSetHost(), intent = AccessIntent()
    let grid = ItemID.ephemeral(UUID())
    host.session.beginBrowsing(items: [grid], sourceVersion: PreviewSourceVersion(1), scrollAnchor: grid)
    host.session.select(grid)
    #expect(CommandRouter(implementedCommands: Set(CommandID.allCases)).route(.preview, from: .key, to: host.session))
    await host.input([setC, setB, setA], intent: intent)
    await host.move(.next)
    #expect(CommandRouter().route(.escape, from: .key, to: host.session) == false)
    #expect(host.session.mode == .viewing)
    #expect(host.session.previewSet?.currentItemID == grid)
    #expect(host.session.filePreviewSet?.index == 1)
    host.session.setInspectorVisible(true); host.session.updateFocus(.panel)
    #expect(host.session.isEnabled(.escape))
    #expect(CommandRouter().route(.escape, from: .key, to: host.session))
    #expect(host.session.inspectorFocus.focus == .canvas)
    #expect(host.session.filePreviewSet?.index == 1)
    #expect(host.appliedFocus.last == .canvas)
    await host.input([setE, setD], intent: intent)
    #expect(host.session.filePreviewSet?.members == [setD, setE])
    #expect(host.session.filePreviewSet?.index == 0)
    #expect(host.session.imageLoader.presented?.fileURL == setD)
    for _ in ["recent", "grantedFolder", "close"] {
        host.session.endFilePreviewSet(); host.session.endFilePreviewSet()
        #expect(host.session.filePreviewSet == nil)
        await host.input([setA, setB], intent: intent)
    }
    await host.input([setC], intent: intent)
    #expect(host.session.filePreviewSet == nil)
    #expect(host.session.imageLoader.presented?.fileURL == setC)
    await host.finish()
}

@Test @MainActor func inputFileSetRejectedUnsupportedAndRetryKeepPosition() async {
    for failure in [ImageLoadError.Kind.corruptImage, .unsupportedFormat] {
        let pipeline = InputPipeline(), host = InputFileSetHost(pipeline: pipeline), intent = AccessIntent()
        await pipeline.fail(setB, ImageLoadError(failure))
        await host.input([setA, setB, setC], intent: intent)
        await host.move(.next)
        #expect(host.session.imageStatus == .failed(failure == .corruptImage ? .corruptImage : .unsupportedFormat, "B.jpg"))
        #expect(host.session.imageLoader.presented == nil)
        #expect(host.session.filePreviewSet?.index == 1)
        #expect(host.session.isEnabled(.next) && host.session.isEnabled(.previous))
        #expect(host.notices.isEmpty)
        host.retry?.reopen { host.openInputImage($0, accessRequest: $1) }
        await host.session.imageLoader.loadTask?.value
        #expect(host.session.filePreviewSet?.index == 1)
        #expect(host.opens.last?.0 == setB)
        #expect(host.retry?.accessRequest == nil)
        await pipeline.fail(setD, ImageLoadError(.unsupportedFormat))
        let generation = host.session.imageLoader.generation
        await host.input([setD], intent: intent)
        #expect(host.session.filePreviewSet?.members == [setA, setB, setC])
        #expect(host.session.filePreviewSet?.index == 1)
        #expect(host.session.imageLoader.generation == generation)
        await host.input([URL(fileURLWithPath: "/bad.zip")], intent: intent)
        #expect(host.session.filePreviewSet?.index == 1)
        #expect(host.notices == [.unsupported("D.png"), .rejected])
        await host.move(.next)
        #expect(host.session.filePreviewSet?.index == 2)
        #expect(host.session.imageLoader.presented?.fileURL == setC)
        await host.finish()
    }
}

@Test @MainActor func inputFileSetMembersDeferScopeAndPartialExclusionsDoNotNotice() async {
    let pipeline = InputPipeline(), host = InputFileSetHost(pipeline: pipeline), intent = AccessIntent()
    host.covered = [setA]
    let external = URL(fileURLWithPath: "/outside/B.png")
    await host.input([external, URL(fileURLWithPath: "/bad.zip"), setA], intent: intent)
    #expect(host.opens.map(\.0) == [setA])
    #expect(host.opens.first?.1 == nil)
    #expect(host.session.imageLoader.presented?.fileURL == setA)
    await host.move(.next)
    #expect(host.opens.map(\.0) == [setA, external])
    #expect(host.opens.allSatisfy { $0.1 == nil })
    #expect(host.session.imageLoader.presented?.fileURL == external)
    #expect(await host.leases.requests == [.root(host.root, file: setA), .root(host.root, file: setA), .root(host.root, file: setA),
                                          .fileGrant(external), .fileGrant(external), .fileGrant(external)])
    let headers = await pipeline.headers
    #expect(headers.count == 4)
    #expect(headers.map { $0.root?.id } == [host.root, host.root, nil, nil])
    #expect(host.notices.isEmpty)
    await host.input([URL(fileURLWithPath: "/bad.zip"), setC], intent: intent)
    #expect(host.session.filePreviewSet == nil)
    #expect(host.session.imageLoader.presented?.fileURL == setC)
    #expect(host.notices.isEmpty)
    await host.finish()
}

private struct FileSetSlowPipeline: ImagePipeline {
    let pipeline: InputPipeline
    let gate: InputGate
    func request(for fileURL: URL, maximumPixelSize: Int) async throws -> ImageDecodeRequest {
        try await request(for: fileURL, maximumPixelSize: maximumPixelSize, identityRoot: nil)
    }
    func request(for fileURL: URL, maximumPixelSize: Int, identityRoot: ItemIdentityRoot?) async throws -> ImageDecodeRequest {
        if fileURL == setA { await gate.pause() }
        return try await pipeline.request(for: fileURL, maximumPixelSize: maximumPixelSize, identityRoot: identityRoot)
    }
    func image(for request: ImageDecodeRequest) async throws -> DecodedImage { try await pipeline.image(for: request) }
}
@Test @MainActor func inputFileSetNewBatchSupersedesPendingSingleProbe() async {
    for failure in 0...3 {
        let pipeline = InputPipeline(), gate = InputGate()
        let slow = FileSetSlowPipeline(pipeline: pipeline, gate: gate)
        let host = InputFileSetHost(pipeline: slow), intent = AccessIntent()
        let errors: [any Error] = [ImageLoadError(.unsupportedFormat), ImageLoadError(.corruptImage), InputFault.generic]
        if failure > 0 { await pipeline.fail(setA, errors[failure - 1]) }
        let old = intent.begin()
        let pending = Task { await host.session.openInput([setA], operation: old, admission: host.admission, host: host) }
        await gate.waitForEntry()
        await host.session.openInput([setE, setD], operation: intent.begin(), admission: host.admission, host: host)
        await gate.resume(); await pending.value; await host.session.imageLoader.loadTask?.value
        #expect(host.session.filePreviewSet?.members == [setD, setE])
        #expect(host.session.filePreviewSet?.index == 0)
        #expect(host.session.imageLoader.presented?.fileURL == setD)
        #expect(host.opens.map(\.0) == [setD])
        #expect(host.notices.isEmpty)
        await host.finish()
    }
}

@Test @MainActor func inputFileSetOwnerCommandsAtEndsDoNothing() async {
    let host = InputFileSetHost(), intent = AccessIntent()
    await host.input([setA, setB], intent: intent)
    host.session.perform(.previous, from: .key)
    #expect(host.opens.map(\.0) == [setA])
    #expect(host.session.filePreviewSet?.index == 0)
    await host.move(.next)
    host.session.perform(.next, from: .key)
    #expect(host.opens.map(\.0) == [setA, setB])
    #expect(host.session.filePreviewSet?.index == 1)
    #expect(host.navigation.isEmpty && host.folders.isEmpty)
    await host.finish()
}
