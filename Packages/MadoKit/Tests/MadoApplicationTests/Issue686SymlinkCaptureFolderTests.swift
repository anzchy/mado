import Foundation
import Testing
import MadoApplication

// #686 P7-10 CAP-02 fix round 1 (gpt M2 = opus L1): the Capture Folder comparison resolves symlinks on both sides, so
// a folder reached through a symlink, or /tmp against /private/tmp, is still the Capture Folder.

private final class Record686Link: @unchecked Sendable {
    var record: CaptureFolderRecord?
    init(_ record: CaptureFolderRecord?) { self.record = record }
}

private func record(_ display: String) -> CaptureFolderRecord {
    CaptureFolderRecord(bookmark: Data([1]), display: display, fellBack: false)
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue686SymlinkedCaptureFolderIsStillTheCaptureFolder() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("issue686-link-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    let real = root.appendingPathComponent("Shots", isDirectory: true)
    let link = root.appendingPathComponent("ShotsLink", isDirectory: true)
    try fm.createDirectory(at: real, withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: link, withDestinationURL: real)
    let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    let box = Record686Link(record(link.path))
    let gate = CaptureFolderGrantGate(record: { box.record }, home: home)
    #expect(await gate.paging(in: real) == .prompt(.capture), "display names the link, the image is in the target")
    box.record = record(real.path)
    #expect(await gate.paging(in: link) == .prompt(.capture), "display names the target, the image is under the link")

    gate.declined(link, wording: .capture)
    #expect(await gate.paging(in: real) == .stay, "a decline through the link covers the target")

    let tmp = URL(fileURLWithPath: "/tmp/issue686-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }
    let privateTmp = URL(fileURLWithPath: "/private" + tmp.path, isDirectory: true)
    box.record = record(tmp.path)
    #expect(await gate.paging(in: privateTmp) == .prompt(.capture))
    box.record = record(privateTmp.path)
    #expect(await gate.paging(in: tmp) == .prompt(.capture))
}
