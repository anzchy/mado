import Foundation

/// One HTTP reply: the status and the raw body. Cloud Recognition services (Baidu text, the table service) read it.
public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let body: Data
    public init(statusCode: Int, body: Data) { self.statusCode = statusCode; self.body = body }
}

/// The network port of Cloud Recognition. It lives in the application layer so services here can be tested with a
/// fake; MadoInfrastructure supplies the URLSession implementation.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}
