import AppKit
import Testing
import MadoCore
import MadoApplication

// #687 fix r5b F11 (amendment 4; review M7 + L9): a failed copy says the clipboard may have changed whenever the
// snapshot missed a representation or the restore failed; it never claims the clipboard is unchanged then.

@MainActor private final class Fix5bSilentProvider: NSObject, NSPasteboardItemDataProvider {
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {}
}

@MainActor private func fix5bBoard(lazyType: Bool, provider: Fix5bSilentProvider) -> NSPasteboard {
    let board = NSPasteboard(name: .init("mado.issue687.fix5b.\(UUID().uuidString)"))
    board.clearContents()
    let item = NSPasteboardItem()
    item.setString("before", forType: .string)
    if lazyType { item.setDataProvider(provider, forTypes: [.init("com.example.mado.lazy")]) }
    board.writeObjects([item])
    return board
}

/// The writer fails the calls whose index is in `failing` (0 is the staging pasteboard, 1 the clipboard, 2 the restore).
@MainActor private func fix5bWriter(failing: Set<Int>) -> @MainActor (NSPasteboard, [NSPasteboardWriting]) -> Bool {
    var call = 0
    return { board, objects in
        defer { call += 1 }
        return failing.contains(call) ? false : board.writeObjects(objects)
    }
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue687Fix5bFailedCopyReportsWhetherTheClipboardSurvived() {
    let provider = Fix5bSilentProvider()
    // A representation the snapshot could not read: the restore cannot bring it back.
    let lazy = fix5bBoard(lazyType: true, provider: provider)
    defer { lazy.releaseGlobally() }
    #expect(NativeTextPasteboard(lazy, writeObjects: fix5bWriter(failing: [1])).copyText("new") == .failed(clipboardIntact: false))
    // The restore itself fails.
    let plain = fix5bBoard(lazyType: false, provider: provider)
    defer { plain.releaseGlobally() }
    #expect(NativeTextPasteboard(plain, writeObjects: fix5bWriter(failing: [1, 2])).copyText("new") == .failed(clipboardIntact: false))
    // A complete snapshot restored: intact, and the old string is back.
    let restored = fix5bBoard(lazyType: false, provider: provider)
    defer { restored.releaseGlobally() }
    #expect(NativeTextPasteboard(restored, writeObjects: fix5bWriter(failing: [1])).copyText("new") == .failed(clipboardIntact: true))
    #expect(restored.string(forType: .string) == "before")
    // Success is unchanged.
    let success = fix5bBoard(lazyType: false, provider: provider)
    defer { success.releaseGlobally() }
    #expect(NativeTextPasteboard(success).copyText("new") == .copied)
    #expect(success.string(forType: .string) == "new")
}

@MainActor private final class Fix5bFailingBoard: TextPasteboardWriting {
    var result: TextCopyResult = .failed(clipboardIntact: false)
    @discardableResult func copy(_ text: String) -> Bool { result == .copied }
    func copyText(_ text: String) -> TextCopyResult { result }
}

/// In the viewer: the honest wording for a clipboard that may have changed; the intact failure keeps today's.
@MainActor @Test(.timeLimit(.minutes(3))) func issue687Fix5bViewerNoticeSaysTheClipboardMayHaveChanged() async throws {
    let h = try await Fix5bHarness()
    defer { h.close() }
    try await h.reset(inspector: false)
    let board = Fix5bFailingBoard()
    h.controller.recogniseTextAdapter.makeTextPasteboard = { _ in board }
    try await h.recognise()
    let changed = try #require(h.overlay?.noticeView)
    #expect(changed.messageLabel.stringValue == "Couldn't copy the text · The clipboard may have changed")
    #expect(changed.kind == .warning)
    board.result = .failed(clipboardIntact: true)
    try await h.recognise()
    #expect(h.overlay?.noticeView?.messageLabel.stringValue == "Unable to recognise text")
    board.result = .copied
    try await h.recognise()
    #expect(h.overlay?.noticeView?.messageLabel.stringValue.hasPrefix("Copied") == true)
}
