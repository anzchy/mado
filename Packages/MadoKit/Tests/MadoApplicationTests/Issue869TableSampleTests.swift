import Foundation
import Testing
@testable import MadoApplication
import MadoInfrastructure

// #869 WI-6: the Settings Test sends a built-in sample table, under the same guards and classes as a real run, and
// passes only when the expected cells come back (AC-6). The expected cells are spelled out here on purpose: the test
// must not read the production constant.

private let sampleRows: [[String]] = [
    ["Item", "Qty", "Price"],
    ["Apple", "3", "1.20"],
    ["Pear", "5", "0.80"],
]

private func markdown(_ rows: [[String]]) -> String {
    var lines = [rows[0]] + [rows[0].map { _ in "---" }] + rows.dropFirst()
    if rows.isEmpty { lines = [] }
    return lines.map { "| " + $0.joined(separator: " | ") + " |" }.joined(separator: "\n")
}

private func sampleReply(_ rows: [[String]] = sampleRows, finish: String = "stop") -> RecordingTransport869.Reply {
    .response(HTTPResponse(statusCode: 200, body: chatReply869(content: markdown(rows), finish: finish)))
}

private func runTest(_ reply: RecordingTransport869.Reply, options: TableRecognitionOptions = .default869)
    async -> (TableRecognitionTestResult, RecordingTransport869) {
    let transport = RecordingTransport869([reply])
    let result = await makeService869(settings: FakeTableSettings869(options), transport: transport).testService()
    return (result, transport)
}

@Test(.timeLimit(.minutes(2)))
func issue869WI6ExactSampleReplyPasses() async {
    let (result, transport) = await runTest(sampleReply())
    #expect(result == .passed)
    #expect(await transport.callCount == 1)
}

@Test(.timeLimit(.minutes(2)))
func issue869WI6CaseAndPaddingVariantsPass() async {
    let seed: UInt64 = 0x0869_0006
    var rng = SplitMix869(seed: seed)
    for iteration in 0..<50 {
        let outer = rng.next() % 2 == 0
        let lines = ([sampleRows[0], sampleRows[0].map { _ in "---" }] + sampleRows.dropFirst()).map { row in
            let cells = row.map { cell in
                let flipped = String(cell.map { rng.next() % 2 == 0 ? Character($0.uppercased()) : Character($0.lowercased()) })
                let shown = cell == "---" ? cell : flipped
                return String(repeating: " ", count: Int(rng.next() % 4)) + shown + String(repeating: " ", count: Int(rng.next() % 4))
            }.joined(separator: "|")
            return outer ? "|" + cells + "|" : cells
        }
        let reply = RecordingTransport869.Reply.response(
            HTTPResponse(statusCode: 200, body: chatReply869(content: lines.joined(separator: "\n"))))
        let (result, _) = await runTest(reply)
        #expect(result == .passed, "seed \(seed) iteration \(iteration): \(lines)")
    }
}

@Test(.timeLimit(.minutes(2)))
func issue869WI6AnyStructuralOrCellChangeFails() async {
    var mutations: [(String, [[String]])] = []
    for row in sampleRows.indices {
        for column in sampleRows[row].indices {
            var rows = sampleRows
            rows[row][column] = "ZZ"
            mutations.append(("cell \(row),\(column)", rows))
        }
        var dropped = sampleRows
        dropped.remove(at: row)
        mutations.append(("drop row \(row)", dropped))
    }
    mutations.append(("extra column", sampleRows.map { $0 + ["x"] }))
    for row in 0..<(sampleRows.count - 1) {
        var swapped = sampleRows
        swapped.swapAt(row, row + 1)
        mutations.append(("swap rows \(row)", swapped))
    }
    mutations.append(("swap columns", sampleRows.map { [$0[1], $0[0]] + $0.dropFirst(2) }))
    for (name, rows) in mutations {
        let (result, transport) = await runTest(sampleReply(rows))
        #expect(result == .failed(.other), "\(name)")
        #expect(await transport.callCount == 1, "\(name)")
    }
}

@Test(.timeLimit(.minutes(2)))
func issue869WI6NoTableAndTruncatedReplies() async {
    let noTable = RecordingTransport869.Reply.response(
        HTTPResponse(statusCode: 200, body: chatReply869(content: "Sorry, no table.")))
    #expect(await runTest(noTable).0 == .failed(.noTable))
    #expect(await runTest(sampleReply(finish: "length")).0 == .failed(.incomplete))
}

@Test(.timeLimit(.minutes(2)), arguments: ["cloudOff", "invalidEndpoint", "consentNotAsked", "consentDeclined",
                                           "consentHostChanged", "noAccessKey"])
func issue869WI6GuardsSendNothing(reason: String) async {
    var options = TableRecognitionOptions.default869
    var keys = FakeTableKeys869()
    let expected: TableRecognitionBlock
    switch reason {
    case "cloudOff": options = .options869(enabled: false); expected = .cloudOff
    case "invalidEndpoint":
        options = .options869(endpoint: TableRecognitionEndpoint(preset: .deepSeek, baseURL: "http://api.deepseek.com",
                                                                 model: "deepseek-flash"))
        expected = .invalidEndpoint
    case "consentNotAsked": options = .options869(consentHost: nil); expected = .consentNotAsked
    case "consentDeclined": options = .options869(granted: false); expected = .consentDeclined
    case "consentHostChanged": options = .options869(consentHost: "gw.example.com"); expected = .consentHostChanged
    default: keys = FakeTableKeys869([:]); expected = .noAccessKey
    }
    let transport = RecordingTransport869()
    let result = await makeService869(settings: FakeTableSettings869(options), keys: keys, transport: transport).testService()
    #expect(result == .notSent(expected))
    #expect(await transport.callCount == 0)
}

private struct Boom: Error {}

@Test(.timeLimit(.minutes(2)))
func issue869WI6ErrorClassesMatchRecognise() async {
    var outcomes: [(String, RecordingTransport869.Reply)] = (100...599).filter { $0 != 200 }.map {
        ("status \($0)", reply869($0, #"{"error":{"message":"bad image"}}"#))
    }
    let codes: [URLError.Code] = [.cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .secureConnectionFailed,
                                  .serverCertificateHasBadDate, .serverCertificateUntrusted,
                                  .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .badURL,
                                  .unsupportedURL, .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                                  .internationalRoamingOff, .timedOut, .badServerResponse, .cancelled]
    outcomes += codes.map { ("URLError \($0.rawValue)", .failure(URLError($0))) }
    outcomes += [("CancellationError", .failure(CancellationError())), ("Boom", .failure(Boom()))]
    let png = makePNG869(3, 2)
    for (name, reply) in outcomes {
        let testTransport = RecordingTransport869([reply])
        let tested = await makeService869(transport: testTransport).testService()
        let recogniseTransport = RecordingTransport869([reply])
        let recognised = await makeService869(transport: recogniseTransport).recognise(png)
        let expected: TableRecognitionTestResult? = switch recognised {
        case .failed(let failure): .failed(failure)
        case .cancelled: .cancelled
        default: nil
        }
        #expect(expected != nil, "\(name): recognise gave \(recognised)")
        #expect(tested == expected, "\(name)")
        #expect(await testTransport.callCount == 1, "\(name)")
        #expect(await recogniseTransport.callCount == 1, "\(name)")
    }
}

@Test(.timeLimit(.minutes(2)))
func issue869WI6SentSampleIsPNGWithinLimits() async throws {
    let transport = RecordingTransport869([sampleReply(), sampleReply()])
    let service = makeService869(transport: transport)
    #expect(await service.testService() == .passed)
    #expect(await service.testService() == .passed)
    let custom = TableRecognitionEndpoint.custom869()
    let customTransport = RecordingTransport869([sampleReply()])
    let customResult = await makeService869(settings: FakeTableSettings869(.options869(endpoint: custom, consentHost: "gw.example.com")),
                                            keys: FakeTableKeys869([custom: "sk-1"]), transport: customTransport).testService()
    #expect(customResult == .passed)

    let requests = await transport.requests + customTransport.requests
    try #require(requests.count == 3)
    var payloads: [Data] = []
    for request in requests {
        let payload = try #require(payload869(request))
        #expect(payload.mediaType == "image/png")
        #expect(payload.base64.utf8.count <= 33_554_432)
        let data = try #require(Data(base64Encoded: payload.base64))
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        let size = try #require(pixelSize869(data))
        #expect(size.0 > 0 && size.1 > 0 && max(size.0, size.1) <= 8192)
        payloads.append(data)
    }
    #expect(payloads[0] == payloads[1])
    #expect(payloads[1] == payloads[2])
    #expect(Set(bodyObject869(requests[0]).keys) == ["model", "messages", "thinking", "temperature", "stream"])
    #expect(Set(bodyObject869(requests[2]).keys) == ["model", "messages", "stream"])
}

/// Real Vision reads every expected cell from the rendered sample, so a pass means the image really shows them.
@Test(.timeLimit(.minutes(2)))
func issue869WI6SampleImageReadsBackOnDevice() async throws {
    let transport = RecordingTransport869([sampleReply()])
    _ = await makeService869(transport: transport).testService()
    let request = try #require(await transport.requests.first)
    let data = try #require(payload869(request).flatMap { Data(base64Encoded: $0.base64) })
    let text = try await OnDeviceTextRecognitionProvider().recognise(data).lowercased()
    for cell in sampleRows.joined() {
        #expect(text.contains(cell.lowercased()), "Vision did not read \(cell): \(text)")
    }
}

@Test(.timeLimit(.minutes(2)))
func issue869WI6CancelledBeforeSendIsCancelled() async {
    let transport = RecordingTransport869()
    let service = makeService869(transport: transport)
    let result = await Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return await service.testService()
    }.value
    #expect(result == .cancelled)
    #expect(await transport.callCount == 0)
}

@Test(.timeLimit(.minutes(2)))
func issue869WI6CancelledWhileAwaitingReplyIsCancelled() async {
    let transport = RecordingTransport869([sampleReply()], gated: true)
    let service = makeService869(transport: transport)
    let task = Task { await service.testService() }
    let held = await awaitHeldSend869(transport, task)
    #expect(held, "testService must send the sample")
    task.cancel()
    await transport.open()
    #expect(await task.value == .cancelled)
    #expect(await transport.callCount == 1)
}
