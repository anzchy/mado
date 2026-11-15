import Foundation
import Testing
@testable import MadoInfrastructure
import MadoApplication

private actor VisionPause {
    private var resumeWork: CheckedContinuation<Void, Never>?

    func wait(entered: AsyncStream<Void>.Continuation) async {
        await withCheckedContinuation {
            resumeWork = $0
            entered.yield(())
        }
    }

    func resume() {
        resumeWork?.resume()
    }
}

private func recognitionFixture(_ name: String) throws -> Data {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try Data(contentsOf: root.appendingPathComponent("TestAssets/TextRecognition/\(name)"))
}

/// Tests that run the real Vision recogniser. #706: at most one runs at a time, so on a
/// runner with few CPUs they cannot crowd each other out of Vision's own queues.
/// `OnDeviceTextRecognitionFixTests.swift` adds more tests to this suite.
@Suite(.serialized)
struct OnDeviceRealVisionTests {
    @Test(.timeLimit(.minutes(2)))
    func issue688VisionProvidesNormalizedLineAndCharacterBoxes() async throws {
        let lines = try await OnDeviceTextRecognitionProvider().recogniseLines(recognitionFixture("mixed.png"))
        let chinese = try #require(lines.first { $0.text.contains("中文") })
        let english = try #require(lines.first { $0.text.contains("Hello Mado") })
        #expect(lines.firstIndex { $0.text == chinese.text }! < lines.firstIndex { $0.text == english.text }!)
        for line in [chinese, english] {
            #expect(line.box.minX >= 0 && line.box.minY >= 0)
            #expect(line.box.maxX <= 1 && line.box.maxY <= 1)
            #expect(line.characterBoxes.isEmpty || line.characterBoxes.count == line.text.count)
        }
    }

    @Test(.timeLimit(.minutes(2)))
    func issue687VisionRecognisesChineseAndEnglishInReadingOrder() async throws {
        let provider = OnDeviceTextRecognitionProvider()
        let text = try await provider.recognise(recognitionFixture("mixed.png"))
        #expect(text.contains("中文"))
        #expect(text.contains("Hello Mado"))
        #expect(text.contains("\n"))
        let chinese = try #require(text.range(of: "中文"))
        let english = try #require(text.range(of: "Hello Mado"))
        #expect(chinese.lowerBound < english.lowerBound)
        let side = try #require(text.range(of: "SIDE"))
        #expect(chinese.lowerBound < side.lowerBound)
        #expect(side.lowerBound < english.lowerBound)
    }

    @Test(.timeLimit(.minutes(2)))
    func issue687VisionBlankImageIsEmpty() async throws {
        let provider = OnDeviceTextRecognitionProvider()
        let text = try await provider.recognise(recognitionFixture("blank.png"))
        #expect(text.isEmpty)
    }

    @Test(.timeLimit(.minutes(2)))
    func issue687VisionInvalidImageIsTypedError() async {
        let provider = OnDeviceTextRecognitionProvider()
        do {
            _ = try await provider.recognise(Data([0x00, 0x01, 0x02]))
            Issue.record("Expected invalidImage")
        } catch {
            #expect(error == .invalidImage)
        }
    }

    @Test(.timeLimit(.minutes(2)))
    func issue687VisionPreCancelledTaskIsTypedError() async throws {
        let bytes = try recognitionFixture("mixed.png")
        let provider = OnDeviceTextRecognitionProvider()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await provider.recognise(bytes)
        }
        do {
            _ = try await task.value
            Issue.record("Expected cancelled")
        } catch {
            #expect(error as? TextRecognitionError == .cancelled)
        }
    }
}

@Test(.timeLimit(.minutes(2)))
func issue687VisionUnexpectedRequestFailureIsTyped() async throws {
    let provider = OnDeviceTextRecognitionProvider(performRequest: { _, _ in
        throw NSError(domain: "vision-test", code: 1)
    }, cancelRequest: { $0.cancel() })
    do {
        _ = try await provider.recognise(recognitionFixture("mixed.png"))
        Issue.record("Expected recognitionFailed")
    } catch {
        #expect(error as? TextRecognitionError == .recognitionFailed(domain: "vision-test", code: 1))
    }
}

@Test(.timeLimit(.minutes(2)))
func issue687VisionCancellationDuringRequestIsTyped() async throws {
    let pause = VisionPause()
    let entered = AsyncStream<Void>.makeStream()
    let provider = OnDeviceTextRecognitionProvider(
        performRequest: { _, _ in throw NSError(domain: "vision-test", code: 2) },
        beforePerform: {
            await pause.wait(entered: entered.continuation)
        },
        cancelRequest: { $0.cancel() }
    )
    let bytes = try recognitionFixture("mixed.png")
    let task = Task { try await provider.recognise(bytes) }
    for await _ in entered.stream { break }
    task.cancel()
    await pause.resume()
    do {
        _ = try await task.value
        Issue.record("Expected cancelled")
    } catch {
        #expect(error as? TextRecognitionError == .cancelled)
    }
}
