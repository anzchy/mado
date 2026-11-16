import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

// #689 WI-8: the viewer's 识别文字 goes through the Cloud Recognition engine choice, so the switch, consent, keys
// and network decide the engine, and the notice names the engine that produced the text.

@MainActor private final class CloudWiringMotion: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

private actor CloudWiringLeases: AccessLeasing {
    func acquire(_ request: AccessRequest) -> AccessLease {
        switch request {
        case .fileGrant(let url), .root(_, let url): AccessLease(url: url, rootID: nil)
        }
    }
    func release(_ lease: AccessLease) {}
}

private actor CloudWiringPipeline: ImagePipeline {
    let image: CGImage
    let item = ItemID.ephemeral(UUID())
    let revision = FileRevision(byteCount: 1, modificationDate: nil)
    init(image: CGImage) { self.image = image }
    func request(for fileURL: URL, maximumPixelSize: Int) -> ImageDecodeRequest {
        ImageDecodeRequest(fileURL: fileURL, maximumPixelSize: maximumPixelSize,
            renderKey: RenderKey(itemID: item, revision: revision, maximumPixelSize: maximumPixelSize))
    }
    func image(for request: ImageDecodeRequest) throws -> DecodedImage {
        DecodedImage(image: image, sourcePixelSize: CGSize(width: image.width, height: image.height),
                     revision: revision, itemID: item)
    }
}

private actor CloudWiringPreferences: CloudRecognitionPreferencePort {
    var enabled: Bool
    var record: CloudRecognitionConsentRecord?
    init(enabled: Bool, consent: Bool?) {
        self.enabled = enabled
        record = consent.map { CloudRecognitionConsentRecord(granted: $0, date: Date(timeIntervalSince1970: 0)) }
    }
    func isEnabled() async -> Bool { enabled }
    func setEnabled(_ enabled: Bool) async { self.enabled = enabled }
    func consentRecord() async -> CloudRecognitionConsentRecord? { record }
    func setConsentRecord(_ record: CloudRecognitionConsentRecord) async { self.record = record }
}

private actor CloudWiringSecrets: CloudSecretStorePort {
    var items: [String: String] = [:]
    func secret(service: String, account: String) async throws(CloudSecretStoreError) -> String? { items[account] }
    func setSecret(_ value: String, service: String, account: String) async throws(CloudSecretStoreError) {
        items[account] = value
    }
    func removeSecret(service: String, account: String) async throws(CloudSecretStoreError) { items[account] = nil }
}

private struct CloudWiringReachability: NetworkReachabilityPort {
    let online: Bool
    func isOnline() async -> Bool { online }
}

private actor CloudWiringCalls {
    var onDevice = 0
    var cloud = 0
    var credentials: CloudCredentials?
    func countOnDevice() { onDevice += 1 }
    func countCloud(_ credentials: CloudCredentials) { cloud += 1; self.credentials = credentials }
}

private struct CloudWiringOnDevice: OnDeviceTextRecognitionProviding {
    let calls: CloudWiringCalls
    func recognise(_ image: Data) async throws(TextRecognitionError) -> String {
        await calls.countOnDevice()
        return "local text"
    }
}

private struct CloudWiringCloud: CloudTextRecognitionProviding {
    let calls: CloudWiringCalls
    let failure: TextRecognitionError?
    func recognise(_ image: Data, credentials: CloudCredentials) async throws(TextRecognitionError) -> String {
        await calls.countCloud(credentials)
        if let failure { throw failure }
        return "cloud text"
    }
}

private struct CloudWiringOutcome {
    let board: String?
    let engine: TextRecognitionEngine?
    let tag: String?
    let onDevice: Int
    let cloud: Int
    let credentials: CloudCredentials?
}

private let savedKeys = CloudCredentials(apiKey: "test-api-key-1234", secretKey: "test-secret-key")

@MainActor private func recogniseInViewer(enabled: Bool = true, consent: Bool? = true, keys: Bool = true,
                                          online: Bool = true,
                                          cloudFailure: TextRecognitionError? = nil) async throws -> CloudWiringOutcome {
    _ = NSApplication.shared
    let unavailable = Task<AccessServices, Error> { throw CancellationError() }
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(),
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: unavailable,
        motionPolicy: MotionPolicy(source: CloudWiringMotion()))
    let window = try #require(controller.window)
    defer { window.close() }
    let context = try #require(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 160,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let pipeline = CloudWiringPipeline(image: try #require(context.makeImage()))
    let url = URL(fileURLWithPath: "/tmp/issue689-cloud-wiring.png")
    controller.session.openImage(url, maximumPixelSize: 40) {
        try await AccessImageSource.open(.fileGrant(url), access: CloudWiringLeases(), pipeline: pipeline)
    }
    for _ in 0..<300 {
        if controller.session.imageLoader.phase == .settled, controller.canvas.backdropFrame.image != nil { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let store = BaiduCloudCredentialStore(secrets: CloudWiringSecrets(), service: "test.issue689.wiring")
    if keys { try await store.save(savedKeys) }
    let calls = CloudWiringCalls()
    let preferences = CloudWiringPreferences(enabled: enabled, consent: consent)
    let adapter = controller.recogniseTextAdapter
    let board = NSPasteboard(name: .init("mado.issue689.wiring.\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    adapter.pasteboard = board
    adapter.scheduleNoticeDismiss = { _, _ in }
    adapter.announce = { _ in }
    adapter.makeRecognitionService = {
        CloudRecognitionConfiguration.service(onDevice: CloudWiringOnDevice(calls: calls), preferences: preferences,
            keys: store, reachability: CloudWiringReachability(online: online),
            cloud: CloudWiringCloud(calls: calls, failure: cloudFailure))
    }
    controller.recogniseText()
    for _ in 0..<500 {
        if adapter.model?.isRunning == false { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    return CloudWiringOutcome(board: board.string(forType: .string), engine: adapter.model?.engine,
                              tag: adapter.focusableNotice?.engineTag.stringValue,
                              onDevice: await calls.onDevice, cloud: await calls.cloud,
                              credentials: await calls.credentials)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue689RecogniseTextUsesBaiduWhenAllowed() async throws {
    let outcome = try await recogniseInViewer()
    #expect(outcome.board == "cloud text")
    #expect(outcome.engine == .cloud)
    #expect(outcome.tag == String(localized: "Baidu Cloud Recognition"))
    #expect(outcome.cloud == 1)
    #expect(outcome.onDevice == 0)
    #expect(outcome.credentials == savedKeys)
}

@MainActor @Test(.timeLimit(.minutes(3)), arguments: [
    (false, true as Bool?, true, true),   // switch off
    (true, false as Bool?, true, true),   // consent declined
    (true, nil as Bool?, true, true),     // never asked
    (true, true as Bool?, false, true),   // no keys
    (true, true as Bool?, true, false),   // offline
]) func issue689RecogniseTextFallsBackWithoutAllowance(enabled: Bool, consent: Bool?, keys: Bool,
                                                      online: Bool) async throws {
    let outcome = try await recogniseInViewer(enabled: enabled, consent: consent, keys: keys, online: online)
    #expect(outcome.board == "local text")
    #expect(outcome.engine == .onDevice)
    #expect(outcome.tag == String(localized: "On-device Recognition"))
    #expect(outcome.cloud == 0)
    #expect(outcome.onDevice == 1)
}

@MainActor @Test(.timeLimit(.minutes(3)), arguments: [
    TextRecognitionError.cloudQuota, .cloudAuth, .cloudOffline, .cloudFailure,
]) func issue689RecogniseTextFallsBackOnBaiduErrors(failure: TextRecognitionError) async throws {
    let outcome = try await recogniseInViewer(cloudFailure: failure)
    #expect(outcome.board == "local text")
    #expect(outcome.engine == .onDevice)
    #expect(outcome.tag == String(localized: "On-device Recognition"))
    #expect(outcome.cloud == 1)
    #expect(outcome.onDevice == 1)
}

@MainActor @Test(.timeLimit(.minutes(1))) func issue689RecogniseTextDefaultUsesTheAppServices() throws {
    _ = NSApplication.shared
    let unavailable = Task<AccessServices, Error> { throw CancellationError() }
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(),
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: unavailable,
        motionPolicy: MotionPolicy(source: CloudWiringMotion()))
    defer { controller.window?.close() }
    #expect(controller.recogniseTextAdapter.recognise == nil)
}
