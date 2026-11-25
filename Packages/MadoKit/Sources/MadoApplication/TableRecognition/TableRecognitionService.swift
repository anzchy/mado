import Foundation

/// Recognise Table: sends one image to the configured vision-model service and returns a table or a classified
/// result (#869, spec #866).
public struct TableRecognitionService: Sendable {
    private let settings: any TableRecognitionSettings
    private let credentials: any TableRecognitionCredentialStore
    private let transport: any HTTPTransport

    public init(settings: any TableRecognitionSettings, credentials: any TableRecognitionCredentialStore,
                transport: any HTTPTransport) {
        self.settings = settings
        self.credentials = credentials
        self.transport = transport
    }

    public func recognise(_ image: Data) async -> TableRecognitionResult {
        switch await prepare(image) {
        case .notSent(let block): return .notSent(block)
        case .cancelled: return .cancelled
        case .ready(let request): return await send(request)
        }
    }

    /// Sends once, never retries. A run cancelled while the reply was outstanding is cancelled, whatever came back.
    private func send(_ request: URLRequest) async -> TableRecognitionResult {
        let result: TableRecognitionResult
        do {
            result = TableRecognitionReply.classify(try await transport.send(request))
        } catch {
            result = TableRecognitionReply.classify(error)
        }
        return Task.isCancelled ? .cancelled : result
    }

    private enum Prepared { case ready(URLRequest), notSent(TableRecognitionBlock), cancelled }

    /// Runs the guards in order (switch, address, consent, key, format, size) and builds the request. The key is read
    /// only once the switch, the address and the consent allow a request, and every input is read fresh. A run
    /// cancelled before the request is built sends nothing.
    private func prepare(_ image: Data) async -> Prepared {
        if Task.isCancelled { return .cancelled }
        let options = await settings.options()
        if Task.isCancelled { return .cancelled }
        guard options.cloudEnabled else { return .notSent(.cloudOff) }
        guard let endpoint = options.endpoint, let url = TableRecognitionGuards.validURL(for: endpoint) else {
            return .notSent(.invalidEndpoint)
        }
        if let block = TableRecognitionGuards.consentBlock(options.consent, url: url) { return .notSent(block) }
        let key = (await credentials.accessKey(for: endpoint) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if Task.isCancelled { return .cancelled }
        guard !key.isEmpty else { return .notSent(.noAccessKey) }
        let mediaType: String
        switch TableRecognitionGuards.image(image) {
        case .failure(let block): return .notSent(block)
        case .success(let type): mediaType = type
        }
        return .ready(TableRecognitionRequest.make(url: url, endpoint: endpoint, key: key, image: image,
                                                   mediaType: mediaType))
    }

    /// The Settings Test: sends the built-in sample table, not the user's image, under the same switch, consent and
    /// key rules as a real run, and passes only when the sample's cells come back (AC-6). Failures keep their class.
    public func testService() async -> TableRecognitionTestResult {
        switch await prepare(TableRecognitionSample.png) {
        case .notSent(let block): return .notSent(block)
        case .cancelled: return .cancelled
        case .ready(let request):
            switch await send(request) {
            case .table(let rows): return TableRecognitionSample.matches(rows) ? .passed : .failed(.other)
            case .notSent(let block): return .notSent(block)
            case .failed(let failure): return .failed(failure)
            case .cancelled: return .cancelled
            }
        }
    }
}
