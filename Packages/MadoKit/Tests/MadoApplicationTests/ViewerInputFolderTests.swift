import Foundation
import Testing
import MadoCore
@testable import MadoApplication

private let folderA = URL(fileURLWithPath: "/photos/A.png")
private let folderB = URL(fileURLWithPath: "/photos/B.png")
private let folderC = URL(fileURLWithPath: "/photos/C.png")
private let requestedFolder = URL(fileURLWithPath: "/outside", isDirectory: true)

@Test @MainActor func inputFolderPromptCancelPreservesShowingEmptyAndFrozenSet() async {
    for state in 0...2 {
        let pipeline = InputPipeline(), host = InputFileSetHost(pipeline: pipeline), intent = AccessIntent()
        if state == 1 { await host.input([folderA], intent: intent) }
        if state == 2 { await host.input([folderC, folderB, folderA], intent: intent); await host.move(.next) }
        let generation = host.session.imageLoader.generation, phase = host.session.imageLoader.phase
        let key = host.session.imageLoader.presented?.key, title = host.title
        let retry = host.retry?.fileURL, request = host.retry?.accessRequest
        let members = host.session.filePreviewSet?.members, index = host.session.filePreviewSet?.index
        let opened = host.opens.map(\.0), headers = await pipeline.headers.count
        let acquired = await host.leases.acquired.count
        for urls in [[requestedFolder], [URL(fileURLWithPath: "/bad.zip"), requestedFolder],
                     [URL(string: "https://example.test/a.png")!, requestedFolder]] {
            await host.input(urls, intent: intent)
            #expect(host.session.imageLoader.generation == generation)
            #expect(host.session.imageLoader.phase == phase)
            #expect(host.session.imageLoader.presented?.key == key)
            #expect(host.title == title)
            #expect(host.retry?.fileURL == retry)
            #expect(host.retry?.accessRequest == request)
            #expect(host.session.filePreviewSet?.members == members)
            #expect(host.session.filePreviewSet?.index == index)
            #expect(host.opens.map(\.0) == opened)
            #expect(await host.leases.acquired.count == acquired)
            #expect(await pipeline.headers.count == headers)
        }
        #expect(host.folders == [requestedFolder, requestedFolder, requestedFolder])
        #expect(host.notices.isEmpty)
        #expect(host.navigation.isEmpty)
        if state == 0 { #expect(host.session.imageStatus == .empty) }
        if state == 1 { #expect(host.session.imageLoader.presented?.fileURL == folderA) }
        if state == 2 {
            await host.move(.next)
            #expect(host.session.filePreviewSet?.members == [folderA, folderB, folderC])
            #expect(host.session.filePreviewSet?.index == 2)
            #expect(host.session.imageLoader.presented?.fileURL == folderC)
        }
        await host.finish()
    }
}

@Test @MainActor func inputFolderPlusImageUsesFilePolicyWithoutPromptOrGrant() async {
    let pipeline = InputPipeline(), host = InputFileSetHost(pipeline: pipeline), intent = AccessIntent()
    await host.input([requestedFolder, folderA], intent: intent)
    #expect(host.session.imageLoader.presented?.fileURL == folderA)
    #expect(host.session.filePreviewSet == nil)
    #expect(host.opens.map(\.0) == [folderA])
    #expect(host.opens.first?.1 == .fileGrant(folderA))
    #expect(host.folders.isEmpty && host.notices.isEmpty)
    #expect(await host.leases.requests.allSatisfy { $0 == .fileGrant(folderA) })
    await host.input([requestedFolder, folderC, folderB], intent: intent)
    #expect(host.session.filePreviewSet?.members == [folderB, folderC])
    #expect(host.session.filePreviewSet?.index == 0)
    #expect(host.session.imageLoader.presented?.fileURL == folderB)
    #expect(host.opens.last?.1 == nil)
    #expect(host.folders.isEmpty && host.notices.isEmpty)
    await host.finish()
}

@Test @MainActor func inputFolderSupersedesSuspendedProbeWithoutLateEffects() async {
    for stage in ["root", "acquire", "header", "release"] {
        for failure in 0...3 {
            let host = InputFileSetHost(), intent = AccessIntent()
            await host.input([folderA, folderB, folderC], intent: intent)
            await host.move(.next)
            let generation = host.session.imageLoader.generation
            let gate = InputGate(), pendingURL = URL(fileURLWithPath: "/pending.png")
            let access = InputLeases(acquireGate: stage == "acquire" ? gate : nil,
                                     releaseGate: stage == "release" ? gate : nil)
            let pipeline = InputPipeline(gate: stage == "header" ? gate : nil)
            let errors: [any Error] = [ImageLoadError(.unsupportedFormat), ImageLoadError(.corruptImage), InputFault.generic]
            if failure > 0 { await pipeline.fail(pendingURL, errors[failure - 1]) }
            let admission = ViewerInputAdmission(access: access, pipeline: pipeline, maximumPixelSize: 64, rootCovering: { _ in
                if stage == "root" { await gate.pause() }
                return nil
            })
            let old = intent.begin()
            let pending = Task { await host.session.openInput([pendingURL], operation: old, admission: admission, host: host) }
            await gate.waitForEntry()
            await host.session.openInput([requestedFolder], operation: intent.begin(), admission: host.admission, host: host)
            await gate.resume(); await pending.value
            #expect(host.folders == [requestedFolder])
            #expect(host.opens.map(\.0) == [folderA, folderB])
            #expect(host.notices.isEmpty && host.navigation.isEmpty)
            #expect(host.session.imageLoader.generation == generation)
            #expect(host.session.imageStatus == .showing)
            #expect(host.session.imageLoader.presented?.fileURL == folderB)
            #expect(host.session.filePreviewSet?.members == [folderA, folderB, folderC])
            #expect(host.session.filePreviewSet?.index == 1)
            let acquired = await access.acquired, released = await access.released
            #expect(acquired.count == (stage == "root" ? 0 : 1))
            #expect(released.count == acquired.count)
            for lease in acquired { #expect(released.filter { $0 == lease }.count == 1) }
            #expect(await access.active.isEmpty == true)
            #expect(await pipeline.decodes == 0)
            await host.finish()
        }
    }
}
