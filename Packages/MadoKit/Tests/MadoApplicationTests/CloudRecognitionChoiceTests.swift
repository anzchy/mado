import Foundation
import Testing
@testable import MadoApplication

private struct ChoiceSettings: CloudRecognitionSettings {
    let value: CloudRecognitionOptions
    func options() async -> CloudRecognitionOptions { value }
}
private struct ChoiceKeys: CloudCredentialStore {
    let value: CloudCredentials?
    func credentials() async -> CloudCredentials? { value }
}
private actor CloudCalls: CloudTextRecognitionProviding {
    var count = 0
    let outcome: Result<String, TextRecognitionError>
    init(_ outcome: Result<String, TextRecognitionError> = .success("cloud words")) { self.outcome = outcome }
    func recognise(_ image: Data, credentials: CloudCredentials) async throws(TextRecognitionError) -> String {
        count += 1
        switch outcome { case .success(let value): return value; case .failure(let error): throw error }
    }
}
private struct LocalWords: OnDeviceTextRecognitionProviding {
    func recognise(_ image: Data) async throws(TextRecognitionError) -> String { "local words" }
}
private let keys = CloudCredentials(apiKey: "api", secretKey: "secret")

@Test(.timeLimit(.minutes(2)))
func issue689SelectionNeverUploads() async throws {
    let cloud = CloudCalls()
    let service = TextRecognitionService(onDevice: LocalWords(), settings: ChoiceSettings(value: .init(enabled: true, consent: .granted, online: true)), credentialStore: ChoiceKeys(value: keys), cloud: cloud)
    let result = try await service.recognise(Data([1]), intent: .selection)
    #expect(result.text == "local words")
    #expect(result.engine == .onDevice)
    #expect(result.fallbackReason == nil)
    #expect(await cloud.count == 0)
}

@Test(.timeLimit(.minutes(2)))
func issue689EngineChoiceTable() async throws {
    let cases: [(Bool, CloudRecognitionConsent, Bool, CloudCredentials?, Bool)] = [
        (true, .granted, true, keys, true),
        (false, .granted, true, keys, false),
        (true, .notAsked, true, keys, false),
        (true, .declined, true, keys, false),
        (true, .granted, false, keys, false),
        (true, .granted, true, nil, false)
    ]
    for (enabled, consent, online, credentials, expectedCloud) in cases {
        let cloud = CloudCalls()
        let service = TextRecognitionService(onDevice: LocalWords(), settings: ChoiceSettings(value: .init(enabled: enabled, consent: consent, online: online)), credentialStore: ChoiceKeys(value: credentials), cloud: cloud)
        let result = try await service.recognise(Data([1]), intent: .explicit)
        #expect(result.engine == (expectedCloud ? .cloud : .onDevice))
        #expect(result.text == (expectedCloud ? "cloud words" : "local words"))
        #expect(result.fallbackReason == nil)
        #expect(await cloud.count == (expectedCloud ? 1 : 0))
    }
}

@Test(.timeLimit(.minutes(2)), arguments: [TextRecognitionError.cloudAuth, .cloudQuota, .cloudOffline, .cloudFailure, .cloudImageTooLarge])
func issue689CloudFailureFallsBack(error: TextRecognitionError) async throws {
    let cloud = CloudCalls(.failure(error))
    let service = TextRecognitionService(onDevice: LocalWords(), settings: ChoiceSettings(value: .init(enabled: true, consent: .granted, online: true)), credentialStore: ChoiceKeys(value: keys), cloud: cloud)
    let result = try await service.recognise(Data([1]), intent: .explicit)
    let expected: CloudFallbackReason = switch error {
    case .cloudAuth: .auth
    case .cloudQuota: .quota
    case .cloudOffline: .offline
    default: .failure
    }
    #expect(result.engine == .onDevice)
    #expect(result.text == "local words")
    #expect(result.fallbackReason == expected)
}

@Test(.timeLimit(.minutes(2)))
func issue689EmptyCredentialsAndMissingProviderStayLocal() async throws {
    let settings = ChoiceSettings(value: .init(enabled: true, consent: .granted, online: true))
    for missing in [CloudCredentials(apiKey: "", secretKey: "secret"), CloudCredentials(apiKey: "api", secretKey: "")] {
        let cloud = CloudCalls()
        let service = TextRecognitionService(onDevice: LocalWords(), settings: settings, credentialStore: ChoiceKeys(value: missing), cloud: cloud)
        #expect(try await service.recognise(Data([1]), intent: .explicit).engine == .onDevice)
        #expect(await cloud.count == 0)
    }
    let service = TextRecognitionService(onDevice: LocalWords(), settings: settings, credentialStore: ChoiceKeys(value: keys))
    #expect(try await service.recognise(Data([1]), intent: .explicit).engine == .onDevice)
}

@Test(.timeLimit(.minutes(2)))
func issue689CloudCancellationIsNotFallback() async {
    let cloud = CloudCalls(.failure(.cancelled))
    let service = TextRecognitionService(onDevice: LocalWords(), settings: ChoiceSettings(value: .init(enabled: true, consent: .granted, online: true)), credentialStore: ChoiceKeys(value: keys), cloud: cloud)
    do { _ = try await service.recognise(Data([1]), intent: .explicit); Issue.record("Expected cancellation") }
    catch { #expect(error == .cancelled) }
}
