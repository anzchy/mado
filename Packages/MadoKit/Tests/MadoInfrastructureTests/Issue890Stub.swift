import Foundation
import Testing
import MadoApplication
@testable import MadoInfrastructure

/// #890: a URLProtocol that answers every request made through a session listing it, so the real transport runs end
/// to end and no request reaches the network. Its own state (not StubURLProtocol's), so the #890 suite cannot race the
/// #689 suite; only `Issue890TransportTests` (serialized) drives it.
final class Stub890: URLProtocol, @unchecked Sendable {
    enum Outcome {
        case respond(Int, Data)
        /// A 3xx pointing at `location`, with a body. Following it would start a second load, which this stub records.
        case redirect(Int, String, Data)
        case hang
    }
    /// When a cancelled load's `stopLoading` is counted (#904). `.immediate` is what URLSession gives; `.after` counts
    /// it later on another queue, the way it can arrive after the cancelled result; `.never` drops it, as if
    /// cancellation never reached the load.
    enum StopDelivery {
        case immediate
        case after(TimeInterval)
        case never
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var outcomes: [Outcome] = []
    nonisolated(unsafe) private static var seen: [(request: URLRequest, body: Data)] = []
    nonisolated(unsafe) private static var stopped = 0
    nonisolated(unsafe) private static var hung: [Stub890] = []
    nonisolated(unsafe) private static var afterRecord: (@Sendable () -> Void)?
    nonisolated(unsafe) private static var stops = StopDelivery.immediate
    /// Bumped by every reset. A load remembers the one it started in, and its stop counts only while that reset is
    /// current, so a stop from an earlier test is never counted in a later one, however late it arrives (#904).
    nonisolated(unsafe) private static var generation = 0
    nonisolated(unsafe) private static var stopCallCount = 0
    private var startedIn = -1

    static func reset(_ outcomes: [Outcome], afterRecord: (@Sendable () -> Void)? = nil,
                      stops: StopDelivery = .immediate) {
        lock.lock(); defer { lock.unlock() }
        self.outcomes = outcomes; seen = []; stopped = 0; stopCallCount = 0; hung = []
        self.afterRecord = afterRecord
        self.stops = stops
        generation += 1
    }
    static var requests: [(request: URLRequest, body: Data)] { lock.lock(); defer { lock.unlock() }; return seen }
    static var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stopped }
    /// Every `stopLoading` call since the last reset, counted or not, whatever its delivery (#904).
    static var stopCalls: Int { lock.lock(); defer { lock.unlock() }; return stopCallCount }
    static var hosts: [String?] { requests.map { $0.request.url?.host } }
    /// Ends every hanging load, as the network would later.
    static func failHung(_ error: URLError) {
        lock.lock(); let loads = hung; hung = []; lock.unlock()
        for load in loads { load.client?.urlProtocol(load, didFailWithError: error) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        Self.lock.lock()
        startedIn = Self.generation
        Self.seen.append((request, body))
        let outcome = Self.outcomes.isEmpty ? Outcome.respond(599, Data()) : Self.outcomes.removeFirst()
        if case .hang = outcome { Self.hung.append(self) }
        let afterRecord = Self.afterRecord
        Self.lock.unlock()
        afterRecord?()
        switch outcome {
        case .respond(let status, let data):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let status, let location, let data):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": location, "Content-Type": "text/html"])!
            var next = URLRequest(url: URL(string: location, relativeTo: request.url)!.absoluteURL)
            next.httpMethod = request.httpMethod
            next.httpBody = body
            next.allHTTPHeaderFields = request.allHTTPHeaderFields
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .hang:
            break
        }
    }

    override func stopLoading() {
        Self.lock.lock()
        Self.stopCallCount += 1
        let stops = Self.stops, startedIn = startedIn
        Self.lock.unlock()
        switch stops {
        case .immediate: Self.countStop(startedIn)
        case .after(let delay): DispatchQueue.global().asyncAfter(deadline: .now() + delay) { Self.countStop(startedIn) }
        case .never: break
        }
    }

    private static func countStop(_ startedIn: Int) {
        lock.lock(); defer { lock.unlock() }
        if startedIn == generation { stopped += 1 }
    }
}

func transport890(timeout: TimeInterval = 20) -> URLSessionHTTPTransport {
    URLSessionHTTPTransport(timeout: timeout, protocolClasses: [Stub890.self])
}

// MARK: - Table service fakes (MadoInfrastructureTests cannot see the #869 fixtures)

struct Settings890: TableRecognitionSettings {
    var endpoint: TableRecognitionEndpoint = .deepSeek
    var consentHost = "api.deepseek.com"
    func options() async -> TableRecognitionOptions {
        TableRecognitionOptions(cloudEnabled: true, endpoint: endpoint,
                                consent: TableRecognitionConsentRecord(host: consentHost, granted: true))
    }
}

let key890 = "sk-test-890-secret"

struct Keys890: TableRecognitionCredentialStore {
    func accessKey(for endpoint: TableRecognitionEndpoint) async -> String? { key890 }
}

func tableService890(_ settings: Settings890 = Settings890(), timeout: TimeInterval = 20) -> TableRecognitionService {
    TableRecognitionService(settings: settings, credentials: Keys890(), transport: transport890(timeout: timeout))
}

func chatReply890(_ content: String) -> Data {
    let choice: [String: Any] = ["index": 0, "message": ["role": "assistant", "content": content], "finish_reason": "stop"]
    return try! JSONSerialization.data(withJSONObject: ["choices": [choice]])
}

let table890 = chatReply890("| A | B |\n|---|---|\n| 1 | 2 |")

/// Holds a task so a URLProtocol hook can cancel it.
final class TaskBox890: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<TableRecognitionResult, Never>?
    func set(_ task: Task<TableRecognitionResult, Never>) { lock.lock(); self.task = task; lock.unlock() }
    func cancel() { lock.lock(); let task = task; lock.unlock(); task?.cancel() }
}

/// Collects the Baidu provider's failure details.
final class Details890: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [CloudFailureDetail] = []
    func append(_ detail: CloudFailureDetail) { lock.lock(); items.append(detail); lock.unlock() }
    var all: [CloudFailureDetail] { lock.lock(); defer { lock.unlock() }; return items }
}

/// Waits up to 10 s for `count` loads to start.
func awaitLoads890(_ count: Int) async throws {
    for _ in 0..<2000 {
        if Stub890.requests.count >= count { return }
        try await Task.sleep(for: .milliseconds(5))
    }
}
