import Foundation
import Testing
@preconcurrency import Vision
@testable import MadoInfrastructure
import MadoApplication

private final class VisionRequestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var optionsObserved = false
    private var cancelled = 0
    let blocked = DispatchSemaphore(value: 0)

    func recordOptions(_ request: VNRecognizeTextRequest) {
        lock.lock(); defer { lock.unlock() }
        optionsObserved = request.recognitionLevel == .accurate
            && request.recognitionLanguages == ["zh-Hans", "en-US"]
            && request.usesLanguageCorrection
    }
    func recordCancel(_ request: VNRecognizeTextRequest) {
        request.cancel()
        lock.lock(); cancelled += 1; lock.unlock()
        blocked.signal()
    }
    var configured: Bool { lock.lock(); defer { lock.unlock() }; return optionsObserved }
    var cancelCount: Int { lock.lock(); defer { lock.unlock() }; return cancelled }
}

private func contractImage() throws -> Data {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    return try Data(contentsOf: root.appendingPathComponent("TestAssets/TextRecognition/mixed.png"))
}

@Test(.timeLimit(.minutes(2)))
func issue687FixRequestOptionsAndDiagnosticError() async throws {
    let probe = VisionRequestProbe()
    let provider = OnDeviceTextRecognitionProvider(performRequest: { _, request in
        probe.recordOptions(request)
        throw NSError(domain: "VisionContract", code: 77, userInfo: [NSLocalizedDescriptionKey: "secret image text"])
    })
    do { _ = try await provider.recognise(contractImage()); Issue.record("Expected request error") }
    catch {
        #expect(error as? TextRecognitionError == .recognitionFailed(domain: "VisionContract", code: 77))
        #expect(String(describing: error).contains("secret image text") == false)
    }
    #expect(probe.configured)
}

@Test(.timeLimit(.minutes(2)))
func issue687FixCancellationReachesActiveVisionRequest() async throws {
    let probe = VisionRequestProbe()
    let entered = AsyncStream<Void>.makeStream()
    let provider = OnDeviceTextRecognitionProvider(
        performRequest: { _, _ in
            entered.continuation.yield(())
            _ = probe.blocked.wait(timeout: .now() + 3)
            throw NSError(domain: "VisionContract", code: 78)
        },
        cancelRequest: { probe.recordCancel($0) }
    )
    let bytes = try contractImage()
    let task = Task { try await provider.recognise(bytes) }
    for await _ in entered.stream { break }
    task.cancel()
    do { _ = try await task.value; Issue.record("Expected cancellation") }
    catch { #expect(error as? TextRecognitionError == .cancelled) }
    #expect(probe.cancelCount == 1)
}
