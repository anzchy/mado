import Foundation
import Testing
import MadoApplication
@testable import MadoInfrastructure

// #890 WI-4: cancelling a table run reaches the real URLSession call and yields the distinct cancelled result.

extension Issue890TransportTests {
    @Test(.timeLimit(.minutes(2)))
    func issue890WI4CancellingAnInFlightTableRequestStopsTheLoad() async throws {
        Stub890.reset([.hang])
        let service = tableService890()
        let image = try png890(width: 3, height: 2)
        let task = Task { await service.recognise(image) }
        try await awaitLoads890(1)
        try #require(Stub890.requests.count == 1)
        let cancelledAt = Date()
        task.cancel()
        let result = await task.value
        #expect(result == .cancelled)
        #expect(Date().timeIntervalSince(cancelledAt) < 5)
        // The cancellation reached the URLSession load itself (its stopLoading can arrive after the result, #904).
        // Checked before the stub ends the hung load: a stop of a load the stub ended itself never counts.
        #expect(try await stopReached { Stub890.stopCount })
        Stub890.failHung(URLError(.timedOut))
    }

    @Test(.timeLimit(.minutes(2)))
    func issue890WI4CancelledBeforeSendSendsNothing() async throws {
        Stub890.reset([.respond(200, table890)])
        let service = tableService890()
        let image = try png890(width: 3, height: 2)
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await service.recognise(image)
        }.value
        #expect(result == .cancelled)
        #expect(Stub890.requests.isEmpty)
        // At the transport itself: a request sent from a cancelled task never starts a load.
        Stub890.reset([.respond(200, table890)])
        let transport = transport890()
        let outcome = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await transport.send(URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!),
                                            to: .consentedHost(host: "api.deepseek.com", port: nil))
        }.result
        guard case .failure(let error) = outcome else { Issue.record("expected cancellation"); return }
        #expect(error is CancellationError || (error as? URLError)?.code == .cancelled)
        #expect(Stub890.requests.isEmpty)
    }

    @Test(.timeLimit(.minutes(2)))
    func issue890WI4CancelledWhileTheAnswerArrivesIsCancelled() async throws {
        let box = TaskBox890()
        Stub890.reset([.respond(200, table890)], afterRecord: { box.cancel() })
        let service = tableService890()
        let image = try png890(width: 3, height: 2)
        let (start, go) = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in start { break }
            return await service.recognise(image)
        }
        box.set(task)
        go.yield()
        go.finish()
        #expect(await task.value == .cancelled)
        #expect(Stub890.requests.count == 1)
    }
}

extension Issue890TransportTests {
    /// URLSession alone sometimes starts a load from an already-cancelled task (seen once in a full #890 run); the
    /// transport must never. Repeated so the race shows.
    @Test(.timeLimit(.minutes(2)))
    func issue890WI4bCancelledTransportCallNeverStartsALoad() async throws {
        let transport = transport890()
        let request = URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!)
        var loads = 0
        for _ in 0..<200 {
            Stub890.reset([.respond(200, table890)])
            let outcome = await Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await transport.send(request, to: .consentedHost(host: "api.deepseek.com", port: nil))
            }.result
            if case .success = outcome { Issue.record("a cancelled call returned an answer") }
            loads += Stub890.requests.count
        }
        #expect(loads == 0)
    }
}
