import Foundation
import Testing
import MadoCore
import MadoApplication

@Test func accessNavigationAsksForGrantAndStepsInFinderOrderWithoutWrapping() {
    let folder = URL(fileURLWithPath: "/photos")
    let a = folder.appendingPathComponent("image1.jpg")
    let b = folder.appendingPathComponent("image2.jpg")
    let c = folder.appendingPathComponent("image10.jpg")
    let navigation = FolderNavigation(images: [c, a, b])
    #expect(navigation.images == [a, b, c])
    #expect(navigation.step(from: a, direction: .next, covered: false) == .needsGrant(folder))
    #expect(navigation.step(from: b, direction: .previous, covered: false) == .needsGrant(folder))
    #expect(navigation.step(from: a, direction: .next, covered: true) == .move(b))
    #expect(navigation.step(from: c, direction: .previous, covered: true) == .move(b))
    #expect(navigation.step(from: a, direction: .previous, covered: true) == .end)
    #expect(navigation.step(from: c, direction: .next, covered: true) == .end)
    #expect(navigation.step(from: folder.appendingPathComponent("missing.jpg"), direction: .next, covered: true) == .end)
    #expect(FolderNavigation(images: []).step(from: a, direction: .next, covered: true) == .end)
}

@MainActor private final class AccessNavigationTarget: ViewerSessionNavigationHost {
    var commands: [CommandID] = []
    var hasImage = true
    var canNavigate = true
    func navigate(_ direction: NavigationDirection) {
        commands.append(direction == .next ? .next : .previous)
    }
    func performCanvas(_ command: CommandID, from entry: CommandEntry) { commands.append(command) }
    func requestOpen() { commands.append(.open) }
    func applyFocus(_ focus: FocusContext) {}
    func showInspector(_ visible: Bool) {}
}

@Test(.timeLimit(.minutes(2))) @MainActor func accessArrowCommandsRouteFromAllEntriesAndRespectTextInput() {
    let target = AccessNavigationTarget()
    let session = ViewerSession(host: target)
    for entry in CommandEntry.allCases {
        session.updateFocus(.canvas)
        #expect(CommandRouter().route(.next, from: entry, to: session))
        session.setInspectorVisible(true)
        session.updateFocus(.panel)
        #expect(CommandRouter().route(.previous, from: entry, to: session))
    }
    #expect(target.commands == [.next, .previous, .next, .previous, .next, .previous])
    session.updateFocus(.textInput)
    #expect(!CommandRouter().route(.next, from: .key, to: session))
    session.updateFocus(.canvas)
    session.setMenuTracking(true)
    #expect(!CommandRouter().route(.previous, from: .key, to: session))
    #expect(CommandID.menuCommands.contains(.next) && CommandID.menuCommands.contains(.previous))
    #expect(CommandID.next.shortcutHint != nil && CommandID.previous.shortcutHint != nil)
}

@Test func accessNavigationMatchesCanonicalFileRepresentations() throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: base) }
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    let first = base.appendingPathComponent("a space.jpg")
    let second = base.appendingPathComponent("b.jpg")
    try Data().write(to: first)
    let alias = base.appendingPathComponent("alias.jpg")
    try fm.createSymbolicLink(at: alias, withDestinationURL: first)
    let navigation = FolderNavigation(images: [first, second])
    #expect(navigation.step(from: alias, direction: .next, covered: true) == .move(second))
    let directoryHint = URL(fileURLWithPath: first.path, isDirectory: true)
    #expect(navigation.step(from: directoryHint, direction: .next, covered: true) == .move(second))
    let escaped = try #require(URL(string: first.absoluteString.replacingOccurrences(of: "a%20", with: "%61%20")))
    #expect(navigation.step(from: escaped, direction: .next, covered: true) == .move(second))
}

@Test(.timeLimit(.minutes(2))) @MainActor func accessSessionKeepsPreviewSteppingAndFolderHostAvailabilitySeparate() {
    let target = AccessNavigationTarget()
    let session = ViewerSession(host: target)
    let router = CommandRouter(implementedCommands: Set(CommandID.allCases))
    target.canNavigate = false
    #expect(!router.route(.next, from: .menu, to: session))
    #expect(!router.route(.previous, from: .button, to: session))
    target.canNavigate = true
    let first = ItemID.ephemeral(UUID()); let second = ItemID.ephemeral(UUID())
    session.beginBrowsing(items: [first, second], sourceVersion: .init(1), scrollAnchor: first)
    session.select(first)
    #expect(!router.route(.next, from: .key, to: session))
    #expect(router.route(.preview, from: .key, to: session))
    #expect(router.route(.next, from: .key, to: session))
    #expect(session.currentItemID == second)
    #expect(router.route(.previous, from: .button, to: session))
    #expect(session.currentItemID == first)
    #expect(target.commands.isEmpty)
    #expect(router.route(.escape, from: .key, to: session))
    #expect(session.mode == .browsing)
    #expect(!router.route(.next, from: .key, to: session))
    // Independent file-opening windows have no Preview Set and use their own host.
    let other = ViewerSession(host: target)
    #expect(router.route(.next, from: .menu, to: other))
    #expect(target.commands == [.next])
    #expect(session.mode == .browsing && session.currentItemID == first)
}
