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
        let options = await settings.options()
        guard let endpoint = options.endpoint, let base = URL(string: endpoint.baseURL),
              let url = TableRecognitionRequest.url(base: base) else { return .notSent(.invalidEndpoint) }
        let key = (await credentials.accessKey(for: endpoint) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let mediaType = TableImageFormat.mediaType(of: image) else { return .notSent(.unsupportedImage) }
        let request = TableRecognitionRequest.make(url: url, endpoint: endpoint, key: key, image: image,
                                                   mediaType: mediaType)
        _ = try? await transport.send(request)
        return .failed(.other)
    }

    public func testService() async -> TableRecognitionTestResult {
        .failed(.other)
    }
}
