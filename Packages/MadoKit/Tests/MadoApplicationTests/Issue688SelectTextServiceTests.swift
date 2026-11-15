import Foundation
import Testing
@testable import MadoApplication

private actor Calls {
    var cloud = 0
    func called() { cloud += 1 }
}
private struct Device: OnDeviceTextRecognitionProviding {
    func recognise(_ image: Data) async throws(TextRecognitionError) -> String { "old" }
    func recogniseLines(_ image: Data) async throws(TextRecognitionError) -> [TextRecognitionLine] {
        [TextRecognitionLine(text: "中文", box: CGRect(x: 0.1, y: 0.7, width: 0.3, height: 0.1)),
         TextRecognitionLine(text: "English", box: CGRect(x: 0.1, y: 0.5, width: 0.4, height: 0.1))]
    }
}
private struct Settings: CloudRecognitionSettings {
    func options() async -> CloudRecognitionOptions { .init(enabled: true, consent: .granted, online: true) }
}
private struct Keys: CloudCredentialStore {
    func credentials() async -> CloudCredentials? { .init(apiKey: "configured", secretKey: "consented") }
}
private struct Cloud: CloudTextRecognitionProviding {
    let calls: Calls
    func recognise(_ image: Data, credentials: CloudCredentials) async throws(TextRecognitionError) -> String {
        await calls.called()
        return "uploaded"
    }
}

private actor LegacyCalls {
    var count = 0
    func record() { count += 1 }
}
private struct LegacyDevice: OnDeviceTextRecognitionProviding {
    let calls: LegacyCalls
    func recognise(_ image: Data) async throws(TextRecognitionError) -> String {
        await calls.record()
        return "legacy result"
    }
}

@Suite(.timeLimit(.minutes(2))) struct Issue688SelectTextServiceTests {
@Test func issue688SelectionAlwaysStaysOnDeviceWithCloudConfigured() async throws {
    let calls = Calls()
    let service = TextRecognitionService(onDevice: Device(), settings: Settings(), credentialStore: Keys(), cloud: Cloud(calls: calls))
    let result = try await service.recognise(Data([1]), intent: .selectOnImage)
    #expect(result.engine == .onDevice)
    #expect(result.text == "中文\nEnglish")
    #expect(result.lines.count == 2)
    let first = try #require(result.lines.first)
    #expect(first.box.minX == 0.1)
    #expect(await calls.cloud == 0)
}

@Test func issue688LegacyOnDeviceProviderHasNoFabricatedSelectionBoxes() async throws {
    let calls = LegacyCalls()
    let lines = try await LegacyDevice(calls: calls).recogniseLines(Data([1]))
    #expect(lines.isEmpty)
    #expect(await calls.count == 1)
}
}
