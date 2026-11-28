import Foundation

/// One HTTP reply: the status and the raw body. Cloud Recognition services (Baidu text, the table service) read it.
public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let body: Data
    public init(statusCode: Int, body: Data) { self.statusCode = statusCode; self.body = body }
}

/// Where one request may go. The caller names it with every request; the transport refuses, before any connection, a
/// request whose URL is not this destination. There is no global or mutable list (#890).
public enum HTTPDestination: Sendable, Equatable {
    /// Baidu's two text-recognition endpoints (ADR-0019), fixed in the transport.
    case baiduOCR
    /// The table-recognition host the user configured and consented to (spec #866). `TableRecognitionService` names it
    /// only after its consent guard passed, from the request it built. https only, no user or password; the host is
    /// compared without case and with one trailing dot dropped (the consent rule); `port` nil means 443.
    case consentedHost(host: String, port: Int?)
}

/// The network port of Cloud Recognition. It lives in the application layer so services here can be tested with a
/// fake; MadoInfrastructure supplies the URLSession implementation.
///
/// Redirects (#890): a transport never follows one. It sends the request once and returns the first answer, so a 3xx
/// comes back as an `HTTPResponse` with that status, whatever its Location or body; nothing is sent to the redirect
/// target. Each service classifies a returned 3xx as a failure. Cancelling the calling task cancels the request.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest, to destination: HTTPDestination) async throws -> HTTPResponse
    /// As `send(_:to:)`; `onStart` runs once the transport has admitted the request and is about to start it.
    func send(_ request: URLRequest, to destination: HTTPDestination,
              onStart: @escaping @Sendable () async -> Void) async throws -> HTTPResponse
}

public extension HTTPTransport {
    func send(_ request: URLRequest, to destination: HTTPDestination,
              onStart: @escaping @Sendable () async -> Void) async throws -> HTTPResponse {
        try await send(request, to: destination)
    }
}
