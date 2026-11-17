import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
import MadoApplication
@testable import MadoInfrastructure

// #689b dev1: the device fallback could not be explained because Baidu's answer was reduced to cloudAuth/cloudQuota/
// cloudFailure. The provider now hands each failure's detail to `onFailure`, without the keys, the token, the image or
// a URL. #689b dev2: the detail carries only bounded facts (stage, HTTP status, numeric error_code, a fixed reason id
// from an allowlist, the transport error's code); Baidu's error_msg and the OAuth error_description never reach it.

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
private func json(_ object: [String: Any], status: Int = 200) throws -> Result<HTTPResponse, any Error> {
    .success(HTTPResponse(statusCode: status, body: try JSONSerialization.data(withJSONObject: object)))
}
private let pair = CloudCredentials(apiKey: "AKdevice0001", secretKey: "SKdevice0002")
/// A key with a character the form body encodes (`+` → `%2B`), and a secret with a quote.
private let hostilePair = CloudCredentials(apiKey: "a+bAKD2", secretKey: "SKD2\"q")
private let token = reply(#"{"access_token":"TOKEN-abc-123","expires_in":2592000}"#)
typealias Reason = CloudFailureDetail.Reason

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

private func run(_ replies: [Result<HTTPResponse, any Error>], credentials: CloudCredentials = pair,
                 image: Data? = nil) async throws -> (TextRecognitionError?, [CloudFailureDetail]) {
    let details = Details()
    let provider = BaiduTextRecognitionProvider(transport: Replies(replies), onFailure: { details.add($0) })
    let image = try image ?? pngImage()
    do throws(TextRecognitionError) {
        _ = try await provider.recognise(image, credentials: credentials)
        return (nil, details.all)
    } catch {
        return (error, details.all)
    }
}

/// The hostile server text: image-like text, the raw key, its form-encoded variant, the secret, the token, quotes,
/// a newline and length.
private let hostile = "图像文字识别 a+bAKD2 a%2BbAKD2 SKD2\"q TOKEN-abc-123 \"quoted\"\nsecond line "
    + String(repeating: "x", count: 400)
private let hostileFragments = ["图像", "a+b", "a%2B", "SKD2", "TOKEN-abc", "quoted", "second", "xxxx", "\"", "\n"]

private func expectNoServerText(_ detail: CloudFailureDetail, sourceLocation: SourceLocation = #_sourceLocation) {
    for rendering in [detail.logMessage, String(reflecting: detail), String(describing: detail)] {
        for fragment in hostileFragments {
            #expect(!rendering.contains(fragment), "\(fragment.debugDescription) in \(rendering.debugDescription)",
                    sourceLocation: sourceLocation)
        }
    }
}

// MARK: - dev1 tests, rewritten for dev2 (errorMessage → reason)

@Test(.timeLimit(.minutes(2)), arguments: [
    (6, Reason.permission, TextRecognitionError.cloudFailure),
    (17, .quota, .cloudQuota),
    (18, .quota, .cloudQuota),
    (111, .auth, .cloudAuth)
])
func issue689bRecognitionErrorCodeIsReported(code: Int, reason: Reason, error: TextRecognitionError) async throws {
    let (thrown, details) = try await run([token, reply(#"{"error_code":\#(code),"error_msg":"Baidu says"}"#)])
    #expect(thrown == error)
    #expect(details == [CloudFailureDetail(stage: .recognition, httpStatus: 200, errorCode: code, reason: reason)])
}

@Test(.timeLimit(.minutes(2)))
func issue689bTokenRefusalIsReported() async throws {
    let (thrown, details) = try await run([reply(#"{"error":"invalid_client","error_description":"unknown client id"}"#, status: 401)])
    #expect(thrown == .cloudAuth)
    #expect(details == [CloudFailureDetail(stage: .token, httpStatus: 401, reason: .invalidClient)])
}

@Test(.timeLimit(.minutes(2)))
func issue689bTokenErrorCodeAndMissingTokenAreReported() async throws {
    let (codeThrown, codeDetails) = try await run([reply(#"{"error_code":4,"error_msg":"Open api request limit reached"}"#)])
    #expect(codeThrown == .cloudAuth)
    #expect(codeDetails == [CloudFailureDetail(stage: .token, httpStatus: 200, errorCode: 4, reason: .other)])
    let (missingThrown, missingDetails) = try await run([reply(#"{"expires_in":10}"#)])
    #expect(missingThrown == .cloudAuth)
    #expect(missingDetails == [CloudFailureDetail(stage: .token, httpStatus: 200, reason: .noAccessToken)])
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
    let (_, details) = try await run([token, try json(["error_code": 216100, "error_msg": echo])])
    let detail = try #require(details.first)
    let (_, tokenDetails) = try await run([reply(#"{"error":"invalid_client","error_description":"bad AKdevice0001"}"#, status: 401)])
    let tokenDetail = try #require(tokenDetails.first)
    for rendering in [detail.logMessage, String(reflecting: detail), tokenDetail.logMessage, String(reflecting: tokenDetail)] {
        for secret in ["AKdevice0001", "SKdevice0002", "TOKEN-abc-123", "bad", "xxxx", "next", "\n"] {
            #expect(!rendering.contains(secret), "\(secret) in \(rendering)")
        }
    }
}

@Test(.timeLimit(.minutes(2)))
func issue689bFailureDetailLogMessage() {
    #expect(CloudFailureDetail(stage: .recognition, httpStatus: 200, errorCode: 6, reason: .permission).logMessage
            == "baidu stage=recognition http=200 error_code=6 reason=permission")
    #expect(CloudFailureDetail(stage: .token, httpStatus: 401, reason: .invalidClient).logMessage
            == "baidu stage=token http=401 reason=invalid_client")
    #expect(CloudFailureDetail(stage: .token, transportError: "URLError -1009").logMessage
            == "baidu stage=token transport=URLError -1009")
}

// MARK: - dev2: CloudFailureDetail shape

private func logPattern() throws -> Regex<AnyRegexOutput> {
    try Regex(#"^baidu stage=(token|recognition)( http=-?\d+)?( error_code=-?\d+)?( reason=[a-z_]+)?( transport=[^"\n]+)?$"#)
}

@Test(.timeLimit(.minutes(2)))
func issue689bD2LogMessageShapes() throws {
    let pattern = try logPattern()
    let rows: [(CloudFailureDetail, String)] = [
        (CloudFailureDetail(stage: .token), "baidu stage=token"),
        (CloudFailureDetail(stage: .recognition, httpStatus: 200, errorCode: 6, reason: .permission),
         "baidu stage=recognition http=200 error_code=6 reason=permission"),
        (CloudFailureDetail(stage: .token, httpStatus: 401, reason: .invalidClient), "baidu stage=token http=401 reason=invalid_client"),
        (CloudFailureDetail(stage: .token, transportError: "URLError -1009"), "baidu stage=token transport=URLError -1009"),
        (CloudFailureDetail(stage: .recognition, httpStatus: 502, reason: .unreadableResponse),
         "baidu stage=recognition http=502 reason=unreadable_response"),
        (CloudFailureDetail(stage: .recognition, httpStatus: 0, errorCode: -1, reason: .other),
         "baidu stage=recognition http=0 error_code=-1 reason=other"),
        (CloudFailureDetail(stage: .recognition, errorCode: Int.max), "baidu stage=recognition error_code=\(Int.max)")
    ]
    for (detail, line) in rows {
        #expect(detail.logMessage == line)
        #expect(detail.logMessage.wholeMatch(of: pattern) != nil, "\(line)")
    }
}

@Test(.timeLimit(.minutes(2)))
func issue689bD2LogMessageIsClosedOverEveryDetail() throws {
    let pattern = try logPattern()
    // Law: every detail's line matches the closed pattern, fields in a fixed order, each present iff its property is.
    let reasons: [Reason?] = [nil] + Reason.allCases.map { $0 }
    for stage in [CloudFailureDetail.Stage.token, .recognition] {
        for http in [nil, 0, 200, 401, 599] as [Int?] {
            for code in [nil, -1, 0, 6, Int.max] as [Int?] {
                for reason in reasons {
                    for transport in [nil, "URLError -1009", "refused redirected", "Other"] as [String?] {
                        let line = CloudFailureDetail(stage: stage, httpStatus: http, errorCode: code, reason: reason,
                                                      transportError: transport).logMessage
                        if line.wholeMatch(of: pattern) == nil || line.contains("  ")
                            || line.contains(" http=") != (http != nil) || line.contains(" error_code=") != (code != nil)
                            || line.contains(" reason=") != (reason != nil)
                            || line.contains(" transport=") != (transport != nil) {
                            Issue.record("bad line: \(line.debugDescription)")
                        }
                    }
                }
            }
        }
    }
}

@Test(.timeLimit(.minutes(2)))
func issue689bD2ReasonIdsAreTheClosedAllowlist() throws {
    let id = try Regex("[a-z_]+")
    let ids = Reason.allCases.map(\.rawValue)
    #expect(Set(ids) == ["permission", "quota", "auth", "other", "invalid_request", "invalid_client", "invalid_grant",
                         "unauthorized_client", "unsupported_grant_type", "invalid_scope", "unreadable_response",
                         "no_words_result", "no_access_token"])
    #expect(ids.count == 13)
    #expect(ids.allSatisfy { $0.wholeMatch(of: id) != nil })
}

@Test(.timeLimit(.minutes(2)))
func issue689bD2DetailHasOnlyBoundedProperties() {
    let detail = CloudFailureDetail(stage: .token, httpStatus: 1, errorCode: 2, reason: .other, transportError: "x")
    #expect(Mirror(reflecting: detail).children.map(\.label) == ["stage", "httpStatus", "errorCode", "reason", "transportError"])
}

// MARK: - dev2: the provider's reason table

private let quotaCodes: Set<Int> = [17, 18, 19]
private let authCodes: Set<Int> = [100, 110, 111]

@Test(.timeLimit(.minutes(2)), arguments: [
    (6, Reason.permission, TextRecognitionError.cloudFailure),
    (17, .quota, .cloudQuota), (18, .quota, .cloudQuota), (19, .quota, .cloudQuota),
    (100, .auth, .cloudAuth), (110, .auth, .cloudAuth), (111, .auth, .cloudAuth),
    (0, .other, .cloudFailure), (-1, .other, .cloudFailure), (5, .other, .cloudFailure), (7, .other, .cloudFailure),
    (16, .other, .cloudFailure), (20, .other, .cloudFailure), (99, .other, .cloudFailure), (101, .other, .cloudFailure),
    (112, .other, .cloudFailure), (216100, .other, .cloudFailure), (282000, .other, .cloudFailure)
])
func issue689bD2RecognitionCodeReasonTable(code: Int, reason: Reason, error: TextRecognitionError) async throws {
    let (thrown, details) = try await run([token, try json(["error_code": code, "error_msg": "m"])])
    #expect(thrown == error)
    #expect(details == [CloudFailureDetail(stage: .recognition, httpStatus: 200, errorCode: code, reason: reason)])
}

@Test(.timeLimit(.minutes(2)))
func issue689bD2CodeReasonIsTotalOverASweep() async throws {
    // Law: every code gets a reason; it is permission/quota/auth exactly on {6}/{17,18,19}/{100,110,111}, else other,
    // and it agrees with the thrown error. The oracle is the two sets above, not the provider's table.
    let image = try pngImage()
    for code in Array(-5...320) + [Int(Int32.max), 216100, 282000] {
        let (thrown, details) = try await run([token, try json(["error_code": code, "error_msg": "m"])], image: image)
        let reason: Reason = code == 6 ? .permission : quotaCodes.contains(code) ? .quota : authCodes.contains(code) ? .auth : .other
        let error: TextRecognitionError = quotaCodes.contains(code) ? .cloudQuota : authCodes.contains(code) ? .cloudAuth : .cloudFailure
        if thrown != error || details != [CloudFailureDetail(stage: .recognition, httpStatus: 200, errorCode: code, reason: reason)] {
            Issue.record("code \(code): \(String(describing: thrown)) \(details)")
        }
    }
}

@Test(.timeLimit(.minutes(2)))
func issue689bD2RecognitionNonIntErrorCodeIsShapeless() async throws {
    let (thrown, details) = try await run([token, reply(#"{"error_code":"6","error_msg":"x"}"#)])
    #expect(thrown == .cloudFailure)
    #expect(details == [CloudFailureDetail(stage: .recognition, httpStatus: 200, reason: .noWordsResult)])
}

@Test(.timeLimit(.minutes(2)))
func issue689bD2TokenOAuthNameTable() async throws {
    let named: [(Any, Reason)] = [
        ("invalid_request", .invalidRequest), ("invalid_client", .invalidClient), ("invalid_grant", .invalidGrant),
        ("unauthorized_client", .unauthorizedClient), ("unsupported_grant_type", .unsupportedGrantType),
        ("invalid_scope", .invalidScope),
        ("INVALID_CLIENT", .other), ("invalid_client ", .other), ("invalid_client\nx", .other), ("permission", .other),
        ("quota", .other), ("no_access_token", .other), ("other", .other), ("", .other), (42, .other),
        (NSNull(), .other), (["invalid_grant"], .other)
    ]
    for (error, reason) in named {
        let (thrown, details) = try await run([try json(["error": error, "error_description": hostile], status: 401)],
                                              credentials: hostilePair)
        #expect(thrown == .cloudAuth, "\(error)")
        #expect(details == [CloudFailureDetail(stage: .token, httpStatus: 401, reason: reason)], "\(error)")
    }
}

@Test(.timeLimit(.minutes(2)))
func issue689bD2TokenErrorCodeWinsOverOAuthName() async throws {
    let rows: [([String: Any], Int?, Reason)] = [
        (["error": "invalid_client", "error_code": 17], 17, .quota),
        (["error_code": 110, "error_msg": "h"], 110, .auth),
        (["error_code": 4], 4, .other),
        (["error_code": 6, "error": "invalid_scope"], 6, .permission),
        (["error_code": "110", "error": "invalid_grant"], nil, .invalidGrant),
        (["error_code": "110"], nil, .other)
    ]
    for (body, code, reason) in rows {
        let (thrown, details) = try await run([try json(body)])
        #expect(thrown == .cloudAuth, "\(body)")
        #expect(details == [CloudFailureDetail(stage: .token, httpStatus: 200, errorCode: code, reason: reason)], "\(body)")
    }
}

@Test(.timeLimit(.minutes(2)))
func issue689bD2LocalShapeFailuresUseFixedIds() async throws {
    // Replaces dev1's issue689bUnreadableAndShapelessAnswersAreReported (fixed text → fixed ids).
    let rows: [([Result<HTTPResponse, any Error>], TextRecognitionError, CloudFailureDetail)] = [
        ([token, reply("<html>bad gateway</html>", status: 502)], .cloudFailure,
         CloudFailureDetail(stage: .recognition, httpStatus: 502, reason: .unreadableResponse)),
        ([reply("", status: 500)], .cloudFailure, CloudFailureDetail(stage: .token, httpStatus: 500, reason: .unreadableResponse)),
        ([token, reply(#"{"log_id":1}"#, status: 500)], .cloudFailure,
         CloudFailureDetail(stage: .recognition, httpStatus: 500, reason: .noWordsResult)),
        ([reply(#"{"expires_in":10}"#)], .cloudAuth, CloudFailureDetail(stage: .token, httpStatus: 200, reason: .noAccessToken)),
        ([reply(#"{"access_token":"","expires_in":10}"#)], .cloudAuth,
         CloudFailureDetail(stage: .token, httpStatus: 200, reason: .noAccessToken)),
        ([reply(#"{"error_msg":"图像 a+bAKD2"}"#)], .cloudAuth, CloudFailureDetail(stage: .token, httpStatus: 200, reason: .noAccessToken))
    ]
    for (replies, error, detail) in rows {
        let (thrown, details) = try await run(replies, credentials: hostilePair)
        #expect(thrown == error)
        #expect(details == [detail])
    }
}

@Test(.timeLimit(.minutes(2)))
func issue689bD2HostileServerTextNeverReachesDetailOrLog() async throws {
    let rows: [([Result<HTTPResponse, any Error>], String)] = [
        ([token, try json(["error_code": 216100, "error_msg": hostile])],
         "baidu stage=recognition http=200 error_code=216100 reason=other"),
        ([try json(["error": "invalid_client", "error_description": hostile], status: 401)],
         "baidu stage=token http=401 reason=invalid_client"),
        ([try json(["error": hostile], status: 401)], "baidu stage=token http=401 reason=other"),
        ([try json(["error_code": 4, "error_msg": hostile])], "baidu stage=token http=200 error_code=4 reason=other")
    ]
    for (replies, line) in rows {
        let (_, details) = try await run(replies, credentials: hostilePair)
        let detail = try #require(details.first)
        #expect(details.count == 1)
        #expect(detail.logMessage == line)
        expectNoServerText(detail)
    }
}

@Test(.timeLimit(.minutes(2)))
func issue689bD2LogMessageIgnoresServerText() async throws {
    // Law: the detail is a function of stage, status, code and the allowlisted name only; free text never changes it.
    let texts: [String?] = [nil, "", "a", "图像文字", "a+bAKD2", "TOKEN-abc-123", "\n", String(repeating: "x", count: 2000)]
    func body(_ fixed: [String: Any], _ key: String, _ text: String?) -> [String: Any] {
        var object = fixed
        if let text { object[key] = text }
        return object
    }
    let carriers: [(String?) throws -> [Result<HTTPResponse, any Error>]] = [
        { [token, try json(body(["error_code": 216100], "error_msg", $0))] },
        { [try json(body(["error": "invalid_client"], "error_description", $0), status: 401)] },
        { [try json(["error": $0 ?? "nonsense"], status: 401)] },
        { [try json(body(["error_code": 4], "error_msg", $0))] }
    ]
    for (index, carrier) in carriers.enumerated() {
        var seen: [CloudFailureDetail] = []
        for text in texts { seen += try await run(carrier(text), credentials: hostilePair).1 }
        #expect(seen.count == texts.count, "carrier \(index)")
        #expect(Set(seen.map(\.logMessage)).count == 1, "carrier \(index): \(Set(seen.map(\.logMessage)))")
        #expect(seen.allSatisfy { $0 == seen[0] }, "carrier \(index)")
    }
}
