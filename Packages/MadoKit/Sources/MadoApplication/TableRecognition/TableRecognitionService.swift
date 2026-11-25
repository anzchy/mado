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
        case .failure(let block): return .notSent(block)
        case .success(let request):
            _ = try? await transport.send(request)
            return .failed(.other)
        }
    }

    /// Runs the guards in order (switch, address, consent, key, format, size) and builds the request. The key is read
    /// only once the switch, the address and the consent allow a request, and every input is read fresh.
    private func prepare(_ image: Data) async -> Result<URLRequest, TableRecognitionBlock> {
        let options = await settings.options()
        guard options.cloudEnabled else { return .failure(.cloudOff) }
        guard let endpoint = options.endpoint, let url = TableRecognitionGuards.validURL(for: endpoint) else {
            return .failure(.invalidEndpoint)
        }
        if let block = TableRecognitionGuards.consentBlock(options.consent, url: url) { return .failure(block) }
        let key = (await credentials.accessKey(for: endpoint) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .failure(.noAccessKey) }
        let mediaType: String
        switch TableRecognitionGuards.image(image) {
        case .failure(let block): return .failure(block)
        case .success(let type): mediaType = type
        }
        return .success(TableRecognitionRequest.make(url: url, endpoint: endpoint, key: key, image: image,
                                                     mediaType: mediaType))
    }

    public func testService() async -> TableRecognitionTestResult {
        .failed(.other)
    }
}
