import Foundation
import Testing
@testable import MadoApplication

// #689b dev1 (device run smoke689b-20261116 step 8): an explicit Recognise Text with everything allowed fell back to
// On-device Recognition and nothing said why. The service now reports what it did, once per explicit run, so the
// App can log it; these tests pin the mapping, not the Logger call.

private struct Settings: CloudRecognitionSettings {
    let value: CloudRecognitionOptions
    func options() async -> CloudRecognitionOptions { value }
}
private struct Keys: CloudCredentialStore {
    let value: CloudCredentials?
    func credentials() async -> CloudCredentials? { value }
}
private struct Cloud: CloudTextRecognitionProviding {
    let outcome: Result<String, TextRecognitionError>
    func recognise(_ image: Data, credentials: CloudCredentials) async throws(TextRecognitionError) -> String {
        try outcome.get()
    }
}
private struct Local: OnDeviceTextRecognitionProviding {
    func recognise(_ image: Data) async throws(TextRecognitionError) -> String { "local" }
}
private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [CloudRecognitionOutcome] = []
    func add(_ outcome: CloudRecognitionOutcome) { lock.lock(); items.append(outcome); lock.unlock() }
    var all: [CloudRecognitionOutcome] { lock.lock(); defer { lock.unlock() }; return items }
}
private let pair = CloudCredentials(apiKey: "AK-real-looking-0001", secretKey: "SK-real-looking-0002")

private func service(enabled: Bool = true, consent: CloudRecognitionConsent = .granted, online: Bool = true,
                     keys: CloudCredentials? = pair, cloud: Result<String, TextRecognitionError> = .success("cloud"),
                     reports: Reports) -> TextRecognitionService {
    TextRecognitionService(onDevice: Local(), settings: Settings(value: .init(enabled: enabled, consent: consent, online: online)),
                           credentialStore: Keys(value: keys), cloud: Cloud(outcome: cloud), report: { reports.add($0) })
}

@Test(.timeLimit(.minutes(2)))
func issue689bExplicitRunReportsEachSkipReasonInOrder() async throws {
    // The first unmet condition names the skip: switch, then consent, then network, then keys.
    for (make, reason) in [
        ({ service(enabled: false, consent: .notAsked, online: false, keys: nil, reports: $0) } as (Reports) -> TextRecognitionService, CloudSkipReason.disabled),
        ({ service(consent: .notAsked, online: false, keys: nil, reports: $0) }, .consentNotGiven),
        ({ service(consent: .declined, reports: $0) }, .consentNotGiven),
        ({ service(online: false, keys: nil, reports: $0) }, .offline),
        ({ service(keys: nil, reports: $0) }, .noKeys),
        ({ service(keys: CloudCredentials(apiKey: "", secretKey: "s"), reports: $0) }, .noKeys),
        ({ service(keys: CloudCredentials(apiKey: "a", secretKey: ""), reports: $0) }, .noKeys)
    ] {
        let reports = Reports()
        let result = try await make(reports).recognise(Data([1]), intent: .explicit)
        #expect(result.engine == .onDevice)
        #expect(reports.all == [.skipped(reason)], "\(reason)")
    }
}

@Test(.timeLimit(.minutes(2)))
func issue689bCloudSuccessReportsCloudOnce() async throws {
    let reports = Reports()
    let result = try await service(reports: reports).recognise(Data([1]), intent: .explicit)
    #expect(result.engine == .cloud)
    #expect(reports.all == [.cloud])
}

@Test(.timeLimit(.minutes(2)), arguments: [
    (TextRecognitionError.cloudAuth, CloudFallbackReason.auth), (.cloudQuota, .quota), (.cloudOffline, .offline),
    (.cloudFailure, .failure), (.cloudImageTooLarge, .failure), (.invalidImage, .failure)
])
func issue689bCloudFailureReportsReasonAndError(error: TextRecognitionError, reason: CloudFallbackReason) async throws {
    let reports = Reports()
    let result = try await service(cloud: .failure(error), reports: reports).recognise(Data([1]), intent: .explicit)
    #expect(result.engine == .onDevice)
    #expect(result.fallbackReason == reason)
    #expect(reports.all == [.fallback(reason, error)])
}

@Test(.timeLimit(.minutes(2)))
func issue689bSelectionAndCancelledRunsReportNothing() async throws {
    let reports = Reports()
    _ = try await service(reports: reports).recognise(Data([1]), intent: .selection)
    let cancelled = service(cloud: .failure(.cancelled), reports: reports)
    await #expect(throws: TextRecognitionError.cancelled) { try await cancelled.recognise(Data([1]), intent: .explicit) }
    #expect(reports.all.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func issue689bOutcomeLogMessagesNameEngineAndReason() {
    #expect(CloudRecognitionOutcome.cloud.logMessage == "engine=cloud")
    #expect(CloudRecognitionOutcome.skipped(.disabled).logMessage == "engine=onDevice skipped=disabled")
    #expect(CloudRecognitionOutcome.skipped(.consentNotGiven).logMessage == "engine=onDevice skipped=consentNotGiven")
    #expect(CloudRecognitionOutcome.skipped(.offline).logMessage == "engine=onDevice skipped=offline")
    #expect(CloudRecognitionOutcome.skipped(.noKeys).logMessage == "engine=onDevice skipped=noKeys")
    #expect(CloudRecognitionOutcome.fallback(.auth, .cloudAuth).logMessage == "engine=onDevice fallback=auth error=cloudAuth")
    #expect(CloudRecognitionOutcome.fallback(.quota, .cloudQuota).logMessage == "engine=onDevice fallback=quota error=cloudQuota")
    #expect(CloudRecognitionOutcome.fallback(.offline, .cloudOffline).logMessage == "engine=onDevice fallback=offline error=cloudOffline")
    #expect(CloudRecognitionOutcome.fallback(.failure, .cloudImageTooLarge).logMessage
            == "engine=onDevice fallback=failure error=cloudImageTooLarge")
    #expect(CloudRecognitionOutcome.fallback(.failure, .invalidImage).logMessage == "engine=onDevice fallback=failure error=invalidImage")
    #expect(CloudRecognitionOutcome.fallback(.failure, .cloudFailure).logMessage == "engine=onDevice fallback=failure error=cloudFailure")
    #expect(CloudRecognitionOutcome.fallback(.failure, .recognitionFailed(domain: "D", code: 7)).logMessage
            == "engine=onDevice fallback=failure error=recognitionFailed(D 7)")
}
