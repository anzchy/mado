import Foundation
import Testing
@testable import MadoApplication

// #689b dev1: the factory the App uses passes the outcome observer through, so Recognise Text's log line exists.

private actor Online: NetworkReachabilityPort { func isOnline() async -> Bool { true } }
private struct Words: CloudTextRecognitionProviding {
    func recognise(_ image: Data, credentials: CloudCredentials) async throws(TextRecognitionError) -> String { "百度" }
}
private struct Device: OnDeviceTextRecognitionProviding {
    func recognise(_ image: Data) async throws(TextRecognitionError) -> String { "本机" }
}
private final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [CloudRecognitionOutcome] = []
    func add(_ item: CloudRecognitionOutcome) { lock.lock(); items.append(item); lock.unlock() }
    var all: [CloudRecognitionOutcome] { lock.lock(); defer { lock.unlock() }; return items }
}

@Test(.timeLimit(.minutes(2)))
func issue689bFactoryPassesTheOutcomeObserver() async throws {
    let preferences = MemoryCloudRecognitionPreferences()
    let keys = BaiduCloudCredentialStore(secrets: FakeSecretStore())
    let heard = Heard()
    let service = CloudRecognitionConfiguration.service(onDevice: Device(), preferences: preferences, keys: keys,
                                                        reachability: Online(), cloud: Words(), report: { heard.add($0) })
    _ = try await service.recognise(Data([1]), intent: .explicit)
    await preferences.setEnabled(true)
    await preferences.setConsentRecord(CloudRecognitionConsentRecord(granted: true, date: Date()))
    _ = try await service.recognise(Data([1]), intent: .explicit)
    try await keys.save(CloudCredentials(apiKey: "AK", secretKey: "SK"))
    _ = try await service.recognise(Data([1]), intent: .explicit)
    #expect(heard.all == [.skipped(.disabled), .skipped(.noKeys), .cloud])
}
