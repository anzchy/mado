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
    /// As `send(_:to:)`, and `onStart` runs from inside the transport once it has admitted the request (the
    /// destination check) and found the call not cancelled, just before it starts the request (#874 fix2 WI-1). A
    /// refused or cancelled call never runs it, and a call cancelled while it runs starts nothing. Only from then is
    /// it true that the request went to the service.
    func send(_ request: URLRequest, to destination: HTTPDestination,
              onStart: @escaping @Sendable () async -> Void) async throws -> HTTPResponse
    /// As `send(_:to:onStart:)`, and `onLoad` runs from inside the transport after its last cancellation check, as
    /// it starts the load (#874 fix3 WI-1).
    func send(_ request: URLRequest, to destination: HTTPDestination,
              onStart: @escaping @Sendable () async -> Void,
              onLoad: @escaping @Sendable () -> Void) async throws -> HTTPResponse
}

public extension HTTPTransport {
    /// For a transport that refuses nothing before it starts a request (the test fakes): the cancellation checks
    /// around `onStart`, then `send(_:to:)`. A transport that checks its requests implements this itself.
    func send(_ request: URLRequest, to destination: HTTPDestination,
              onStart: @escaping @Sendable () async -> Void) async throws -> HTTPResponse {
        try Task.checkCancellation()
        await onStart()
        try Task.checkCancellation()
        return try await send(request, to: destination)
    }

    /// Stub (#874 fix3): ignores `onLoad`.
    func send(_ request: URLRequest, to destination: HTTPDestination,
              onStart: @escaping @Sendable () async -> Void,
              onLoad: @escaping @Sendable () -> Void) async throws -> HTTPResponse {
        try await send(request, to: destination, onStart: onStart)
    }
}
