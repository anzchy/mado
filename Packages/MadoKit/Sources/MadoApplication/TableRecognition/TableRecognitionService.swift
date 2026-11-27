import Foundation

/// Recognise Table: sends one image to the configured vision-model service and returns a table or a classified
/// result (#869, spec #866).
public struct TableRecognitionService: Sendable {
    private let settings: any TableRecognitionSettings
    private let credentials: any TableRecognitionCredentialStore
    private let transport: any HTTPTransport
    private let report: @Sendable (TableRecognitionDiagnostic) -> Void
    /// Test seam: runs once the request is built, in the synchronous stretch before it is sent.
    private let requestBuilt: @Sendable () -> Void

    public init(settings: any TableRecognitionSettings, credentials: any TableRecognitionCredentialStore,
                transport: any HTTPTransport,
                report: @escaping @Sendable (TableRecognitionDiagnostic) -> Void = TableRecognitionDiagnostic.record) {
        self.init(settings: settings, credentials: credentials, transport: transport,
                  requestBuilt: {}, report: report)
    }

    init(settings: any TableRecognitionSettings, credentials: any TableRecognitionCredentialStore,
         transport: any HTTPTransport, requestBuilt: @escaping @Sendable () -> Void) {
        self.init(settings: settings, credentials: credentials, transport: transport,
                  requestBuilt: requestBuilt, report: TableRecognitionDiagnostic.record)
    }

    init(settings: any TableRecognitionSettings, credentials: any TableRecognitionCredentialStore,
         transport: any HTTPTransport, requestBuilt: @escaping @Sendable () -> Void,
         report: @escaping @Sendable (TableRecognitionDiagnostic) -> Void) {
        self.settings = settings
        self.credentials = credentials
        self.transport = transport
        self.requestBuilt = requestBuilt
        self.report = report
    }

    public func recognise(_ image: Data) async -> TableRecognitionResult { await recognise(image, willSend: {}) }

    /// As `recognise(_:)`; `willSend` runs once every check has passed and the request is built, just before the
    /// transport is called (#874 fix1 WI-2). A run refused or cancelled before that never runs it.
    public func recognise(_ image: Data, willSend: @Sendable () async -> Void) async -> TableRecognitionResult {
        switch await prepare(image) {
        case .notSent(let block): return .notSent(block)
        case .cancelled: return .cancelled
        case .ready(let request, let destination):
            let sent = await send(request, to: destination, willSend: willSend)
            if case .cancelled = sent.result { return .cancelled }
            report(TableRecognitionDiagnostic.make(response: sent.response,
                                                   durationMilliseconds: sent.durationMilliseconds,
                                                   errorClass: sent.result.failureClass))
            return sent.result
        }
    }

    /// Sends once, never retries, and only to `destination`, the consented host. A run cancelled before the call,
    /// including while the request was being built, sends nothing; one cancelled while the reply was outstanding is
    /// cancelled, whatever came back.
    private struct Sent {
        let result: TableRecognitionResult
        let response: HTTPResponse?
        let durationMilliseconds: Int
    }

    private func send(_ request: URLRequest, to destination: HTTPDestination,
                      willSend: @Sendable () async -> Void) async -> Sent {
        if Task.isCancelled { return Sent(result: .cancelled, response: nil, durationMilliseconds: 0) }
        await willSend()
        let start = ContinuousClock.now
        let result: TableRecognitionResult
        let response: HTTPResponse?
        do {
            let received = try await transport.send(request, to: destination)
            response = received
            result = TableRecognitionReply.classify(received)
        } catch {
            response = nil
            result = TableRecognitionReply.classify(error)
        }
        let elapsed = start.duration(to: .now).components
        let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1_000_000_000_000_000
        return Sent(result: Task.isCancelled ? .cancelled : result, response: response,
                    durationMilliseconds: Int(min(Double(Int.max), max(0, milliseconds))))
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
        guard let consentedHost = options.consent?.host else { return .notSent(.consentNotAsked) }
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
        // The transport admits only this host and port (#890): the host from the consent record, not one read back
        // from the request, so the transport checks the request against what the user consented to.
        let port = URLComponents(url: target.url, resolvingAgainstBaseURL: false)?.port
        requestBuilt()
        return .ready(request, .consentedHost(host: consentedHost, port: port))
    }

    /// The Settings Test: sends the built-in sample table, not the user's image, under the same switch, consent and
    /// key rules as a real run, and passes only when the sample's cells come back (AC-6). Failures keep their class.
    public func testService() async -> TableRecognitionTestResult {
        switch await prepare(TableRecognitionSample.png) {
        case .notSent(let block): return .notSent(block)
        case .cancelled: return .cancelled
        case .ready(let request, let destination):
            let sent = await send(request, to: destination, willSend: {})
            let answer: TableRecognitionTestResult
            switch sent.result {
            case .table(let rows): answer = TableRecognitionSample.matches(rows) ? .passed : .failed(.other)
            case .notSent(let block): answer = .notSent(block)
            case .failed(let failure): answer = .failed(failure)
            case .cancelled: return .cancelled
            }
            report(TableRecognitionDiagnostic.make(response: sent.response,
                                                   durationMilliseconds: sent.durationMilliseconds,
                                                   errorClass: answer.failureClass))
            return answer
        }
    }
}

private extension TableRecognitionResult {
    var failureClass: TableRecognitionFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }
}

private extension TableRecognitionTestResult {
    var failureClass: TableRecognitionFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }
}
