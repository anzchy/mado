import Foundation
import Testing
@testable import MadoApplication

private actor Reachability: NetworkReachabilityPort {
    var online: Bool
    init(_ online: Bool) { self.online = online }
    func isOnline() async -> Bool { online }
}
private actor CountingCloud: CloudTextRecognitionProviding {
    private(set) var calls: [CloudCredentials] = []
    let failure: TextRecognitionError?
    init(failing failure: TextRecognitionError? = nil) { self.failure = failure }
    func recognise(_ image: Data, credentials: CloudCredentials) async throws(TextRecognitionError) -> String {
        calls.append(credentials)
        if let failure { throw failure }
        return "百度"
    }
}
private struct OnDevice: OnDeviceTextRecognitionProviding {
    func recognise(_ image: Data) async throws(TextRecognitionError) -> String { "本机" }
}

private struct Row: CustomStringConvertible {
    let name: String
    var enabled = true
    var consent: Bool? = true
    var keys = true
    var online = true
    var cloudFailure: TextRecognitionError?
    var intent = TextRecognitionIntent.explicit
    let engine: TextRecognitionEngine
    var reason: CloudFallbackReason?
    var cloudCalls = 1
    var description: String { name }
}

private let rows: [Row] = [
    Row(name: "all allowed", engine: .cloud),
    Row(name: "switch off", enabled: false, engine: .onDevice, cloudCalls: 0),
    Row(name: "never asked", consent: nil, engine: .onDevice, cloudCalls: 0),
    Row(name: "declined", consent: false, engine: .onDevice, cloudCalls: 0),
    Row(name: "no key", keys: false, engine: .onDevice, cloudCalls: 0),
    Row(name: "offline", online: false, engine: .onDevice, cloudCalls: 0),
    Row(name: "auth error", cloudFailure: .cloudAuth, engine: .onDevice, reason: .auth),
    Row(name: "quota error", cloudFailure: .cloudQuota, engine: .onDevice, reason: .quota),
    Row(name: "offline error", cloudFailure: .cloudOffline, engine: .onDevice, reason: .offline),
    Row(name: "other failure", cloudFailure: .cloudFailure, engine: .onDevice, reason: .failure),
    Row(name: "select on image", intent: .selection, engine: .onDevice, cloudCalls: 0),
]

@Test(.timeLimit(.minutes(2)), arguments: rows)
private func issue689FactoryEngineChoiceRows(_ row: Row) async throws {
    let preferences = MemoryCloudRecognitionPreferences()
    await preferences.setEnabled(row.enabled)
    if let granted = row.consent {
        await preferences.setConsentRecord(CloudRecognitionConsentRecord(granted: granted, date: Date()))
    }
    let secrets = FakeSecretStore()
    let keys = BaiduCloudCredentialStore(secrets: secrets)
    if row.keys { try await keys.save(CloudCredentials(apiKey: "AK", secretKey: "SK")) }
    let cloud = CountingCloud(failing: row.cloudFailure)
    let service = CloudRecognitionConfiguration.service(onDevice: OnDevice(), preferences: preferences, keys: keys,
                                                        reachability: Reachability(row.online), cloud: cloud)
    let result = try await service.recognise(Data([1]), intent: row.intent)
    #expect(result.engine == row.engine, "\(row)")
    #expect(result.text == (row.engine == .cloud ? "百度" : "本机"), "\(row)")
    #expect(result.fallbackReason == row.reason, "\(row)")
    #expect(await cloud.calls.count == row.cloudCalls, "\(row)")
    if row.cloudCalls > 0 { #expect(await cloud.calls.first == CloudCredentials(apiKey: "AK", secretKey: "SK")) }
}

@Test(.timeLimit(.minutes(2)))
func issue689FactoryOptionsMirrorPreferences() async throws {
    let preferences = MemoryCloudRecognitionPreferences()
    let reachability = Reachability(false)
    let configuration = CloudRecognitionConfiguration(preferences: preferences, reachability: reachability)
    var options = await configuration.options()
    #expect(!options.enabled && options.consent == .notAsked && !options.online)
    await preferences.setEnabled(true)
    await preferences.setConsentRecord(CloudRecognitionConsentRecord(granted: false, date: Date()))
    options = await configuration.options()
    #expect(options.enabled && options.consent == .declined && !options.online)
    await preferences.setConsentRecord(CloudRecognitionConsentRecord(granted: true, date: Date()))
    options = await CloudRecognitionConfiguration(preferences: preferences, reachability: Reachability(true)).options()
    #expect(options.enabled && options.consent == .granted && options.online)
}

@Test(.timeLimit(.minutes(2)))
func issue689FactoryStopsUsingBaiduOnceKeysAreRemoved() async throws {
    let preferences = MemoryCloudRecognitionPreferences()
    let secrets = FakeSecretStore()
    let keys = BaiduCloudCredentialStore(secrets: secrets)
    let model = CloudRecognitionSettingsModel(preferences: preferences, keys: keys)
    try await model.saveKeys(apiKey: "AK", secretKey: "SK")
    #expect(await model.answerConsent(granted: true) == .enabled)
    let cloud = CountingCloud()
    let service = CloudRecognitionConfiguration.service(onDevice: OnDevice(), preferences: preferences, keys: keys,
                                                        reachability: Reachability(true), cloud: cloud)
    #expect(try await service.recognise(Data([1]), intent: .explicit).engine == .cloud)
    try await model.removeKeys()
    let after = try await service.recognise(Data([1]), intent: .explicit)
    #expect(after.engine == .onDevice)
    #expect(await cloud.calls.count == 1)
    // Turning the switch back on is refused until keys are saved again.
    #expect(await model.requestEnable() == .needsKeys)
    #expect(try await service.recognise(Data([1]), intent: .explicit).engine == .onDevice)
    #expect(await cloud.calls.count == 1)
}
