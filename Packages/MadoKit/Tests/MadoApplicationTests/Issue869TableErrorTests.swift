import Foundation
import Testing
@testable import MadoApplication

// #869 WI-3: failures are classified (AC-4), never retried, and cancellation is its own result.

private let png = makePNG869(3, 2)
private let imageBody = #"{"error":{"message":"bad image"}}"#

private func run(_ reply: RecordingTransport869.Reply) async -> (TableRecognitionResult, Int) {
    let transport = RecordingTransport869([reply])
    let result = await makeService869(transport: transport).recognise(png)
    return (result, await transport.callCount)
}

@Test(.timeLimit(.minutes(2)), arguments: [
    (401, "{}", TableRecognitionFailure.keyRejected),
    (403, "{}", .keyRejected),
    (404, "{}", .addressUnreachable),
    (400, #"{"error":{"message":"This model does not support Image input"}}"#, .modelCannotReadImages),
    (422, #"{"error":{"message":"IMAGE not supported"}}"#, .modelCannotReadImages),
    (400, #"{"error":{"message":"unknown variant `image_url`, expected `text`"}}"#, .modelCannotReadImages),
    (400, #"{"error":{"message":"invalid temperature"}}"#, .other),
    (400, #"{"error":{"type":"image_error","message":"bad request"}}"#, .other),
    (422, "not json", .other),
    (402, "{}", .quotaOrBalance),
    (429, "{}", .quotaOrBalance),
    (413, "{}", .tooLarge),
    (500, "{}", .other),
    (502, "{}", .other),
    (503, "{}", .other),
    (418, "{}", .other),
    (201, String(decoding: chatReply869(content: goodTable869), as: UTF8.self), .other),
    (204, "", .other),
])
func issue869WI3StatusClassTable(status: Int, body: String, expected: TableRecognitionFailure) async {
    let (result, calls) = await run(reply869(status, body))
    #expect(result == .failed(expected), "\(status) \(body)")
    #expect(calls == 1)
}

@Test(.timeLimit(.minutes(2)))
func issue869WI3StatusSweepClassifiesEveryCode() async {
    let tableBody = String(decoding: chatReply869(content: goodTable869), as: UTF8.self)
    for status in 100...599 where status != 200 && !(300...399).contains(status) {
        for (name, body) in [("image", imageBody), ("table", tableBody)] {
            let expected: TableRecognitionFailure = switch status {
            case 401, 403: .keyRejected
            case 404: .addressUnreachable
            case 400, 422: name == "image" ? .modelCannotReadImages : .other
            case 402, 429: .quotaOrBalance
            case 413: .tooLarge
            default: .other
            }
            let (result, calls) = await run(reply869(status, body))
            #expect(result == .failed(expected), "\(status) \(name)")
            #expect(calls == 1, "\(status) \(name)")
        }
    }
}

@Test(.timeLimit(.minutes(2)), arguments: [
    (URLError.Code.cannotFindHost, TableRecognitionFailure.addressUnreachable),
    (.cannotConnectToHost, .addressUnreachable),
    (.dnsLookupFailed, .addressUnreachable),
    (.secureConnectionFailed, .addressUnreachable),
    (.serverCertificateHasBadDate, .addressUnreachable),
    (.serverCertificateUntrusted, .addressUnreachable),
    (.serverCertificateHasUnknownRoot, .addressUnreachable),
    (.serverCertificateNotYetValid, .addressUnreachable),
    (.badURL, .addressUnreachable),
    (.unsupportedURL, .addressUnreachable),
    (.notConnectedToInternet, .offline),
    (.networkConnectionLost, .offline),
    (.dataNotAllowed, .offline),
    (.internationalRoamingOff, .offline),
    (.timedOut, .other),
    (.badServerResponse, .other),
])
func issue869WI3URLErrorClassTable(code: URLError.Code, expected: TableRecognitionFailure) async {
    let (result, calls) = await run(.failure(URLError(code)))
    #expect(result == .failed(expected), "\(code.rawValue)")
    #expect(calls == 1)
}

private struct Boom: Error {}

@Test(.timeLimit(.minutes(2)))
func issue869WI3OtherThrownErrorIsOther() async {
    let (result, calls) = await run(.failure(Boom()))
    #expect(result == .failed(.other))
    #expect(calls == 1)
}

@Test(.timeLimit(.minutes(2)), arguments: [
    "", "not json", "[]", "{}", #"{"choices":[]}"#, #"{"choices":"x"}"#, #"{"choices":[{}]}"#,
    #"{"choices":[{"message":{"content":42}}]}"#,
])
func issue869WI3Unparseable200IsOther(body: String) async {
    let (result, calls) = await run(reply869(200, body))
    #expect(result == .failed(.other), "\(body)")
    #expect(calls == 1)
}

@Test(.timeLimit(.minutes(2)))
func issue869WI3CancelledBeforeCallSendsNothing() async {
    let transport = RecordingTransport869()
    let service = makeService869(transport: transport)
    let result = await Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return await service.recognise(png)
    }.value
    #expect(result == .cancelled)
    #expect(await transport.callCount == 0)
}

@Test(.timeLimit(.minutes(2)))
func issue869WI3CancelledDuringGuardReadsSendsNothing() async {
    let settings = FakeTableSettings869(gated: true)
    let transport = RecordingTransport869()
    let service = makeService869(settings: settings, transport: transport)
    let task = Task { await service.recognise(png) }
    await settings.entered()
    task.cancel()
    await settings.open()
    #expect(await task.value == .cancelled)
    #expect(await transport.callCount == 0)
}

@Test(.timeLimit(.minutes(2)))
func issue869WI3CancelledDuringKeyReadSendsNothing() async {
    let keys = FakeTableKeys869(gated: true)
    let transport = RecordingTransport869()
    let service = makeService869(keys: keys, transport: transport)
    let task = Task { await service.recognise(png) }
    await keys.entered()
    task.cancel()
    await keys.open()
    #expect(await task.value == .cancelled)
    #expect(await transport.callCount == 0)
}

@Test(.timeLimit(.minutes(2)), arguments: ["cancellation", "urlCancelled"])
func issue869WI3TransportCancellationErrorsAreCancelled(kind: String) async {
    let error: any Error = kind == "cancellation" ? CancellationError() : URLError(.cancelled)
    let (result, calls) = await run(.failure(error))
    #expect(result == .cancelled)
    #expect(calls == 1)
}

@Test(.timeLimit(.minutes(2)))
func issue869WI3CancelledWhileAwaitingReplyDiscardsTable() async {
    let transport = RecordingTransport869([.response(goodReply869())], gated: true)
    let service = makeService869(transport: transport)
    let task = Task { await service.recognise(png) }
    await transport.entered()
    task.cancel()
    await transport.open()
    #expect(await task.value == .cancelled)
    #expect(await transport.callCount == 1)
}

@Test(.timeLimit(.minutes(2)), arguments: [(401, TableRecognitionFailure.keyRejected), (400, .other)])
func issue869WI3FailureDescriptionsRedactSecrets(status: Int, expected: TableRecognitionFailure) async {
    let prefix = String(png.base64EncodedString().prefix(64))
    let body = #"{"error":{"message":"bad key sk-SECRET-869 for "# + prefix + #""}}"#
    let transport = RecordingTransport869([reply869(status, body)])
    let keys = FakeTableKeys869([TableRecognitionEndpoint.deepSeekDefault869: "sk-SECRET-869"])
    let result = await makeService869(keys: keys, transport: transport).recognise(png)
    #expect(result == .failed(expected))
    var dumped = ""
    dump(result, to: &dumped)
    for text in [String(describing: result), String(reflecting: result), dumped] {
        #expect(!text.contains("sk-SECRET-869") && !text.contains(prefix))
    }
}
