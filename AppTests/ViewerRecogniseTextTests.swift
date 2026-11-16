import Foundation
import AppKit
import Testing
import MadoApplication
import MadoInfrastructure

@MainActor private final class FakeTextPasteboard: TextPasteboardWriting {
    var writes: [String] = []
    var succeeds = true
    @discardableResult func copy(_ text: String) -> Bool {
        guard succeeds else { return false }
        writes.append(text)
        return true
    }
}

@MainActor @Test(.timeLimit(.minutes(3))) func viewerRecogniseTextFailedPasteboardWriteNeverClaimsCopy() async {
    let board = FakeTextPasteboard()
    board.succeeds = false
    let identity = UUID()
    let model = RecogniseTextModel(recognise: { _ in
        TextRecognitionResult(text: "found", characterCount: 5, engine: .onDevice, isEmpty: false)
    }, pasteboard: board, isCurrent: { $0 == identity })
    await model.start(Data(), identity: identity).value
    #expect(model.notice == .failed)
    #expect(model.panelText == nil)
    #expect(board.writes.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(3))) func viewerRecogniseTextCopiesGraphemeCountAndCloudLabel() async {
    let board = FakeTextPasteboard()
    let identity = UUID()
    var confirmationReset: (@MainActor () -> Void)?
    let model = RecogniseTextModel(recognise: { _ in
        TextRecognitionResult(text: "e\u{301}中文", characterCount: 99, engine: .cloud, isEmpty: false)
    }, pasteboard: board, isCurrent: { $0 == identity },
       scheduleConfirmationReset: { confirmationReset = $0 })
    await model.start(Data([1]), identity: identity).value
    #expect(board.writes == ["e\u{301}中文"])
    #expect(model.notice == .copied(count: 3, engine: .cloud)) // String.count counts grapheme clusters.
    model.openPanel()
    #expect(model.panelText == "e\u{301}中文")
    model.edit("edited")
    model.copyEditedText()
    #expect(board.writes == ["e\u{301}中文", "edited"])
    #expect(model.panelText == "edited")
    #expect(model.copiedConfirmation)
    confirmationReset?()
    #expect(!model.copiedConfirmation)
}

@MainActor @Test(.timeLimit(.minutes(3))) func viewerRecogniseTextWhitespaceAndErrorNeverWrite() async {
    let board = FakeTextPasteboard()
    let identity = UUID()
    let empty = RecogniseTextModel(recognise: { _ in
        TextRecognitionResult(text: " \n\t", characterCount: 3, engine: .onDevice, isEmpty: false)
    }, pasteboard: board, isCurrent: { $0 == identity })
    await empty.start(Data(), identity: identity).value
    #expect(board.writes.isEmpty)
    #expect(empty.notice == .noText)
    let failure = RecogniseTextModel(recognise: { _ in throw TextRecognitionError.invalidImage },
                                     pasteboard: board, isCurrent: { $0 == identity })
    await failure.start(Data(), identity: identity).value
    #expect(board.writes.isEmpty)
    #expect(failure.notice == .failed)
}

private actor RecognitionGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

private actor RecognitionCounter {
    private var value = 0
    func next() -> Int { value += 1; return value }
}

@MainActor @Test(.timeLimit(.minutes(3))) func viewerRecogniseTextDropsChangedImageAndClosedWindow() async {
    let board = FakeTextPasteboard()
    let a = UUID(), b = UUID()
    var current = a
    let gate = RecognitionGate()
    let model = RecogniseTextModel(recognise: { _ in
        await gate.wait()
        return TextRecognitionResult(text: "old image", characterCount: 9, engine: .onDevice, isEmpty: false)
    }, pasteboard: board, isCurrent: { $0 == current })
    let pending = model.start(Data([1]), identity: a)
    #expect(model.isRunning)
    current = b
    await gate.release()
    await pending.value
    #expect(board.writes.isEmpty)
    #expect(model.notice == nil)
    #expect(!model.isRunning)

    let closeGate = RecognitionGate()
    let closing = RecogniseTextModel(recognise: { _ in
        await closeGate.wait()
        return TextRecognitionResult(text: "too late", characterCount: 8, engine: .onDevice, isEmpty: false)
    }, pasteboard: board, isCurrent: { _ in true })
    let closedPending = closing.start(Data([2]), identity: a)
    closing.close()
    await closeGate.release()
    await closedPending.value
    #expect(board.writes.isEmpty)
    #expect(closing.notice == nil)
    #expect(!closing.isRunning)
}

@MainActor @Test(.timeLimit(.minutes(3))) func viewerRecogniseTextCancellationShowsNothingAndRepeatReplacesNotice() async {
    let board = FakeTextPasteboard()
    let identity = UUID()
    let cancellation = RecogniseTextModel(recognise: { _ in throw TextRecognitionError.cancelled },
                                          pasteboard: board, isCurrent: { $0 == identity })
    await cancellation.start(Data(), identity: identity).value
    #expect(cancellation.notice == nil)
    #expect(!cancellation.isRunning)
    let count = RecognitionCounter()
    let repeated = RecogniseTextModel(recognise: { _ in
        let next = await count.next()
        return TextRecognitionResult(text: "run \(next)", characterCount: 5,
                                     engine: .onDevice, isEmpty: false)
    }, pasteboard: board, isCurrent: { $0 == identity })
    await repeated.start(Data(), identity: identity).value
    #expect(repeated.notice == .copied(count: 5, engine: .onDevice))
    await repeated.start(Data(), identity: identity).value
    #expect(repeated.notice == .copied(count: 5, engine: .onDevice))
    #expect(board.writes == ["run 1", "run 2"])
}

@MainActor @Test(.timeLimit(.minutes(3))) func viewerRecogniseTextPrivatePasteboardPreservesNoTextAndCopiesPlainString() async {
    let board = NSPasteboard(name: .init("mado.issue687.\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    let privateType = NSPasteboard.PasteboardType("mado.issue687.sentinel")
    board.declareTypes([.string, privateType], owner: nil)
    board.setString("sentinel", forType: .string)
    board.setString("other", forType: privateType)
    let beforeCount = board.changeCount
    let beforeTypes = board.types
    let identity = UUID()
    let port = NativeTextPasteboard(board)
    let blank = RecogniseTextModel(recognise: { _ in
        TextRecognitionResult(text: " \n", characterCount: 2, engine: .onDevice, isEmpty: false)
    }, pasteboard: port, isCurrent: { $0 == identity })
    await blank.start(Data(), identity: identity).value
    #expect(board.changeCount == beforeCount)
    #expect(board.types == beforeTypes)
    #expect(board.string(forType: .string) == "sentinel")
    #expect(board.string(forType: privateType) == "other")

    let found = RecogniseTextModel(recognise: { _ in
        TextRecognitionResult(text: "中文 English", characterCount: 10, engine: .onDevice, isEmpty: false)
    }, pasteboard: port, isCurrent: { $0 == identity })
    await found.start(Data(), identity: identity).value
    #expect(board.string(forType: .string) == "中文 English")
    #expect(board.types?.contains(.string) == true)
    #expect(board.types?.allSatisfy { [.string, .init("NSStringPboardType")].contains($0) } == true)
    #expect(board.string(forType: privateType) == nil)
}

@MainActor @Test(.timeLimit(.minutes(3))) func viewerRecogniseTextNativeWriteFailurePreservesPreviousClipboard() throws {
    let board = NSPasteboard(name: .init("mado.issue687.write-failure.\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    let sentinelType = NSPasteboard.PasteboardType("mado.issue687.sentinel")
    board.declareTypes([.string, sentinelType], owner: nil)
    #expect(board.setString("before", forType: .string))
    #expect(board.setString("keep", forType: sentinelType))
    let previousCount = board.changeCount
    let previousTypes = board.types
    var attempted = false
    let port = NativeTextPasteboard(board, writeObjects: { _, objects in
        attempted = true
        #expect(objects.count == 1)
        return false
    })
    #expect(!port.copy("after"))
    #expect(attempted)
    #expect(board.changeCount == previousCount)
    #expect(board.types == previousTypes)
    #expect(board.string(forType: .string) == "before")
    #expect(board.string(forType: sentinelType) == "keep")
}

@MainActor @Test(.timeLimit(.minutes(3))) func viewerRecogniseTextDestinationWriteFailureRestoresPreviousItems() {
    let board = NSPasteboard(name: .init("mado.issue687.destination-failure.\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    let sentinelType = NSPasteboard.PasteboardType("mado.issue687.sentinel")
    board.declareTypes([.string, sentinelType], owner: nil)
    board.setString("before", forType: .string)
    board.setString("keep", forType: sentinelType)
    // #687 fix r6: since F11 the restore also goes through the writer seam, so only the destination write (the
    // first write to `board`) fails; the restore is a real write. A failed restore is F11's own test.
    var destinationAttempted = false
    let port = NativeTextPasteboard(board, writeObjects: { target, objects in
        // Reject the destination text, then let the restore write prove the prior items survive.
        if target === board && (objects.first as? NSPasteboardItem)?.string(forType: .string) == "after" {
            destinationAttempted = true
            return false
        }
        return target.writeObjects(objects)
    })
    #expect(port.copyText("after") == .failed(clipboardIntact: true))
    #expect(destinationAttempted)
    #expect(board.string(forType: .string) == "before")
    #expect(board.string(forType: sentinelType) == "keep")
}

@MainActor @Test(.timeLimit(.minutes(3))) func viewerRecogniseTextRealProviderUsesPrivateNamedPasteboard() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let fixtures = root.appendingPathComponent("TestAssets/TextRecognition")
    let board = NSPasteboard(name: .init("mado.issue687.vision.\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    let privateType = NSPasteboard.PasteboardType("mado.issue687.keep")
    board.declareTypes([.string, privateType], owner: nil)
    board.setString("sentinel", forType: .string)
    board.setString("keep", forType: privateType)
    let beforeCount = board.changeCount
    let beforeTypes = board.types
    let service = TextRecognitionService(onDevice: OnDeviceTextRecognitionProvider())
    let identity = UUID()
    let model = RecogniseTextModel(recognise: { data in try await service.recognise(data, intent: .explicit) },
                                   pasteboard: NativeTextPasteboard(board), isCurrent: { $0 == identity })
    let blank = try Data(contentsOf: fixtures.appendingPathComponent("blank.png"))
    await model.start(blank, identity: identity).value
    #expect(model.notice == .noText)
    #expect(board.changeCount == beforeCount)
    #expect(board.types == beforeTypes)
    #expect(board.string(forType: .string) == "sentinel")
    #expect(board.string(forType: privateType) == "keep")
    let mixed = try Data(contentsOf: fixtures.appendingPathComponent("mixed.png"))
    await model.start(mixed, identity: identity).value
    let text = try #require(board.string(forType: .string))
    #expect(text.contains("中文"))
    #expect(text.contains("Hello Mado"))
    #expect(board.string(forType: privateType) == nil)
    #expect(model.notice == .copied(count: text.count, engine: .onDevice))
}
