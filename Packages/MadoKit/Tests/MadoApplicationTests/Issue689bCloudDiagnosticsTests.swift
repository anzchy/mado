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

@Test(.timeLimit(.minutes(2)))
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

// MARK: - #689b dev2: an outcome is reported only after the engine that delivered has delivered

// The run happens inside its own Task, so a fake that cancels "the current task" cancels the run, never the test.

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ event: String) { lock.lock(); items.append(event); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}
private func cancelCurrentTask() { withUnsafeCurrentTask { $0?.cancel() } }

private struct CancellingSettings: CloudRecognitionSettings {
    let value: CloudRecognitionOptions
    func options() async -> CloudRecognitionOptions { cancelCurrentTask(); return value }
}
private struct CountingCloud: CloudTextRecognitionProviding {
    let outcome: Result<String, TextRecognitionError>
    var cancels = false
    let calls: Counter
    func recognise(_ image: Data, credentials: CloudCredentials) async throws(TextRecognitionError) -> String {
        calls.add()
        if cancels { cancelCurrentTask() }
        return try outcome.get()
    }
}
private enum LocalScript: Sendable {
    case deliver, fail(TextRecognitionError), cancelThenReturn, cancelThenThrow(TextRecognitionError)
}
private struct ScriptedLocal: OnDeviceTextRecognitionProviding {
    let script: LocalScript
    let calls: Counter
    func recognise(_ image: Data) async throws(TextRecognitionError) -> String {
        calls.add()
        switch script {
        case .deliver: return "local"
        case .fail(let error): throw error
        case .cancelThenReturn: cancelCurrentTask(); return "local"
        case .cancelThenThrow(let error): cancelCurrentTask(); throw error
        }
    }
}
/// Holds the on-device engine until the test opens it (or the run is cancelled, which opens it with "late").
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var released: String?
    private var holder: CheckedContinuation<String, Never>?
    func enter() {
        lock.lock(); entered = true; let waiter = enteredWaiter; enteredWaiter = nil; lock.unlock()
        waiter?.resume()
    }
    func waitEntered() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if entered { lock.unlock(); continuation.resume() } else { enteredWaiter = continuation; lock.unlock() }
        }
    }
    func hold() async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            lock.lock()
            if let released { lock.unlock(); continuation.resume(returning: released) } else { holder = continuation; lock.unlock() }
        }
    }
    func open(_ value: String) {
        lock.lock()
        guard released == nil else { lock.unlock(); return }
        released = value; let waiting = holder; holder = nil
        lock.unlock()
        waiting?.resume(returning: value)
    }
}
private struct HeldLocal: OnDeviceTextRecognitionProviding {
    let gate: Gate
    let events: Events
    func recognise(_ image: Data) async throws(TextRecognitionError) -> String {
        let text = await withTaskCancellationHandler {
            gate.enter()
            return await gate.hold()
        } onCancel: { gate.open("late") }
        events.add("onDeviceReturned")
        return text
    }
}

private let cloudOn = CloudRecognitionOptions(enabled: true, consent: .granted, online: true)
private let switchOff = CloudRecognitionOptions(enabled: false, consent: .granted, online: true)

private func d2Service(settings: any CloudRecognitionSettings, keys: CloudCredentials? = pair,
                       cloud: any CloudTextRecognitionProviding, local: any OnDeviceTextRecognitionProviding,
                       reports: Reports, events: Events? = nil) -> TextRecognitionService {
    TextRecognitionService(onDevice: local, settings: settings, credentialStore: Keys(value: keys), cloud: cloud,
                           report: { reports.add($0); events?.add("reported") })
}
private func start(_ service: TextRecognitionService) -> Task<Result<TextRecognitionResult, TextRecognitionError>, Never> {
    Task {
        do throws(TextRecognitionError) {
            return .success(try await service.recognise(Data([1]), intent: .explicit))
        } catch {
            return .failure(error)
        }
    }
}
private func explicitRun(_ service: TextRecognitionService) async -> Result<TextRecognitionResult, TextRecognitionError> {
    await start(service).value
}
private func error(of result: Result<TextRecognitionResult, TextRecognitionError>) -> TextRecognitionError? {
    if case .failure(let error) = result { return error }
    return nil
}

@Test(.timeLimit(.minutes(2)))
func issue689bD2CancelledDuringOptionsReportsNothing() async {
    // Engine calls stay as before: the skip path still runs the on-device engine, the cloud path still calls Baidu
    // and does not fall back once the run is cancelled.
    for (options, cloudOutcome, localCalls, cloudCalls) in [
        (switchOff, Result<String, TextRecognitionError>.success("c"), 1, 0),
        (cloudOn, .success("c"), 0, 1),
        (cloudOn, .failure(.cloudQuota), 0, 1)
    ] {
        let reports = Reports(), local = Counter(), cloud = Counter()
        let result = await explicitRun(d2Service(settings: CancellingSettings(value: options),
                                                 cloud: CountingCloud(outcome: cloudOutcome, calls: cloud),
                                                 local: ScriptedLocal(script: .deliver, calls: local), reports: reports))
        #expect(error(of: result) == .cancelled)
        #expect(reports.all.isEmpty, "\(options.enabled) \(cloudOutcome)")
        #expect(local.value == localCalls)
        #expect(cloud.value == cloudCalls)
    }
}

@Test(.timeLimit(.minutes(2)))
func issue689bD2CancelledDuringCloudCallReportsNothing() async {
    for cloudOutcome in [Result<String, TextRecognitionError>.success("c"), .failure(.cloudFailure)] {
        let reports = Reports(), local = Counter()
        let result = await explicitRun(d2Service(settings: Settings(value: cloudOn),
                                                 cloud: CountingCloud(outcome: cloudOutcome, cancels: true, calls: Counter()),
                                                 local: ScriptedLocal(script: .deliver, calls: local), reports: reports))
        #expect(error(of: result) == .cancelled)
        #expect(reports.all.isEmpty)
        #expect(local.value == 0)
    }
}

@Test(.timeLimit(.minutes(2)))
func issue689bD2CancelledDuringOnDeviceCallReportsNothing() async {
    let localError = TextRecognitionError.recognitionFailed(domain: "L", code: 9)
    for (options, cloudOutcome) in [(switchOff, Result<String, TextRecognitionError>.success("c")),
                                    (cloudOn, .failure(.cloudAuth))] {
        for (script, expected) in [(LocalScript.cancelThenReturn, TextRecognitionError.cancelled),
                                   (.cancelThenThrow(localError), localError)] {
            let reports = Reports()
            let result = await explicitRun(d2Service(settings: Settings(value: options),
                                                     cloud: CountingCloud(outcome: cloudOutcome, calls: Counter()),
                                                     local: ScriptedLocal(script: script, calls: Counter()), reports: reports))
            #expect(error(of: result) == expected)
            #expect(reports.all.isEmpty, "\(options.enabled) \(script)")
        }
    }
}

@Test(.timeLimit(.minutes(2)))
func issue689bD2OnDeviceFailureAfterSkipOrFallbackReportsNothing() async {
    for (keys, cloudOutcome) in [(nil as CloudCredentials?, Result<String, TextRecognitionError>.success("c")),
                                 (pair, .failure(.cloudQuota))] {
        for localError in [TextRecognitionError.recognitionFailed(domain: "V", code: 3), .invalidImage] {
            let reports = Reports()
            let result = await explicitRun(d2Service(settings: Settings(value: cloudOn), keys: keys,
                                                     cloud: CountingCloud(outcome: cloudOutcome, calls: Counter()),
                                                     local: ScriptedLocal(script: .fail(localError), calls: Counter()),
                                                     reports: reports))
            #expect(error(of: result) == localError)
            #expect(reports.all.isEmpty, "\(keys == nil) \(localError)")
        }
    }
}

@Test(.timeLimit(.minutes(2)))
func issue689bD2HeldOnDeviceRunReportsOnlyAfterDelivery() async throws {
    for (options, cloudOutcome, expected) in [
        (CloudRecognitionOptions(enabled: true, consent: .granted, online: false),
         Result<String, TextRecognitionError>.success("c"), CloudRecognitionOutcome.skipped(.offline)),
        (cloudOn, .failure(.cloudFailure), .fallback(.failure, .cloudFailure))
    ] {
        let reports = Reports(), events = Events(), gate = Gate()
        let run = start(d2Service(settings: Settings(value: options),
                                  cloud: CountingCloud(outcome: cloudOutcome, calls: Counter()),
                                  local: HeldLocal(gate: gate, events: events), reports: reports, events: events))
        await gate.waitEntered()
        #expect(reports.all.isEmpty, "reported while the on-device engine is still working: \(expected)")
        #expect(events.all.isEmpty)
        gate.open("held")
        let result = try await run.value.get()
        #expect(result.engine == .onDevice)
        #expect(result.text == "held")
        #expect(reports.all == [expected])
        #expect(events.all == ["onDeviceReturned", "reported"])
    }
}

@Test(.timeLimit(.minutes(2)))
func issue689bD2HeldOnDeviceCancelledReportsNothing() async {
    for (options, cloudOutcome) in [(switchOff, Result<String, TextRecognitionError>.success("c")),
                                    (cloudOn, .failure(.cloudQuota))] {
        let reports = Reports(), events = Events(), gate = Gate()
        let run = start(d2Service(settings: Settings(value: options),
                                  cloud: CountingCloud(outcome: cloudOutcome, calls: Counter()),
                                  local: HeldLocal(gate: gate, events: events), reports: reports, events: events))
        await gate.waitEntered()
        run.cancel()
        #expect(error(of: await run.value) == .cancelled)
        #expect(reports.all.isEmpty)
        #expect(events.all == ["onDeviceReturned"])
    }
}

@Test(.timeLimit(.minutes(2)))
func issue689bD2OutcomeMatchesDeliveredEngineInvariant() async {
    // Law: an explicit run reports exactly one outcome iff it delivered a result, and that outcome names the engine
    // (and fallback reason) of the result it delivered; otherwise the error is the one the engines produced.
    let localError = TextRecognitionError.recognitionFailed(domain: "L", code: 1)
    let clouds: [(CloudRecognitionOptions, Result<String, TextRecognitionError>)] = [
        (CloudRecognitionOptions(enabled: true, consent: .notAsked, online: true), .success("c")),
        (cloudOn, .success("c")), (cloudOn, .failure(.cloudQuota)), (cloudOn, .failure(.cloudImageTooLarge))
    ]
    for (options, cloudOutcome) in clouds {
        for script in [LocalScript.deliver, .fail(localError), .cancelThenReturn] {
            let reports = Reports(), local = Counter()
            let result = await explicitRun(d2Service(settings: Settings(value: options),
                                                     cloud: CountingCloud(outcome: cloudOutcome, calls: Counter()),
                                                     local: ScriptedLocal(script: script, calls: local), reports: reports))
            let label = "\(options.consent) \(cloudOutcome) \(script)"
            #expect(reports.all.count <= 1, "\(label)")
            switch result {
            case .success(let delivered):
                #expect(reports.all.count == 1, "\(label)")
                switch reports.all.first {
                case .cloud?: #expect(delivered.engine == .cloud && delivered.fallbackReason == nil, "\(label)")
                case .skipped?: #expect(delivered.engine == .onDevice && delivered.fallbackReason == nil, "\(label)")
                case .fallback(let reason, let cloudError)?:
                    #expect(delivered.engine == .onDevice && delivered.fallbackReason == reason, "\(label)")
                    #expect(cloudOutcome == .failure(cloudError), "\(label)")
                case nil: break
                }
            case .failure(let thrown):
                #expect(reports.all.isEmpty, "\(label)")
                #expect(local.value == 1, "\(label)")
                if case .fail = script { #expect(thrown == localError, "\(label)") } else { #expect(thrown == .cancelled, "\(label)") }
            }
        }
    }
}
