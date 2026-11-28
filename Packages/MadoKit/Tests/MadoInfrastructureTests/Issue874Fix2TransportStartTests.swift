import Foundation
import Testing
import MadoApplication
@testable import MadoInfrastructure

// #874 fix round 2 WI-1 (audit i874-confirm1 gpt F1, opus L2): the URLSession transport reports the start of a request
// only after it admitted the destination and checked for cancellation, and starts no load when the call was cancelled
// before or while it reported the start.

private actor Starts874G {
    /// The loads the stub had seen each time the start was reported.
    private(set) var loadsSeen: [Int] = []
    func mark(_ loads: Int) { loadsSeen.append(loads) }
}

private let tableRequest874G = URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!)
private let deepSeek874G = HTTPDestination.consentedHost(host: "api.deepseek.com", port: nil)

extension Issue890TransportTests {
    @Test(.timeLimit(.minutes(2)))
    func issue874Fix2TheTransportReportsTheStartOnceAfterAdmittingAndBeforeTheLoad() async throws {
        let starts = Starts874G()
        Stub890.reset([.respond(200, Data("{}".utf8))])
        await #expect(throws: URLSessionHTTPTransport.Refusal.notAllowedHost) {
            try await transport890().send(tableRequest874G, to: .consentedHost(host: "other.example.com", port: nil),
                                          onStart: { await starts.mark(Stub890.requests.count) })
        }
        #expect(await starts.loadsSeen.isEmpty, "a refused destination reports no start")
        let response = try await transport890().send(tableRequest874G, to: deepSeek874G,
                                                     onStart: { await starts.mark(Stub890.requests.count) })
        #expect(response.statusCode == 200)
        #expect(await starts.loadsSeen == [0], "reported once, before the load began")
        #expect(Stub890.requests.count == 1)
    }

    @Test(.timeLimit(.minutes(2)))
    func issue874Fix2ACallCancelledBeforeOrWhileReportingTheStartLoadsNothing() async throws {
        let starts = Starts874G()
        Stub890.reset([.respond(200, Data("{}".utf8)), .respond(200, Data("{}".utf8))])
        let transport = transport890()
        let before = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await transport.send(tableRequest874G, to: deepSeek874G, onStart: { await starts.mark(-1) })
        }
        await #expect(throws: CancellationError.self) { try await before.value }
        #expect(await starts.loadsSeen.isEmpty, "a call cancelled before it was admitted reports no start")
        let during = Task {
            try await transport.send(tableRequest874G, to: deepSeek874G, onStart: {
                await starts.mark(Stub890.requests.count)
                withUnsafeCurrentTask { $0?.cancel() }
            })
        }
        await #expect(throws: CancellationError.self) { try await during.value }
        #expect(await starts.loadsSeen == [0])
        #expect(Stub890.requests.isEmpty, "cancelled while reporting the start: no load")
    }
}
