import Foundation
import Testing
import MadoApplication
@testable import MadoInfrastructure

// #874 fix round 3 WI-1 (audit i874-confirm2 gpt F1): the URLSession transport reports the load (`onLoad`) only after
// its last cancellation check, as it starts the load. A call refused, cancelled before it was admitted, or cancelled
// while it reported the start (`onStart`) never reports the load and loads nothing.

/// The loads the stub had seen each time `onLoad` ran; written from the transport's thread.
private final class Loads874H: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Int] = []
    func mark(_ loads: Int) { lock.lock(); seen.append(loads); lock.unlock() }
    var loadsSeen: [Int] { lock.lock(); defer { lock.unlock() }; return seen }
}

private let tableRequest874H = URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!)
private let deepSeek874H = HTTPDestination.consentedHost(host: "api.deepseek.com", port: nil)

extension Issue890TransportTests {
    @Test(.timeLimit(.minutes(2)))
    func issue874Fix3TheTransportReportsTheLoadOnceAfterTheStartAndBeforeTheLoad() async throws {
        let loads = Loads874H()
        Stub890.reset([.respond(200, Data("{}".utf8))])
        await #expect(throws: URLSessionHTTPTransport.Refusal.notAllowedHost) {
            try await transport890().send(tableRequest874H, to: .consentedHost(host: "other.example.com", port: nil),
                                          onStart: {}, onLoad: { loads.mark(Stub890.requests.count) })
        }
        #expect(loads.loadsSeen.isEmpty, "a refused destination reports no load")
        let started = Loads874H()
        let response = try await transport890().send(tableRequest874H, to: deepSeek874H,
            onStart: { started.mark(loads.loadsSeen.count) }, onLoad: { loads.mark(Stub890.requests.count) })
        #expect(response.statusCode == 200)
        #expect(started.loadsSeen == [0], "the start was reported before the load was")
        #expect(loads.loadsSeen == [0], "the load reported once, just before it began")
        #expect(Stub890.requests.count == 1)
    }

    @Test(.timeLimit(.minutes(2)))
    func issue874Fix3ACallCancelledBeforeOrWhileReportingTheStartNeverReportsTheLoad() async throws {
        let loads = Loads874H()
        Stub890.reset([.respond(200, Data("{}".utf8)), .respond(200, Data("{}".utf8))])
        let transport = transport890()
        let before = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await transport.send(tableRequest874H, to: deepSeek874H, onStart: {},
                                            onLoad: { loads.mark(-1) })
        }
        await #expect(throws: CancellationError.self) { try await before.value }
        let during = Task {
            try await transport.send(tableRequest874H, to: deepSeek874H,
                                     onStart: { withUnsafeCurrentTask { $0?.cancel() } },
                                     onLoad: { loads.mark(Stub890.requests.count) })
        }
        await #expect(throws: CancellationError.self) { try await during.value }
        #expect(loads.loadsSeen.isEmpty, "a cancelled call never says it is loading")
        #expect(Stub890.requests.isEmpty, "cancelled before or while reporting the start: no load")
    }
}
