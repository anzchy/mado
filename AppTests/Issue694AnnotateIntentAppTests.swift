import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

// #694 P7-11 WI-2 (CAP-02, EDIT-07): a Capture opened from the thumbnail's 标注 arrives as a File Grant open with an
// annotate target; Mado shows it and enters Annotate Mode on it. Real grants, folder scanning and ImageIO loading
// (Issue690Context), with the window ordered out.

@MainActor private func controller694(_ context: Issue690Context) throws -> CanvasWindowController {
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(), preferencesStore: InMemoryDisplayPreferencesStore(),
        accessServices: Task { context.services }, motionPolicy: MotionPolicy(source: Issue349Motion()))
    context.controller = controller
    controller.annotateUI = context.ui
    controller.annotatePasteboard = context.pasteboard
    let window = try #require(controller.window)
    issue690UnconstrainFrame(window)
    window.setContentSize(NSSize(width: 1280, height: 800))
    window.orderOut(nil)
    return controller
}

@MainActor @Suite(.serialized) struct Issue694AnnotateIntentAppTests {
    /// Cold: no image on screen; the Capture (a File Grant) opens straight into Annotate Mode.
    @Test func issue694ColdOpenEntersAnnotateMode() async throws {
        let context = try await Issue690Context(grant: false)
        defer { context.close() }
        let controller = try controller694(context)
        controller.openInput([context.first], annotate: context.first)
        try await waitUntil("a.png shown in Annotate Mode", timeout: .seconds(60)) {
            controller.session.isAnnotating && controller.session.imageLoader.fileURL == context.first
        }
        #expect(controller.session.annotateMode?.fileURL == context.first)
        #expect(controller.session.annotateMode?.tool == .rectangle)
        #expect(controller.session.annotateOnShow == nil)
        // The ⌘E path: tool letters and ⌘S reach Annotate Mode without another click.
        try context.key("a", code: 0)
        #expect(controller.session.annotateMode?.tool == .arrow)
    }

    /// Warm: another image shows; the Capture replaces it and Annotate Mode is on the Capture, not the old image.
    @Test func issue694WarmOpenReplacesImageThenAnnotates() async throws {
        let context = try await Issue690Context()
        defer { context.close() }
        let controller = try await context.open()
        controller.openInput([context.second], annotate: context.second)
        try await waitUntil("b.png shown in Annotate Mode", timeout: .seconds(60)) {
            controller.session.isAnnotating && controller.session.imageLoader.fileURL == context.second
        }
        #expect(controller.session.annotateMode?.fileURL == context.second)
    }

    /// A plain open (Finder, 在 Mado 中打开) never enters Annotate Mode.
    @Test func issue694PlainOpenOnlyViews() async throws {
        let context = try await Issue690Context()
        defer { context.close() }
        let controller = try await context.open()
        controller.openInput([context.second])
        try await waitUntil("b.png shown", timeout: .seconds(60)) {
            controller.session.imageStatus == .showing && controller.session.imageLoader.fileURL == context.second
        }
        #expect(!controller.session.isAnnotating)
        #expect(controller.session.annotateOnShow == nil)
    }

    /// Annotating another image with unsaved marks: 不存储 opens the Capture in Annotate Mode (the intent survives the
    /// retry); 取消 keeps the first image and its marks and drops the intent.
    @Test func issue694IntentSurvivesLeavePromptRetry() async throws {
        let context = try await Issue690Context()
        defer { context.close() }
        let controller = try await context.open()
        controller.enterAnnotateMode()
        context.mark()
        context.ui.answer = .discard
        controller.openInput([context.second], annotate: context.second)
        #expect(context.ui.asked == [.changeImage])
        try await waitUntil("b.png shown in Annotate Mode after 不存储", timeout: .seconds(60)) {
            controller.session.isAnnotating && controller.session.imageLoader.fileURL == context.second
        }
        #expect(controller.session.annotateMode?.document.marks.isEmpty == true)
    }

    @Test func issue694CancelDropsIntent() async throws {
        let context = try await Issue690Context()
        defer { context.close() }
        let controller = try await context.open()
        controller.enterAnnotateMode()
        context.mark()
        context.ui.answer = .cancel
        controller.openInput([context.second], annotate: context.second)
        #expect(context.ui.asked == [.changeImage])
        #expect(controller.session.annotateOnShow == nil)
        #expect(controller.session.imageLoader.fileURL == context.first)
        #expect(controller.session.annotateMode?.fileURL == context.first)
        #expect(controller.session.annotateMode?.document.marks.count == 1)
    }

    /// Another open before the Capture shows: that image is shown plain.
    @Test func issue694IntentDroppedOnLaterOpen() async throws {
        let context = try await Issue690Context()
        defer { context.close() }
        let controller = try await context.open()
        controller.openInput([context.second], annotate: context.second)
        controller.openInput([context.first])
        #expect(controller.session.annotateOnShow == nil)
        try await waitUntil("a.png shown", timeout: .seconds(60)) {
            controller.session.imageStatus == .showing && controller.session.imageLoader.fileURL == context.first
        }
        for _ in 0..<50 { await Task.yield() }
        #expect(!controller.session.isAnnotating)
    }

    @Test func issue694IntentDroppedOnWindowClose() async throws {
        let context = try await Issue690Context(grant: false)
        defer { context.close() }
        let controller = try controller694(context)
        controller.openInput([context.first], annotate: context.first)
        #expect(controller.session.annotateOnShow != nil)
        let window = try #require(controller.window)
        #expect(controller.windowShouldClose(window))
        #expect(controller.session.annotateOnShow == nil)
    }

    /// An unsupported file never enters Annotate Mode and leaves no intent behind.
    @Test func issue694LoadFailureDropsIntentInWindow() async throws {
        let context = try await Issue690Context(grant: false)
        defer { context.close() }
        let broken = context.folder.appendingPathComponent("broken.png")
        try Data("not a png".utf8).write(to: broken)
        let controller = try controller694(context)
        controller.openInput([broken], annotate: broken)
        try await waitUntil("the intent is dropped", timeout: .seconds(60)) { controller.session.annotateOnShow == nil }
        #expect(!controller.session.isAnnotating)
    }
}
