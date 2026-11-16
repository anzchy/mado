import Foundation
import Testing
import MadoApplication

// #686 P7-10 CAP-02 fix round 2 (gpt confirm M2): the grant gate resolves symlinks synchronously on the main actor,
// so it resolves the Capture Folder once per App Group value and the image's folder once per item, not on every
// ←/→ attempt or decline.

private final class Record686Once: @unchecked Sendable {
    var record: CaptureFolderRecord?
    init(_ record: CaptureFolderRecord?) { self.record = record }
}

private final class Resolutions686: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    var count: Int { lock.withLock { paths.count } }
    func resolve(_ url: URL) -> String {
        lock.withLock { paths.append(url.path) }
        return url.resolvingSymlinksInPath().path
    }
}

private func record(_ display: String) -> CaptureFolderRecord {
    CaptureFolderRecord(bookmark: Data([1]), display: display, fellBack: false)
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue686GrantGateResolvesEachFolderOnce() async throws {
    let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
    let resolutions = Resolutions686()
    let box = Record686Once(record("~/Captures"))
    let gate = CaptureFolderGrantGate(record: { box.record }, home: home, resolve: resolutions.resolve)
    let elsewhere = URL(fileURLWithPath: "/Users/someone/Pictures", isDirectory: true)
    let captures = URL(fileURLWithPath: "/Users/someone/Captures", isDirectory: true)

    #expect(await gate.paging(in: elsewhere) == .prompt(.generic))
    #expect(resolutions.count == 2, "first attempt: the image's folder and the Capture Folder")
    for _ in 0..<5 { #expect(await gate.paging(in: elsewhere) == .prompt(.generic)) }
    gate.declined(elsewhere, wording: .generic)
    #expect(resolutions.count == 2, "repeated ←/→ on the same item resolves nothing again")

    #expect(await gate.paging(in: captures) == .prompt(.capture))
    #expect(resolutions.count == 3, "a new item resolves its folder once")
    for _ in 0..<5 { #expect(await gate.paging(in: captures) == .prompt(.capture)) }
    gate.declined(captures, wording: .capture)
    #expect(await gate.paging(in: captures) == .stay)
    #expect(resolutions.count == 3, "←/→ and the decline on that item reuse its resolution")

    box.record = record("~/Shots")
    #expect(await gate.paging(in: elsewhere) == .prompt(.generic))
    #expect(resolutions.count == 5, "a new App Group value resolves once; the new item once")
    for _ in 0..<3 { #expect(await gate.paging(in: elsewhere) == .prompt(.generic)) }
    #expect(resolutions.count == 5)
}
