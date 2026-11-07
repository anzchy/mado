import Foundation
import Testing
import MadoCore
@testable import MadoApplication

private let multipleA = URL(fileURLWithPath: "/photos/A.png")
private let multipleB = URL(fileURLWithPath: "/photos/B.png")
private let multipleC = URL(fileURLWithPath: "/photos/C.png")
private let multipleOne = URL(fileURLWithPath: "/one", isDirectory: true)
private let multipleTwo = URL(fileURLWithPath: "/two", isDirectory: true)
private let multipleThree = URL(fileURLWithPath: "/three", isDirectory: true)
private let multipleZip = URL(fileURLWithPath: "/bad.zip")

@Test @MainActor func inputFoldersMultipleHaveAccurateNoticeAndPreserveState() async {
    for showing in [false, true] {
        let pipeline = InputPipeline(), host = InputFileSetHost(pipeline: pipeline), intent = AccessIntent()
        if showing {
            await host.input([multipleC, multipleA, multipleB], intent: intent)
            await host.move(.next)
            #expect(host.session.imageLoader.presented?.fileURL == multipleB)
            #expect(host.session.filePreviewSet?.index == 1)
        } else { #expect(host.session.imageStatus == .empty) }
        let generation = host.session.imageLoader.generation, phase = host.session.imageLoader.phase
        let key = host.session.imageLoader.presented?.key, url = host.session.imageLoader.presented?.fileURL
        let title = host.title, retry = host.retry?.fileURL, request = host.retry?.accessRequest
        let members = host.session.filePreviewSet?.members, index = host.session.filePreviewSet?.index
        let opened = host.opens.map(\.0), headers = await pipeline.headers.count, decodes = await pipeline.decodes
        let acquired = await host.leases.acquired.count
        let batches = [
            [multipleOne, multipleTwo], [multipleOne, multipleTwo, multipleThree],
            [multipleOne, multipleTwo, multipleZip],
            [multipleOne, multipleTwo, multipleOne, URL(fileURLWithPath: "/./two", isDirectory: true)],
            [URL(string: "https://example.test/a.png")!, multipleOne, multipleTwo]
        ]
        for urls in batches {
            await host.input(urls, intent: intent)
            #expect(host.notices.last == .multipleFolders)
            #expect(host.session.imageLoader.generation == generation)
            #expect(host.session.imageLoader.phase == phase)
            #expect(host.session.imageLoader.presented?.key == key)
            #expect(host.session.imageLoader.presented?.fileURL == url)
            #expect(host.title == title)
            #expect(host.retry?.fileURL == retry)
            #expect(host.retry?.accessRequest == request)
            #expect(host.session.filePreviewSet?.members == members)
            #expect(host.session.filePreviewSet?.index == index)
            #expect(host.opens.map(\.0) == opened)
            #expect(host.folders.isEmpty)
            #expect(await host.leases.acquired.count == acquired)
            #expect(await pipeline.headers.count == headers)
            #expect(await pipeline.decodes == decodes)
        }
        #expect(host.notices == [.multipleFolders, .multipleFolders, .multipleFolders, .multipleFolders, .multipleFolders])
        await host.finish()
    }
}

@Test @MainActor func inputFoldersNeighborsKeepExistingPolicy() async {
    for urls in [[multipleOne, multipleOne], [multipleOne, multipleZip],
                 [multipleOne, URL(fileURLWithPath: "/./one", isDirectory: true)]] {
        let host = InputFileSetHost()
        await host.input(urls, intent: AccessIntent())
        #expect(host.folders == [multipleOne])
        #expect(host.notices.isEmpty && host.opens.isEmpty)
        #expect(host.session.imageStatus == .empty)
        #expect(await host.leases.acquired.isEmpty)
        await host.finish()
    }
    let host = InputFileSetHost(), intent = AccessIntent()
    await host.input([multipleOne, multipleTwo, multipleA], intent: intent)
    #expect(host.session.imageLoader.presented?.fileURL == multipleA)
    #expect(host.session.filePreviewSet == nil)
    #expect(host.folders.isEmpty && host.notices.isEmpty)
    await host.input([multipleOne, multipleTwo, multipleC, multipleA], intent: intent)
    #expect(host.session.imageLoader.presented?.fileURL == multipleA)
    #expect(host.session.filePreviewSet?.members == [multipleA, multipleC])
    #expect(host.session.filePreviewSet?.index == 0)
    #expect(host.folders.isEmpty && host.notices.isEmpty)
    let generation = host.session.imageLoader.generation
    await host.input([multipleZip, URL(fileURLWithPath: "/plain")], intent: intent)
    #expect(host.notices == [.rejected])
    #expect(host.session.imageLoader.generation == generation)
    #expect(host.session.imageLoader.presented?.fileURL == multipleA)
    #expect(host.session.filePreviewSet?.members == [multipleA, multipleC])
    await host.finish()
}
