import Foundation

/// Recognise Table: sends one image to the configured vision-model service and returns a table or a classified
/// result (#869, spec #866).
public struct TableRecognitionService: Sendable {
    private let settings: any TableRecognitionSettings
    private let credentials: any TableRecognitionCredentialStore
    private let transport: any HTTPTransport
    /// Test seam: runs once the request is built, in the synchronous stretch before it is sent.
    private let requestBuilt: @Sendable () -> Void

    public init(settings: any TableRecognitionSettings, credentials: any TableRecognitionCredentialStore,
                transport: any HTTPTransport) {
        self.init(settings: settings, credentials: credentials, transport: transport, requestBuilt: {})
    }

    init(settings: any TableRecognitionSettings, credentials: any TableRecognitionCredentialStore,
         transport: any HTTPTransport, requestBuilt: @escaping @Sendable () -> Void) {
        self.settings = settings
        self.credentials = credentials
        self.transport = transport
        self.requestBuilt = requestBuilt
    }

    public func recognise(_ image: Data) async -> TableRecognitionResult {
        switch await prepare(image) {
        case .notSent(let block): return .notSent(block)
        case .cancelled: return .cancelled
        case .ready(let request, let destination): return await send(request, to: destination)
        }
    }

    /// Sends once, never retries, and only to `destination`, the consented host. A run cancelled before the call,
    /// including while the request was being built, sends nothing; one cancelled while the reply was outstanding is
    /// cancelled, whatever came back.
    private func send(_ request: URLRequest, to destination: HTTPDestination) async -> TableRecognitionResult {
        if Task.isCancelled { return .cancelled }
        let result: TableRecognitionResult
        do {
            result = TableRecognitionReply.classify(try await transport.send(request, to: destination))
        } catch {
            result = TableRecognitionReply.classify(error)
        }
        return Task.isCancelled ? .cancelled : result
    }

    private enum Prepared { case ready(URLRequest, HTTPDestination), notSent(TableRecognitionBlock), cancelled }

    /// Runs the guards in order (switch, address, consent, key, format, size) and builds the request. The key is read
    /// only once the switch, the address and the consent allow a request, and every input is read fresh. A run
    /// cancelled before the request is built sends nothing.
    private func prepare(_ image: Data) async -> Prepared {
        if Task.isCancelled { return .cancelled }
        let options = await settings.options()
        if Task.isCancelled { return .cancelled }
        guard options.cloudEnabled else { return .notSent(.cloudOff) }
        guard let endpoint = options.endpoint, let target = TableRecognitionGuards.validURL(for: endpoint) else {
            return .notSent(.invalidEndpoint)
        }
        if let block = TableRecognitionGuards.consentBlock(options.consent, host: target.host) { return .notSent(block) }
        let key = (await credentials.accessKey(for: endpoint) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if Task.isCancelled { return .cancelled }
        guard !key.isEmpty else { return .notSent(.noAccessKey) }
        let mediaType: String
        switch TableRecognitionGuards.image(image) {
        case .failure(let block): return .notSent(block)
        case .success(let type): mediaType = type
        }
        let request = TableRecognitionRequest.make(url: target.url, endpoint: endpoint, key: key, image: image,
                                                   mediaType: mediaType)
        // The transport admits only this host and port (#890): the consented host, named after the consent guard.
        let port = URLComponents(url: target.url, resolvingAgainstBaseURL: false)?.port
        requestBuilt()
        return .ready(request, .consentedHost(host: target.host, port: port))
    }

    /// The Settings Test: sends the built-in sample table, not the user's image, under the same switch, consent and
    /// key rules as a real run, and passes only when the sample's cells come back (AC-6). Failures keep their class.
    public func testService() async -> TableRecognitionTestResult {
        switch await prepare(TableRecognitionSample.png) {
        case .notSent(let block): return .notSent(block)
        case .cancelled: return .cancelled
        case .ready(let request, let destination):
            switch await send(request, to: destination) {
            case .table(let rows): return TableRecognitionSample.matches(rows) ? .passed : .failed(.other)
            case .notSent(let block): return .notSent(block)
            case .failed(let failure): return .failed(failure)
            case .cancelled: return .cancelled
            }
        }
    }
}
