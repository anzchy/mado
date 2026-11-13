import Foundation
import Testing
import MadoCore
@testable import MadoApplication

private let revokeA = URL(fileURLWithPath: "/photos/A.png")
private let revokeB = URL(fileURLWithPath: "/photos/B.jpg")
private let revokeC = URL(fileURLWithPath: "/photos/C.png")
private let revokeD = URL(fileURLWithPath: "/photos/D.png")
private let revokeMembers = [revokeA, revokeB, revokeC]

@MainActor private struct RevocationSnapshot {
    let generation: UUID
    let key: RenderKey?
    let url: URL?
    let phase: ViewerImagePhase
    let status: ViewerImageStatus
    let title: String
    let retryURL: URL?
    let retryRequest: AccessRequest?
    let members: [URL]?
    let index: Int?
    init(_ session: ViewerSession, title: String, retry: ViewerRetryIntent?) {
        generation = session.imageLoader.generation; key = session.imageLoader.presented?.key
        url = session.imageLoader.presented?.fileURL; phase = session.imageLoader.phase
        status = session.imageStatus; self.title = title
        retryURL = retry?.fileURL; retryRequest = retry?.accessRequest
        members = session.filePreviewSet?.members; index = session.filePreviewSet?.index
    }
    func check(_ session: ViewerSession, title: String, retry: ViewerRetryIntent?) {
        #expect(session.imageLoader.generation == generation)
        #expect(session.imageLoader.presented?.key == key)
        #expect(session.imageLoader.presented?.fileURL == url)
        #expect(session.imageLoader.phase == phase)
        #expect(session.imageStatus == status)
        #expect(title == self.title)
        #expect(retry?.fileURL == retryURL)
        #expect(retry?.accessRequest == retryRequest)
        #expect(session.filePreviewSet?.members == members)
        #expect(session.filePreviewSet?.index == index)
    }
}

@MainActor private final class RevocationProbe {
    let gate = InputGate()
    let leases = InputLeases()
    let pipeline: InputPipeline
    let intent = AccessIntent()
    private var pending: Task<Void, Never>?
    init() { pipeline = InputPipeline(gate: gate) }
    func start(_ session: ViewerSession, host: any ViewerInputHost, unsupported: Bool) async {
        if unsupported { await pipeline.fail(revokeD, ImageLoadError(.unsupportedFormat)) }
        let admission = ViewerInputAdmission(access: leases, pipeline: pipeline, maximumPixelSize: 64, rootCovering: { _ in nil })
        let operation = intent.begin()
        pending = Task { await session.openInput([revokeD], operation: operation, admission: admission, host: host) }
        await gate.waitForEntry()
        #expect(await leases.active.count == 1)
    }
    func finish() async {
        await gate.resume(); await pending?.value
        let acquired = await leases.acquired, released = await leases.released
        #expect(acquired.count == 1)
        #expect(released == acquired)
        #expect(await leases.active.isEmpty)
        #expect(await pipeline.decodes == 0)
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func inputRevocationSetMovesPreserveNewerMember() async {
    for command in [CommandID.next, .previous] {
        for unsupported in [false, true] {
            let host = InputFileSetHost(), input = AccessIntent(), probe = RevocationProbe()
            await host.input(revokeMembers, intent: input)
            if command == .previous { await host.move(.next) }
            await probe.start(host.session, host: host, unsupported: unsupported)
            await host.move(command)
            let destination = command == .next ? revokeB : revokeA
            let index = command == .next ? 1 : 0
            #expect(host.session.imageLoader.presented?.fileURL == destination)
            #expect(host.session.filePreviewSet?.members == revokeMembers)
            #expect(host.session.filePreviewSet?.index == index)
            let snapshot = RevocationSnapshot(host.session, title: host.title, retry: host.retry)
            let opens = host.opens.map(\.0)
            await probe.finish(); await host.session.imageLoader.loadTask?.value
            snapshot.check(host.session, title: host.title, retry: host.retry)
            #expect(host.opens.map(\.0) == opens)
            #expect(host.notices.isEmpty)
            await host.finish()
        }
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func inputRevocationFolderNavigationBeforeDestinationOpens() async {
    for command in [CommandID.next, .previous] {
        for unsupported in [false, true] {
            let host = InputFileSetHost(), probe = RevocationProbe()
            host.openInputImage(revokeA, accessRequest: .fileGrant(revokeA))
            await host.session.imageLoader.loadTask?.value
            await probe.start(host.session, host: host, unsupported: unsupported)
            let snapshot = RevocationSnapshot(host.session, title: host.title, retry: host.retry)
            #expect(CommandRouter().route(command, from: .key, to: host.session))
            #expect(host.navigation == [command == .next ? .next : .previous])
            #expect(host.session.imageLoader.generation == snapshot.generation)
            await probe.finish(); await host.session.imageLoader.loadTask?.value
            snapshot.check(host.session, title: host.title, retry: host.retry)
            #expect(host.opens.map(\.0) == [revokeA])
            #expect(host.notices.isEmpty)
            host.openInputImage(revokeB, accessRequest: nil)
            await host.session.imageLoader.loadTask?.value
            #expect(host.session.imageLoader.presented?.fileURL == revokeB)
            await host.finish()
        }
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func inputRevocationRetryAndCancelPreserveLaterState() async {
    for unsupported in [false, true] {
        for failed in [false, true] {
            let pipeline = InputPipeline(), host = InputFileSetHost(pipeline: pipeline), probe = RevocationProbe()
            if failed { await pipeline.fail(revokeB, ImageLoadError(.corruptImage)) }
            await host.input(revokeMembers, intent: AccessIntent()); await host.move(.next)
            await probe.start(host.session, host: host, unsupported: unsupported)
            host.retry?.reopen { host.openInputImage($0, accessRequest: $1) }
            await host.session.imageLoader.loadTask?.value
            #expect(host.session.imageStatus == (failed ? .failed(.corruptImage, "B.jpg") : .showing))
            #expect(host.retry?.fileURL == revokeB)
            #expect(host.session.filePreviewSet?.index == 1)
            let snapshot = RevocationSnapshot(host.session, title: host.title, retry: host.retry)
            let opens = host.opens.map(\.0)
            await probe.finish(); await host.session.imageLoader.loadTask?.value
            snapshot.check(host.session, title: host.title, retry: host.retry)
            #expect(host.opens.map(\.0) == opens)
            #expect(host.notices.isEmpty)
            await host.finish()
        }
        let host = InputHost(), loaderGate = InputGate(), probe = RevocationProbe()
        host.loaderGate = loaderGate
        host.openInputImage(revokeA, accessRequest: .fileGrant(revokeA))
        await loaderGate.waitForEntry()
        let loading = host.session.imageLoader.loadTask
        await probe.start(host.session, host: host, unsupported: unsupported)
        host.session.cancelImageOpening()
        #expect(host.session.imageStatus == .empty)
        let snapshot = RevocationSnapshot(host.session, title: host.title, retry: host.retry)
        await loaderGate.resume(); await loading?.value
        await probe.finish(); await host.session.imageLoader.loadTask?.value
        snapshot.check(host.session, title: host.title, retry: host.retry)
        #expect(host.opens.map(\.0) == [revokeA])
        #expect(host.notices.isEmpty)
        await host.finish()
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func inputRevocationLoaderCompletionDoesNotSupersedeAdmission() async {
    for unsupported in [false, true] {
        let host = InputHost(), loaderGate = InputGate(), probe = RevocationProbe()
        host.session.filePreviewSet = FilePreviewSet(files: revokeMembers)
        host.loaderGate = loaderGate
        host.openInputImage(revokeA, accessRequest: .fileGrant(revokeA))
        await loaderGate.waitForEntry()
        let generation = host.session.imageLoader.generation
        await probe.start(host.session, host: host, unsupported: unsupported)
        await loaderGate.resume(); await host.session.imageLoader.loadTask?.value
        #expect(host.session.imageLoader.presented?.fileURL == revokeA)
        #expect(host.session.imageLoader.generation == generation)
        let snapshot = RevocationSnapshot(host.session, title: host.title, retry: host.retry)
        await probe.finish(); await host.session.imageLoader.loadTask?.value
        if unsupported {
            snapshot.check(host.session, title: host.title, retry: host.retry)
            #expect(host.notices == [.unsupported("D.png")])
            #expect(host.opens.map(\.0) == [revokeA])
        } else {
            #expect(host.session.imageLoader.presented?.fileURL == revokeD)
            #expect(host.session.filePreviewSet == nil)
            #expect(host.opens.map(\.0) == [revokeA, revokeD])
            #expect(host.notices.isEmpty)
        }
        await host.finish()
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func inputRevocationComposedLifecyclePreservesDestination() async {
    for boundary in ["recent", "folder", "close"] {
        for unsupported in [false, true] {
            let host = InputFileSetHost(), probe = RevocationProbe()
            await host.input(revokeMembers, intent: AccessIntent()); await host.move(.next)
            #expect(host.session.imageLoader.presented?.fileURL == revokeB)
            #expect(host.session.filePreviewSet?.index == 1)
            await probe.start(host.session, host: host, unsupported: unsupported)
            probe.intent.invalidate(); host.session.endFilePreviewSet()
            if boundary == "close" { host.session.closeImage() }
            else {
                let destination = URL(fileURLWithPath: boundary == "recent" ? "/photos/E.png" : "/folder/F.png")
                host.openInputImage(destination, accessRequest: .fileGrant(destination))
                await host.session.imageLoader.loadTask?.value
                #expect(host.session.imageLoader.presented?.fileURL == destination)
                #expect(host.session.imageStatus == .showing)
            }
            #expect(host.session.filePreviewSet == nil)
            if boundary == "close" { #expect(host.session.imageStatus == .empty) }
            let snapshot = RevocationSnapshot(host.session, title: host.title, retry: host.retry)
            let opens = host.opens.map(\.0)
            await probe.finish(); await host.session.imageLoader.loadTask?.value
            snapshot.check(host.session, title: host.title, retry: host.retry)
            #expect(host.opens.map(\.0) == opens)
            #expect(host.notices.isEmpty)
            await host.finish()
        }
    }
}
