import Foundation
import Testing
@testable import MadoInfrastructure

// An extension of the serialized #689 suite, so it never runs beside the other users of StubURLProtocol's shared state.
extension Issue689URLSessionTransportTests {
    /// #787 i787-fix1 (audit F1/M1): a hanging load can be ended by `failHung` as soon as its request is visible through
    /// `requests`. The hook calls `failHung` at that earliest moment, with no sleeps. If the load is not registered yet,
    /// nothing ends it and the 2-second transport timeout answers `.timedOut` instead of the injected error.
    @Test(.timeLimit(.minutes(2)))
    func issue787FailHungReachesALoadAsSoonAsItsRequestIsVisible() async throws {
        StubURLProtocol.reset([.hang], afterRecord: { StubURLProtocol.failHung(URLError(.cannotFindHost)) })
        defer { StubURLProtocol.reset([]) }
        let transport = URLSessionHTTPTransport(timeout: 2, protocolClasses: [StubURLProtocol.self])
        var request = URLRequest(url: URL(string: "https://aip.baidubce.com/oauth/2.0/token")!)
        request.httpMethod = "POST"
        let error = await #expect(throws: URLError.self) { try await transport.send(request, to: .baiduOCR) }
        #expect(error?.code == .cannotFindHost, "failHung found no registered load; the transport timed out instead")
        #expect(StubURLProtocol.requests.count == 1)
    }
}
