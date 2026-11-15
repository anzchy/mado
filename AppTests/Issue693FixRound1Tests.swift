import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoMacUI

// #693 slice B fix round 1 (i693b-fix1-brief.md): the hint link keeps the Annotate keys (opus M1), the redaction
// source read belongs to one overlay and retries after a failure (gpt M2), and Return waits for a held crop drag
// (opus L5). The #690 harness: page 39's 1600×2400 image, 1280×800 window.

/// Holds each source read until the test answers it.
@MainActor private final class SourceReads {
    private(set) var urls: [URL] = []
    private var pending: [CheckedContinuation<AnnotationOverlayView.RedactionSource?, Never>?] = []

    func read(_ url: URL) async -> AnnotationOverlayView.RedactionSource? {
        urls.append(url)
        return await withCheckedContinuation { pending.append($0) }
    }

    func answer(_ index: Int, _ value: AnnotationOverlayView.RedactionSource?) {
        pending[index]?.resume(returning: value)
        pending[index] = nil
    }

    /// Lets a test end without leaving a read suspended.
    func finish() { for index in pending.indices { answer(index, nil) } }
}

@MainActor private func tinySource() throws -> AnnotationOverlayView.RedactionSource {
    let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    return AnnotationOverlayView.RedactionSource(image: try #require(context.makeImage()), orientation: 1)
}

@MainActor @Suite(.serialized) struct Issue693FixRound1Tests {
    /// opus M1: a click on the hint would make it first responder; after 改用实色块 the Annotate keys still act.
    @Test(.timeLimit(.minutes(3))) func issue693LinkClickKeepsAnnotateKeys() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        controller.enterAnnotateMode()
        try context.key("m", code: 46)
        try context.drag(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
        let popover = try context.popover()
        let window = try #require(controller.window)
        // What NSWindow does with a mouse-down on the hint: offer it the keys.
        _ = window.makeFirstResponder(popover.hintView)
        _ = popover.textView(popover.hintView, clickedOnLink: "mado-annotate:solid", at: 0)
        #expect(context.marks().first?.redaction == .solid)
        #expect(window.firstResponder !== popover.hintView, "the hint does not keep the keys")
        try context.key("c", code: 8)
        #expect(controller.session.annotateMode?.tool == .crop, "C still chooses 裁剪")
        try context.key("z", code: 6, modifiers: [.command])
        #expect(context.marks().first?.redaction == .mosaic(strength: 24), "⌘Z still undoes the restyle")
        try context.key("m", code: 46)
        #expect(controller.session.annotateMode?.tool == .redact)
    }

    /// gpt M2: a read started for one Annotate session never reaches the next one's overlay.
    @Test(.timeLimit(.minutes(3))) func issue693StaleSourceReadDoesNotReachANewerSession() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        let reads = SourceReads()
        defer { reads.finish() }
        controller.annotateRedactionSourceRead = { await reads.read($0) }
        controller.enterAnnotateMode()
        try context.key("m", code: 46)
        try context.drag(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
        try await waitUntil("the first read started") { reads.urls.count == 1 }
        // Leave (discarding the redaction) and come back to the same file before the read ends.
        context.ui.answer = .discard
        try context.escape()
        #expect(!controller.session.isAnnotating)
        controller.enterAnnotateMode()
        try context.key("m", code: 46)
        try context.drag(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
        try await waitUntil("the second session read started") { reads.urls.count == 2 }
        #expect(reads.urls == [context.first, context.first])
        let overlay = try context.overlay()
        let stale = try tinySource(), fresh = try tinySource()
        reads.answer(0, stale)
        try await context.settle()
        #expect(overlay.redactionSource == nil, "the first session's read is dropped")
        reads.answer(1, fresh)
        try await waitUntil("the second read is shown") { overlay.redactionSource != nil }
        #expect(overlay.redactionSource?.image === fresh.image)
    }

    /// gpt M2: a failed read is tried again on the next redaction.
    @Test(.timeLimit(.minutes(3))) func issue693FailedSourceReadRetriesOnTheNextRedaction() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        let reads = SourceReads()
        defer { reads.finish() }
        controller.annotateRedactionSourceRead = { await reads.read($0) }
        controller.enterAnnotateMode()
        try context.key("m", code: 46)
        try context.drag(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
        try await waitUntil("the first read started") { reads.urls.count == 1 }
        reads.answer(0, nil)
        try await context.settle()
        #expect(reads.urls.count == 1, "nothing retries on its own")
        try context.drag(from: CGPoint(x: 600, y: 400), to: CGPoint(x: 700, y: 500))
        try await context.settle()
        #expect(reads.urls.count == 2, "the next redaction reads again")
        let source = try tinySource()
        if reads.urls.count == 2 { reads.answer(1, source) }
        let overlay = try context.overlay()
        try await context.settle()
        #expect(overlay.redactionSource?.image === source.image)
    }

    /// opus L5: Return while a crop drag is held does nothing; the release proposes the new crop.
    @Test(.timeLimit(.minutes(3))) func issue693ReturnDuringACropDragIsIgnored() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        controller.enterAnnotateMode()
        try context.key("c", code: 8)
        let a = try #require(context.expectedCrop(CGPoint(x: 400, y: 200), CGPoint(x: 500, y: 300)))
        try context.drag(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
        #expect(context.pendingCrop() == a)
        let b = try #require(context.expectedCrop(CGPoint(x: 600, y: 400), CGPoint(x: 700, y: 600)))
        try context.press(CGPoint(x: 600, y: 400), to: CGPoint(x: 700, y: 600))
        try context.returnKey()
        #expect(context.crop() == nil, "Return during the drag applies nothing")
        #expect(controller.session.annotateMode?.document.canUndo == false)
        try context.release(CGPoint(x: 700, y: 600))
        #expect(context.pendingCrop() == b && context.crop() == nil)
        try context.returnKey()
        #expect(context.crop() == b)
    }
}
