import Foundation
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure

private actor SidebarLeaseProbe: AccessLeasing {
    let root: URL
    var active = 0
    var releases = 0
    init(root: URL) { self.root = root }
    func acquire(_ request: AccessRequest) throws -> AccessLease {
        guard case .root = request else { throw FileAccessError.outsideRoot }
        active += 1
        return AccessLease(url: root, rootID: AccessRootID())
    }
    func release(_ lease: AccessLease) { active -= 1; releases += 1 }
}

@Test(.timeLimit(.minutes(2))) func sidebarListingCountsRealDirectImagesAndKeepsLease() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("sidebar-list-\(UUID())")
    let root = base.appendingPathComponent("root")
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let child = root.appendingPathComponent("Trip")
    let empty = root.appendingPathComponent("Empty")
    let hidden = root.appendingPathComponent(".hidden")
    let package = root.appendingPathComponent("Library.photoslibrary")
    for folder in [child, empty, hidden, package] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    for name in ["a.jpg", "b.PNG", "notes.txt", ".hidden.jpeg"] {
        try Data().write(to: child.appendingPathComponent(name))
    }
    let outside = base.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
    let probe = SidebarLeaseProbe(root: root)
    let browser = SidebarFolderBrowser(access: probe, enumerator: SystemSidebarFolderEnumerator())
    let id = AccessRootID()
    let children = try await browser.children(in: root, rootID: id)
    #expect(Set(children.map(\.lastPathComponent)) == ["Trip", "Empty"])
    #expect(try await browser.imageCount(in: child, rootID: id) == 2)
    #expect(try await browser.imageCount(in: empty, rootID: id) == 0)
    await #expect(throws: FileAccessError.self) { try await browser.imageCount(in: outside, rootID: id) }
    #expect(await probe.active == 0)
    #expect(await probe.releases == 4)
}
