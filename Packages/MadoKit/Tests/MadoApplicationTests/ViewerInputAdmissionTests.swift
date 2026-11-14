import Foundation
import Testing
import MadoCore
@testable import MadoApplication

actor InputGate {
    private var entered = false
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var paused: CheckedContinuation<Void, Never>?
    func pause() async {
        if opened { return }
        entered = true; waiter?.resume(); waiter = nil
        await withCheckedContinuation { paused = $0 }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func resume() { opened = true; paused?.resume(); paused = nil }
}

enum InputFault: Error, Sendable { case generic }
actor InputLeases: AccessLeasing {
    var requests: [AccessRequest] = []
    var acquired: [AccessLease] = []
    var released: [AccessLease] = []
    var active = Set<AccessLease>()
    let acquireGate: InputGate?
    let releaseGate: InputGate?
    let fails: Bool
    private var drained: CheckedContinuation<Void, Never>?
    init(acquireGate: InputGate? = nil, releaseGate: InputGate? = nil, fails: Bool = false) {
        self.acquireGate = acquireGate; self.releaseGate = releaseGate; self.fails = fails
    }
    func acquire(_ request: AccessRequest) async throws -> AccessLease {
        requests.append(request)
        await acquireGate?.pause()
        if fails { throw FileAccessError.startFailed }
        let lease: AccessLease
        switch request {
        case .root(let root, _): lease = AccessLease(url: URL(fileURLWithPath: "/photos", isDirectory: true), rootID: root)
        case .fileGrant(let file): lease = AccessLease(url: file, rootID: nil)
        }
        acquired.append(lease); active.insert(lease)
        return lease
    }
    func release(_ lease: AccessLease) async {
        await releaseGate?.pause()
        released.append(lease); active.remove(lease)
        if active.isEmpty { drained?.resume(); drained = nil }
    }
    func waitForDrain() async {
        if active.isEmpty { return }
        await withCheckedContinuation { drained = $0 }
    }
}
struct InputHeader: Sendable {
    let file: URL
    let maximum: Int
    let root: ItemIdentityRoot?
}
actor InputPipeline: ImagePipeline {
    let gate: InputGate?
    var faults: [URL: any Error] = [:]
    var headers: [InputHeader] = []
    var decodes = 0
    let item = ItemID.ephemeral(UUID())
    let revision = FileRevision(byteCount: 123, modificationDate: nil)
    init(gate: InputGate? = nil) { self.gate = gate }
    func fail(_ file: URL, _ error: any Error) { faults[file] = error }
    func request(for fileURL: URL, maximumPixelSize: Int) async throws -> ImageDecodeRequest {
        try await request(for: fileURL, maximumPixelSize: maximumPixelSize, identityRoot: nil)
    }
    func request(for fileURL: URL, maximumPixelSize: Int, identityRoot: ItemIdentityRoot?) async throws -> ImageDecodeRequest {
        headers.append(InputHeader(file: fileURL, maximum: maximumPixelSize, root: identityRoot))
        await gate?.pause()
        if let error = faults[fileURL] { throw error }
        return ImageDecodeRequest(fileURL: fileURL, maximumPixelSize: maximumPixelSize,
            renderKey: RenderKey(itemID: item, revision: revision, maximumPixelSize: maximumPixelSize), identityRoot: identityRoot)
    }
    func image(for request: ImageDecodeRequest) throws -> DecodedImage {
        decodes += 1
        return loadImage(request.renderKey!, edge: 1)
    }
}
@MainActor final class InputHost: ViewerInputHost, ViewerImageHost, ViewerSessionHost {
    let session = ViewerSession()
    let access: InputLeases
    let pipeline: InputPipeline
    let loaderIntent = AccessIntent()
    var loaderGate: InputGate?
    var opens: [(URL, AccessRequest?)] = []
    var notices: [ViewerInputNotice] = []
    var folders: [URL] = []
    var openings = 0
    var title = "Mado"
    var retry: ViewerRetryIntent?
    var hasImage = false
    var forward = true
    init(access: InputLeases = InputLeases(), pipeline: InputPipeline = InputPipeline()) {
        self.access = access; self.pipeline = pipeline
        session.host = self; session.imageLoader.host = self
    }
    func openInputImage(_ url: URL, accessRequest: AccessRequest?) {
        opens.append((url, accessRequest))
        if !forward { return }
        retry = ViewerRetryIntent(fileURL: url, accessRequest: accessRequest)
        _ = loaderIntent.begin()
        let access = access, pipeline = pipeline, gate = loaderGate
        session.openImage(url, maximumPixelSize: 64,
            opener: ViewerImageLoader.accessOpener(intent: loaderIntent) { operation in
                if let gate { try await operation.wait { await gate.pause() } }
                return try await operation.wait {
                    try await AccessImageSource.open(accessRequest ?? .fileGrant(url), access: access, pipeline: pipeline)
                }
            })
    }
    func showInputNotice(_ notice: ViewerInputNotice) { notices.append(notice) }
    func promptForInputFolder(_ folder: URL) { folders.append(folder) }
    func beginImageOpening() { openings += 1; hasImage = false; title = "Mado" }
    func installImage(_ image: DecodedImage, fileURL: URL) { hasImage = true; title = fileURL.lastPathComponent }
    func imageLoadFailed(_ error: any Error) {
        hasImage = false; title = "Mado"
        _ = session.dismissCancelledImageFailure(error)
    }
    func performCanvas(_ command: CommandID, from entry: CommandEntry) { }
    func performCanvasZoom(_ command: CommandID, from entry: CommandEntry) -> Double? { nil }
    func requestOpen() { }
    func applyFocus(_ focus: FocusContext) { }
    func showInspector(_ visible: Bool) { }
    func finish() async { session.closeImage(); await access.waitForDrain() }
}
private let inputA = URL(fileURLWithPath: "/photos/A.png")
private let inputB = URL(fileURLWithPath: "/photos/B.jpg")

@MainActor @Test(.timeLimit(.minutes(2))) func issue695FailedReplacementLeasePreservesSetAndReportsFailure() async {
    let host = InputHost(access: InputLeases(fails: true)), intent = AccessIntent()
    let chosen = URL(fileURLWithPath: "/photos/chosen.png")
    host.session.filePreviewSet = FilePreviewSet(files: [inputA, inputB])
    _ = host.session.filePreviewSet?.move(forward: true)
    await host.session.recoverFilePreviewSetMember(inputB, with: chosen,
        operation: intent.begin(), admission: inputAdmission(host.access, host.pipeline), host: host)
    #expect(host.session.filePreviewSet?.members == [inputA, inputB])
    #expect(host.session.filePreviewSet?.index == 1)
    #expect(host.opens.isEmpty)
    #expect(!host.notices.isEmpty)
    #expect(host.notices == [.accessFailed])
    #expect(await host.access.requests == [.fileGrant(chosen)])
}
private func inputAdmission(_ access: InputLeases, _ pipeline: InputPipeline, root: AccessRootID? = nil,
                            rootGate: InputGate? = nil) -> ViewerInputAdmission {
    ViewerInputAdmission(access: access, pipeline: pipeline, maximumPixelSize: 960) { _ in
        await rootGate?.pause(); return root
    }
}

@MainActor @Test(.timeLimit(.minutes(2))) func inputAdmissionScopeHeadersAndLeaseConservation() async throws {
    for root in [nil, AccessRootID()] {
        for outcome in 0...4 {
            let access = InputLeases(), pipeline = InputPipeline(), intent = AccessIntent()
            let errors: [any Error] = [ImageLoadError(.unsupportedFormat), ImageLoadError(.corruptImage), InputFault.generic, CancellationError()]
            if outcome > 0 { await pipeline.fail(inputB, errors[outcome - 1]) }
            let result = await inputAdmission(access, pipeline, root: root).probe(inputB, operation: intent.begin())
            let request: AccessRequest = root.map { .root($0, file: inputB) } ?? .fileGrant(inputB)
            #expect(result == (outcome == 1 ? .unsupported : .open(request)))
            #expect(await access.requests == [request])
            let headers = await pipeline.headers
            #expect(headers.count == 1)
            #expect(headers.first?.file == inputB)
            #expect(headers.first?.maximum == 960)
            #expect(headers.first?.root?.id == root)
            #expect(headers.first?.root?.url == (root == nil ? nil : URL(fileURLWithPath: "/photos", isDirectory: true)))
            #expect(await pipeline.decodes == 0)
            #expect(await access.acquired.count == 1)
            let acquired = await access.acquired, released = await access.released
            #expect(released == acquired)
            #expect(await access.active.isEmpty == true)
        }
    }
    let access = InputLeases(fails: true), pipeline = InputPipeline(), intent = AccessIntent()
    #expect(await inputAdmission(access, pipeline).probe(inputB, operation: intent.begin()) == .open(.fileGrant(inputB)))
    #expect(await access.requests == [.fileGrant(inputB)])
    #expect(await access.acquired.isEmpty == true)
    #expect(await access.released.isEmpty == true)
    #expect(await pipeline.headers.isEmpty == true)
}

@MainActor @Test(.timeLimit(.minutes(2))) func inputAdmissionUnsupportedPreservesEveryStateAndExistingOpening() async throws {
    for state in 0...3 {
        let host = InputHost(), intent = AccessIntent()
        let gate = InputGate()
        if state == 2 { host.loaderGate = gate }
        if state == 3 { await host.pipeline.fail(inputA, ImageLoadError(.corruptImage)) }
        if state != 0 {
            host.openInputImage(inputA, accessRequest: .fileGrant(inputA))
            if state == 2 { await gate.waitForEntry() }
            else { await host.session.imageLoader.loadTask?.value }
        }
        let generation = host.session.imageLoader.generation, phase = host.session.imageLoader.phase
        let key = host.session.imageLoader.presented?.key, title = host.title
        let retry = host.retry?.fileURL, openings = host.openings
        await host.pipeline.fail(inputB, ImageLoadError(.unsupportedFormat))
        for _ in 0..<2 {
            await host.session.openInput([inputB], operation: intent.begin(), admission: inputAdmission(host.access, host.pipeline), host: host)
            #expect(host.session.imageLoader.generation == generation)
            #expect(host.session.imageLoader.phase == phase)
            #expect(host.session.imageLoader.presented?.key == key)
            #expect(host.title == title)
            #expect(host.retry?.fileURL == retry)
            #expect(host.retry?.accessRequest == (state == 0 ? nil : .fileGrant(inputA)))
            #expect(host.openings == openings)
        }
        #expect(host.notices == [.unsupported("B.jpg"), .unsupported("B.jpg")])
        if state == 2 {
            await gate.resume(); await host.session.imageLoader.loadTask?.value
            #expect(host.session.imageStatus == .showing)
            #expect(host.title == "A.png")
            #expect(host.session.imageLoader.presented?.fileURL == inputA)
        }
        if state == 3 {
            host.retry?.reopen { host.openInputImage($0, accessRequest: $1) }
            await host.session.imageLoader.loadTask?.value
            #expect(host.session.imageStatus == .failed(.corruptImage, "A.png"))
        }
        await host.finish()
    }
}

@MainActor @Test(.timeLimit(.minutes(2))) func inputAdmissionCorruptReplacesShowingImage() async {
    let host = InputHost(), intent = AccessIntent()
    host.openInputImage(inputA, accessRequest: nil)
    await host.session.imageLoader.loadTask?.value
    #expect(host.session.imageStatus == .showing)
    await host.pipeline.fail(inputB, ImageLoadError(.corruptImage))
    await host.session.openInput([inputB], operation: intent.begin(), admission: inputAdmission(host.access, host.pipeline), host: host)
    await host.session.imageLoader.loadTask?.value
    #expect(host.session.imageStatus == .failed(.corruptImage, "B.jpg"))
    #expect(host.session.imageLoader.presented == nil)
    #expect(host.openings == 2)
    #expect(host.retry?.fileURL == inputB)
    #expect(host.retry?.accessRequest == .fileGrant(inputB))
    #expect(host.notices.isEmpty)
    await host.finish()
}

@MainActor @Test(.timeLimit(.minutes(2))) func inputAdmissionRejectedHasNoIOOrStateChange() async {
    for showing in [false, true] {
        let host = InputHost(), intent = AccessIntent()
        if showing { host.openInputImage(inputA, accessRequest: nil); await host.session.imageLoader.loadTask?.value }
        let generation = host.session.imageLoader.generation, phase = host.session.imageLoader.phase
        let title = host.title, retry = host.retry?.fileURL
        let leases = await host.access.acquired.count, headers = await host.pipeline.headers.count
        for urls in [[], [URL(string: "https://example.test/a.png")!], [URL(fileURLWithPath: "/bad.zip")], [URL(fileURLWithPath: "/plain")]] {
            await host.session.openInput(urls, operation: intent.begin(), admission: inputAdmission(host.access, host.pipeline), host: host)
            #expect(host.session.imageLoader.generation == generation)
            #expect(host.session.imageLoader.phase == phase)
            #expect(host.title == title)
            #expect(host.retry?.fileURL == retry)
        }
        #expect(host.notices == [.rejected, .rejected, .rejected, .rejected])
        #expect(await host.access.acquired.count == leases)
        #expect(await host.pipeline.headers.count == headers)
        await host.finish()
    }
}

@MainActor @Test(.timeLimit(.minutes(2))) func inputAdmissionStaleErrorsAndLifecycleNeverAct() async {
    for stage in ["root", "acquire", "header", "release"] {
        for failure in 0...3 {
            for transition in ["new", "rejected", "close", "recent", "folder", "cancel"] {
                let gate = InputGate()
                let access = InputLeases(acquireGate: stage == "acquire" ? gate : nil,
                                         releaseGate: stage == "release" ? gate : nil)
                let pipeline = InputPipeline(gate: stage == "header" ? gate : nil)
                let errors: [any Error] = [ImageLoadError(.unsupportedFormat), ImageLoadError(.corruptImage), InputFault.generic]
                if failure > 0 { await pipeline.fail(inputA, errors[failure - 1]) }
                let host = InputHost(access: access, pipeline: pipeline), intent = AccessIntent()
                host.forward = false
                let operation = intent.begin()
                let admission = inputAdmission(access, pipeline, rootGate: stage == "root" ? gate : nil)
                let pending = Task { await host.session.openInput([inputA], operation: operation, admission: admission, host: host) }
                await gate.waitForEntry()
                if stage == "header" || stage == "release" { #expect(await access.active.count == 1) }
                if transition == "cancel" { pending.cancel() }
                else if transition == "new" || transition == "rejected" { _ = intent.begin() }
                else { intent.invalidate() }
                await gate.resume()
                if transition == "new" || transition == "rejected" {
                    let urls = transition == "new" ? [inputB] : [URL(fileURLWithPath: "/bad.zip")]
                    await host.session.openInput(urls, operation: intent.current, admission: inputAdmission(access, pipeline), host: host)
                }
                await pending.value
                #expect(host.opens.map(\.0) == (transition == "new" ? [inputB] : []))
                #expect(host.notices == (transition == "rejected" ? [.rejected] : []))
                #expect(host.folders.isEmpty)
                #expect(host.session.imageStatus == .empty)
                #expect(await access.active.isEmpty == true)
                let acquired = await access.acquired, released = await access.released
                #expect(acquired.count == (stage == "root" ? 0 : 1) + (transition == "new" ? 1 : 0))
                #expect(released.count == acquired.count)
                for lease in acquired { #expect(released.filter { $0 == lease }.count == 1) }
                #expect(await pipeline.decodes == 0)
            }
        }
    }
    let host = InputHost(), intent = AccessIntent(), stale = intent.begin()
    intent.invalidate()
    await host.session.openInput([inputB], operation: stale, admission: inputAdmission(host.access, host.pipeline), host: host)
    #expect(host.opens.isEmpty && host.notices.isEmpty)
    #expect(await host.access.acquired.isEmpty == true)
}
