import Foundation
import MadoApplication

/// The network side of Cloud Recognition (ADR-0019, #890): an ephemeral session with no cookies, credential storage or
/// cache. Each request names its destination: Baidu's two OCR endpoints, or the one table-recognition host the user
/// configured and consented to, passed in by the caller with that request. A request to anything else is refused
/// before a connection. A redirect is never followed: the 3xx is returned as the answer (see `HTTPTransport`), so it
/// cannot carry the keys or the image to another host. This transport cannot become a general network path.
public final class URLSessionHTTPTransport: HTTPTransport {
    /// Why a request was refused before a connection. No case carries the request, its host, key or body.
    public enum Refusal: Error, Equatable { case notBaiduOCR, notAllowedHost }

    static let host = "aip.baidubce.com"
    /// The provider's two endpoints (defined once there).
    static let paths = Set([BaiduTextRecognitionProvider.tokenEndpoint, BaiduTextRecognitionProvider.recognitionEndpoint]
        .map { URL(string: $0)!.path })

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
        session = URLSession(configuration: configuration, delegate: RedirectRefusal(), delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    public func send(_ request: URLRequest, to destination: HTTPDestination) async throws -> HTTPResponse {
        try await send(request, to: destination, onStart: {})
    }

    /// Stub (#874 fix3): ignores `onLoad`.
    public func send(_ request: URLRequest, to destination: HTTPDestination,
                     onStart: @escaping @Sendable () async -> Void,
                     onLoad: @escaping @Sendable () -> Void) async throws -> HTTPResponse {
        try await send(request, to: destination, onStart: onStart)
    }

    /// Reports the start (`onStart`) only after the destination check and the cancellation check, and checks for
    /// cancellation again before the load, so nothing is said to be sent that was refused or cancelled (#874 fix2).
    public func send(_ request: URLRequest, to destination: HTTPDestination,
                     onStart: @escaping @Sendable () async -> Void) async throws -> HTTPResponse {
        let parts = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        switch destination {
        case .baiduOCR:
            guard let parts, parts.scheme == "https", parts.host == Self.host, parts.port == nil, parts.user == nil,
                  parts.password == nil, Self.paths.contains(parts.path) else { throw Refusal.notBaiduOCR }
        case .consentedHost(let host, let port):
            guard let parts, Self.admits(parts, host: host, port: port) else { throw Refusal.notAllowedHost }
        }
        // URLSession starts a load even for a task that is already cancelled (#890: 199 of 200 calls did); a
        // cancelled call sends nothing.
        try Task.checkCancellation()
        await onStart()
        // A call cancelled while it reported the start sends nothing either.
        try Task.checkCancellation()
        var outgoing = request
        outgoing.timeoutInterval = timeout
        outgoing.httpShouldHandleCookies = false
        outgoing.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (body, response) = try await session.data(for: outgoing)
        // The delegate refused to follow, so a 3xx arrives here as the final answer and is returned as it is; each
        // service classifies it as a failure (the HTTPTransport contract).
        // URLSession answers an https request with an HTTPURLResponse or an error; a custom protocol could not, so
        // a bare URLResponse is still mapped to the services' failure path rather than trapping.
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return HTTPResponse(statusCode: status, body: body)
    }

    /// The consented host: https, no user or password, the same host after lowercasing and dropping one trailing dot
    /// (the consent rule; an international name compares in the one spelling URLComponents decodes it to), and the
    /// same port, where none means 443.
    static func admits(_ parts: URLComponents, host: String, port: Int?) -> Bool {
        guard parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil,
              let requestHost = parts.host else { return false }
        let allowed = normalised(host)
        return !allowed.isEmpty && normalised(requestHost) == allowed && (parts.port ?? 443) == (port ?? 443)
    }

    private static func normalised(_ host: String) -> String {
        var host = host.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        return host
    }
}

/// Completes every redirect with nil: the 3xx response becomes the task's answer and no second request is sent.
private final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}
