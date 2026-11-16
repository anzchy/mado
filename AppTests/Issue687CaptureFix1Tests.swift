import AppKit
import Testing
import MadoApplication

// #687c fix round 1: a Capture or selection that starts while a 截图并识别文字 read is pending makes that read stale
// (F1); the helper panel's editor answers the Edit key equivalents without an Edit menu (M1).
// Every wait here ends within `fix1Limit`: a stub that never answers fails, it never hangs.

private let fix1Limit = Duration.seconds(5)
private struct Fix1ReadFailed: Error {}

/// Counts recognitions and answers each with the PNG's own text.
private final class Fix1Recognitions: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [Data] = []
    var count: Int { lock.withLock { calls.count } }
    var recognise: CaptureRecogniseTextPresenter.Recognise {
        { [self] png in
            lock.withLock { calls.append(png) }
            let text = String(decoding: png, as: UTF8.self)
            return TextRecognitionResult(text: text, characterCount: text.count, engine: .onDevice, isEmpty: false)
        }
    }
}

/// A screen read the test releases; unreleased, it fails after `fix1Limit`.
@MainActor private final class Fix1Read {
    let png: Data
    var started = false
    var released = false
    var failure: Error?
    init(_ text: String) { png = Data(text.utf8) }
    func read() async throws -> (png: Data, visibleFrame: NSRect) {
        started = true
        let deadline = ContinuousClock.now + fix1Limit
        while !released {
            guard ContinuousClock.now < deadline else { throw Fix1ReadFailed() }
            try await Task.sleep(for: .milliseconds(5))
        }
        if let failure { throw failure }
        return (png, NSRect(x: 0, y: 25, width: 1440, height: 875))
    }
}

/// One `recognise` call's outcome, filled in when it returns.
@MainActor private final class Fix1Call {
    var finished = false
    var presented: Task<Void, Never>?
    var error: Error?
    var willPresentCount = 0
}

@MainActor private final class Fix1Harness {
    let recognitions = Fix1Recognitions()
    let pasteboard = NSPasteboard(name: .init("mado.test.687c.fix1.\(UUID().uuidString)"))
    let presenter: CaptureRecogniseTextPresenter

    init() {
        _ = NSApplication.shared
        presenter = CaptureRecogniseTextPresenter(recognise: recognitions.recognise,
                                                  pasteboard: NativeTextPasteboard(pasteboard),
                                                  scheduleDismiss: { _, _ in }, scheduleConfirmationReset: { _ in },
                                                  announce: { _ in })
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)
    }
    func close() { presenter.dismiss(); presenter.panel.orderOut(nil); pasteboard.releaseGlobally() }

    /// Starts 截图并识别文字 on `read`; the call's outcome lands in the returned record.
    func start(_ read: Fix1Read) -> Fix1Call {
        let call = Fix1Call()
        Task { @MainActor in
            do {
                call.presented = try await presenter.recognise(read: { try await read.read() },
                                                               willPresent: { call.willPresentCount += 1 })
            } catch { call.error = error }
            call.finished = true
        }
        return call
    }
    func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + fix1Limit
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
    /// The presented recognition, awaited at most `fix1Limit`.
    func finish(_ task: Task<Void, Never>?) async -> Bool {
        guard let task else { return false }
        var done = false
        Task { await task.value; done = true }
        return await eventually { done }
    }
}

// MARK: - F1

/// A read pending when another Capture or selection starts (which dismisses the presenter) shows nothing and leaves
/// the clipboard alone when it resumes.
@MainActor @Test(.timeLimit(.minutes(3))) func issue687CaptureFix1DismissDuringReadPresentsNothing() async throws {
    let h = Fix1Harness()
    defer { h.close() }
    let changeCount = h.pasteboard.changeCount
    let a = Fix1Read("text A")
    let call = h.start(a)
    #expect(await h.eventually { a.started }, "A's screen read is pending")
    h.presenter.dismiss()  // B starts: CaptureHelperMain's capture() / startSelection
    a.released = true
    #expect(await h.eventually { call.finished }, "A resumes and returns")
    #expect(call.presented == nil, "A presents nothing")
    #expect(call.willPresentCount == 0, "A does not touch the status panel either")
    #expect(call.error == nil)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(h.recognitions.count == 0, "A's image is never recognised")
    #expect(!h.presenter.panel.isVisible)
    #expect(h.presenter.overlay.noticeView == nil && h.presenter.overlay.panelView == nil)
    #expect(h.pasteboard.changeCount == changeCount, "the clipboard is untouched")
    #expect(h.pasteboard.string(forType: .string) == "before")
}

/// B's result stays when A's stale read resumes after B presented.
@MainActor @Test(.timeLimit(.minutes(3))) func issue687CaptureFix1LaterRecogniseKeepsItsResult() async throws {
    let h = Fix1Harness()
    defer { h.close() }
    let a = Fix1Read("text A")
    let callA = h.start(a)
    #expect(await h.eventually { a.started })
    h.presenter.dismiss()  // B's selection starts
    let b = Fix1Read("text B")
    b.released = true
    let callB = h.start(b)
    #expect(await h.eventually { callB.finished })
    #expect(await h.finish(callB.presented), "B presents")
    #expect(h.pasteboard.string(forType: .string) == "text B")
    let afterB = h.pasteboard.changeCount
    a.released = true
    #expect(await h.eventually { callA.finished })
    #expect(callA.presented == nil)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(h.recognitions.count == 1, "only B's image is recognised")
    #expect(h.pasteboard.changeCount == afterB && h.pasteboard.string(forType: .string) == "text B")
    #expect(h.presenter.overlay.noticeView != nil, "B's notice stays")
}

/// A stale read's failure is dropped (the newer operation reports its own); a current failure still throws.
@MainActor @Test(.timeLimit(.minutes(3))) func issue687CaptureFix1StaleReadFailureIsDropped() async throws {
    let h = Fix1Harness()
    defer { h.close() }
    let stale = Fix1Read("stale")
    stale.failure = Fix1ReadFailed()
    let staleCall = h.start(stale)
    #expect(await h.eventually { stale.started })
    h.presenter.dismiss()
    stale.released = true
    #expect(await h.eventually { staleCall.finished })
    #expect(staleCall.error == nil, "a stale failure is not reported")
    #expect(staleCall.presented == nil)
    let current = Fix1Read("current")
    current.failure = Fix1ReadFailed()
    current.released = true
    let currentCall = h.start(current)
    #expect(await h.eventually { currentCall.finished })
    #expect(currentCall.error is Fix1ReadFailed, "a current failure is reported")
    #expect(currentCall.willPresentCount == 0)
}

/// With nothing in between, a read presents: the status panel is hidden first and the text is copied.
@MainActor @Test(.timeLimit(.minutes(3))) func issue687CaptureFix1CurrentReadPresents() async throws {
    let h = Fix1Harness()
    defer { h.close() }
    let a = Fix1Read("current text")
    a.released = true
    let call = h.start(a)
    #expect(await h.eventually { call.finished })
    #expect(call.willPresentCount == 1)
    #expect(await h.finish(call.presented))
    #expect(h.recognitions.count == 1)
    #expect(h.pasteboard.string(forType: .string) == "current text")
    #expect(h.presenter.overlay.noticeView != nil)
}
