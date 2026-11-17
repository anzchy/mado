import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
import MadoApplication
@testable import MadoInfrastructure

// #689b dev1: the device fallback could not be explained because Baidu's answer was reduced to cloudAuth/cloudQuota/
// cloudFailure. The provider now hands each failure's detail (stage, HTTP status, Baidu's error_code and error_msg,
// or the transport error's code) to `onFailure`, without the keys, the token, the image or a URL.

private actor Replies: HTTPTransport {
    var replies: [Result<HTTPResponse, any Error>]
    init(_ replies: [Result<HTTPResponse, any Error>]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> HTTPResponse { try replies.removeFirst().get() }
}
private final class Details: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [CloudFailureDetail] = []
    func add(_ detail: CloudFailureDetail) { lock.lock(); items.append(detail); lock.unlock() }
    var all: [CloudFailureDetail] { lock.lock(); defer { lock.unlock() }; return items }
}
private func reply(_ text: String, status: Int = 200) -> Result<HTTPResponse, any Error> {
    .success(HTTPResponse(statusCode: status, body: Data(text.utf8)))
}
private let pair = CloudCredentials(apiKey: "AKdevice0001", secretKey: "SKdevice0002")
private let token = reply(#"{"access_token":"TOKEN-abc-123","expires_in":2592000}"#)

private func pngImage() throws -> Data {
    let context = try #require(CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private func run(_ replies: [Result<HTTPResponse, any Error>]) async throws -> (TextRecognitionError?, [CloudFailureDetail]) {
    let details = Details()
    let provider = BaiduTextRecognitionProvider(transport: Replies(replies), onFailure: { details.add($0) })
    let image = try pngImage()
    do throws(TextRecognitionError) {
        _ = try await provider.recognise(image, credentials: pair)
        return (nil, details.all)
    } catch {
        return (error, details.all)
    }
}

@Test(.timeLimit(.minutes(2)), arguments: [
    (6, "No permission to access data", TextRecognitionError.cloudFailure),
    (17, "Open api daily request limit reached", .cloudQuota),
    (18, "Open api qps request limit reached", .cloudQuota),
    (111, "Access token expired", .cloudAuth)
])
func issue689bRecognitionErrorCodeIsReported(code: Int, message: String, error: TextRecognitionError) async throws {
    let (thrown, details) = try await run([token, reply(#"{"error_code":\#(code),"error_msg":"\#(message)"}"#)])
    #expect(thrown == error)
    #expect(details == [CloudFailureDetail(stage: .recognition, httpStatus: 200, errorCode: code, errorMessage: message)])
}

@Test(.timeLimit(.minutes(2)))
func issue689bTokenRefusalIsReported() async throws {
    let (thrown, details) = try await run([reply(#"{"error":"invalid_client","error_description":"unknown client id"}"#, status: 401)])
    #expect(thrown == .cloudAuth)
    #expect(details == [CloudFailureDetail(stage: .token, httpStatus: 401, errorMessage: "invalid_client: unknown client id")])
}

@Test(.timeLimit(.minutes(2)))
func issue689bTokenErrorCodeAndMissingTokenAreReported() async throws {
    let (codeThrown, codeDetails) = try await run([reply(#"{"error_code":4,"error_msg":"Open api request limit reached"}"#)])
    #expect(codeThrown == .cloudAuth)
    #expect(codeDetails == [CloudFailureDetail(stage: .token, httpStatus: 200, errorCode: 4,
                                               errorMessage: "Open api request limit reached")])
    let (missingThrown, missingDetails) = try await run([reply(#"{"expires_in":10}"#)])
    #expect(missingThrown == .cloudAuth)
    #expect(missingDetails == [CloudFailureDetail(stage: .token, httpStatus: 200, errorMessage: "no access_token")])
}

@Test(.timeLimit(.minutes(2)))
func issue689bTransportFailuresReportOnlyTheirCode() async throws {
    let timedOut = URLError(.timedOut, userInfo: [NSURLErrorFailingURLStringErrorKey:
        "https://aip.baidubce.com/rest/2.0/ocr/v1/accurate_basic?access_token=TOKEN-abc-123"])
    let (tokenThrown, tokenDetails) = try await run([.failure(URLError(.notConnectedToInternet))])
    #expect(tokenThrown == .cloudOffline)
    #expect(tokenDetails == [CloudFailureDetail(stage: .token, transportError: "URLError -1009")])
    let (ocrThrown, ocrDetails) = try await run([token, .failure(timedOut)])
    #expect(ocrThrown == .cloudOffline)
    #expect(ocrDetails == [CloudFailureDetail(stage: .recognition, transportError: "URLError -1001")])
    let (refusedThrown, refusedDetails) = try await run([token, .failure(URLSessionHTTPTransport.Refusal.redirected)])
    #expect(refusedThrown == .cloudFailure)
    #expect(refusedDetails == [CloudFailureDetail(stage: .recognition, transportError: "refused redirected")])
    struct Other: Error { let secret = "AKdevice0001" }
    let (otherThrown, otherDetails) = try await run([token, .failure(Other())])
    #expect(otherThrown == .cloudFailure)
    #expect(otherDetails == [CloudFailureDetail(stage: .recognition, transportError: "Other")])
}

@Test(.timeLimit(.minutes(2)))
func issue689bUnreadableAndShapelessAnswersAreReported() async throws {
    let (htmlThrown, htmlDetails) = try await run([token, reply("<html>bad gateway</html>", status: 502)])
    #expect(htmlThrown == .cloudFailure)
    #expect(htmlDetails == [CloudFailureDetail(stage: .recognition, httpStatus: 502, errorMessage: "unreadable response")])
    let (tokenThrown, tokenDetails) = try await run([reply("", status: 500)])
    #expect(tokenThrown == .cloudFailure)
    #expect(tokenDetails == [CloudFailureDetail(stage: .token, httpStatus: 500, errorMessage: "unreadable response")])
    let (shapeThrown, shapeDetails) = try await run([token, reply(#"{"log_id":1}"#, status: 500)])
    #expect(shapeThrown == .cloudFailure)
    #expect(shapeDetails == [CloudFailureDetail(stage: .recognition, httpStatus: 500, errorMessage: "no words_result")])
}

@Test(.timeLimit(.minutes(2)))
func issue689bSuccessAndInvalidImageReportNoDetail() async throws {
    let (thrown, details) = try await run([token, reply(#"{"words_result":[{"words":"hi"}]}"#)])
    #expect(thrown == nil)
    #expect(details.isEmpty)
    let provider = BaiduTextRecognitionProvider(transport: Replies([]), onFailure: { _ in Issue.record("no detail for a local refusal") })
    await #expect(throws: TextRecognitionError.invalidImage) { try await provider.recognise(Data([1, 2]), credentials: pair) }
}

@Test(.timeLimit(.minutes(2)))
func issue689bBaiduMessageNeverCarriesKeysOrToken() async throws {
    let echo = "bad AKdevice0001 / SKdevice0002 / TOKEN-abc-123 " + String(repeating: "x", count: 400) + "\nnext"
    let body = try JSONSerialization.data(withJSONObject: ["error_code": 216100, "error_msg": echo])
    let (_, details) = try await run([token, .success(HTTPResponse(statusCode: 200, body: body))])
    let message = try #require(details.first?.errorMessage)
    #expect(!message.contains("AKdevice0001") && !message.contains("SKdevice0002") && !message.contains("TOKEN-abc-123"))
    #expect(message.hasPrefix("bad <redacted> / <redacted> / <redacted> "))
    #expect(message.count <= 200)
    #expect(!message.contains("\n"))
    let (_, tokenDetails) = try await run([reply(#"{"error":"invalid_client","error_description":"bad AKdevice0001"}"#, status: 401)])
    #expect(tokenDetails.first?.errorMessage == "invalid_client: bad <redacted>")
}

@Test(.timeLimit(.minutes(2)))
func issue689bFailureDetailLogMessage() {
    #expect(CloudFailureDetail(stage: .recognition, httpStatus: 200, errorCode: 6, errorMessage: "No permission to access data")
        .logMessage == #"baidu stage=recognition http=200 error_code=6 error_msg="No permission to access data""#)
    #expect(CloudFailureDetail(stage: .token, httpStatus: 401, errorMessage: "invalid_client: unknown client id").logMessage
            == #"baidu stage=token http=401 error_msg="invalid_client: unknown client id""#)
    #expect(CloudFailureDetail(stage: .token, transportError: "URLError -1009").logMessage
            == "baidu stage=token transport=URLError -1009")
}
