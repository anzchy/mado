import Foundation

/// The network side of Cloud Recognition (ADR-0019): an ephemeral session with no cookies, credential storage or
/// cache, which sends only the two Baidu requests `BaiduTextRecognitionProvider` shapes. Anything else is refused
/// before it reaches the network, so this transport cannot become a general network path.
public final class URLSessionHTTPTransport: HTTPTransport {
    public enum Refusal: Error, Equatable { case notBaiduOCR }

    static let host = "aip.baidubce.com"
    static let paths: Set<String> = ["/oauth/2.0/token", "/rest/2.0/ocr/v1/accurate_basic"]

    private let session: URLSession
    private let timeout: TimeInterval
    var configuration: URLSessionConfiguration { session.configuration }

    public convenience init(timeout: TimeInterval = 20) { self.init(timeout: timeout, protocolClasses: []) }

    init(timeout: TimeInterval, protocolClasses: [AnyClass]) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if !protocolClasses.isEmpty { configuration.protocolClasses = protocolClasses }
        self.timeout = timeout
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        guard let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == Self.host, parts.port == nil,
              parts.user == nil, parts.password == nil, Self.paths.contains(parts.path) else { throw Refusal.notBaiduOCR }
        var outgoing = request
        outgoing.timeoutInterval = timeout
        outgoing.httpShouldHandleCookies = false
        outgoing.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (body, response) = try await session.data(for: outgoing)
        // URLSession answers an https request with an HTTPURLResponse or an error; a custom protocol could not, so
        // a bare URLResponse is still mapped to the provider's failure path rather than trapping.
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return HTTPResponse(statusCode: status, body: body)
    }
}
