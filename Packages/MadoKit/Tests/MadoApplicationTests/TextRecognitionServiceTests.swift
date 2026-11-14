import Foundation
import Testing
@testable import MadoApplication

private struct FakeTextProvider: OnDeviceTextRecognitionProviding {
    let result: Result<String, TextRecognitionError>

    func recognise(_ image: Data) async throws(TextRecognitionError) -> String {
        switch result {
        case .success(let text): return text
        case .failure(let error): throw error
        }
    }
}

@Test(.timeLimit(.minutes(2)), arguments: [TextRecognitionIntent.selection, .explicit])
func issue687ServiceUsesOnDeviceForBothIntents(intent: TextRecognitionIntent) async throws {
    for expected in ["Hello", "中文 English", "é🙂"] {
        let service = TextRecognitionService(onDevice: FakeTextProvider(result: .success(expected)))
        let result = try await service.recognise(Data([1]), intent: intent)
        #expect(result.text == expected)
        #expect(result.characterCount == expected.count)
        #expect(result.engine == .onDevice)
        #expect(result.isEmpty == false)
    }
}

@Test(.timeLimit(.minutes(2)))
func issue687ServiceEmptyResult() async throws {
    let service = TextRecognitionService(onDevice: FakeTextProvider(result: .success("")))
    let result = try await service.recognise(Data([1]), intent: .explicit)
    #expect(result.text == "")
    #expect(result.characterCount == 0)
    #expect(result.engine == .onDevice)
    #expect(result.isEmpty)
}

@Test(.timeLimit(.minutes(2)))
func issue687ServicePropagatesTypedError() async {
    let service = TextRecognitionService(onDevice: FakeTextProvider(result: .failure(.invalidImage)))
    do {
        _ = try await service.recognise(Data(), intent: .selection)
        Issue.record("Expected invalidImage")
    } catch {
        #expect(error == .invalidImage)
    }
}
