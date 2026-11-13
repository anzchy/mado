import Foundation
import Darwin
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure

@MainActor private final class FolderAliasHost: FolderScanHost {
    var visible: URL?
    var opens: [URL] = []
    func rememberFolder(_ folder: URL, rootID: AccessRootID) async throws { }
    func openFolderImage(_ url: URL, rootID: AccessRootID) { visible = url; opens.append(url) }
}

@Test(.timeLimit(.minutes(2))) @MainActor func folderNavigationInwardAliasDoesNotTrapCurrentItem() async throws {
    let fm = FileManager.default
    // Foundation resolves this prefix back to /var; enumeration uses the physical /private/var spelling.
    let physicalTemp = try #require(realpath(fm.temporaryDirectory.path, nil))
    defer { free(physicalTemp) }
    let base = URL(fileURLWithPath: String(cString: physicalTemp), isDirectory: true).appendingPathComponent(UUID().uuidString)
    let root = base.appendingPathComponent("images")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let a = root.appendingPathComponent("a.png"), b = root.appendingPathComponent("b.png")
    let alias = root.appendingPathComponent("z-alias.png")
    try Data().write(to: a); try Data().write(to: b)
    try fm.createSymbolicLink(at: alias, withDestinationURL: a)
    let scope = CountingScope()
    let access = try FileAccess(scope: scope, bookmarks: FakeBookmarks(),
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "P2-02-WI-4")
    let id = try await access.grant(folder: root)
    let coordinator = FolderScanCoordinator(access: access, scanner: FolderBrowser()), host = FolderAliasHost()
    coordinator.host = host
    for input in [a, alias] {
        try await coordinator.begin(folder: root, rootID: id, input: input).value
        #expect(coordinator.snapshot?.entries.map(\.url.lastPathComponent) == ["a.png", "b.png", "z-alias.png"])
        #expect(coordinator.currentItemID == .rootRelative(rootID: id, relativePath: "a.png"))
        #expect(coordinator.move(.next))
        #expect(host.visible == b)
        #expect(coordinator.canMove(.next) == false)
        #expect(coordinator.move(.previous))
        #expect(host.visible == a)
        #expect(coordinator.canMove(.previous) == false)
    }
    #expect(host.opens == [b, a, b, a])
    #expect(scope.counts == [3, 3])
}
