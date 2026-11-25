import Foundation
import Testing
@testable import MadoApplication

// #869 WI-1: the request each preset sends (AC-1). The reply side is WI-3..WI-5; here only what goes out is checked.

private let deepSeekKeys: Set<String> = ["model", "messages", "thinking", "temperature", "stream"]
private let customKeys: Set<String> = ["model", "messages", "stream"]

@Test(.timeLimit(.minutes(2)))
func issue869WI1DeepSeekRequestExactShape() async throws {
    let transport = RecordingTransport869()
    let png = makePNG869(3, 2)
    let result = await makeService869(transport: transport).recognise(png)

    #expect(result == .table(rows: [["A", "B"], ["1", "2"]]))
    #expect(await transport.callCount == 1)
    let request = try #require(await transport.requests.first)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.absoluteString == "https://api.deepseek.com/chat/completions")
    #expect(request.allHTTPHeaderFields == ["Authorization": "Bearer sk-test-ds-0001",
                                            "Content-Type": "application/json"])
    let body = bodyObject869(request)
    #expect(Set(body.keys) == deepSeekKeys)
    #expect(body["model"] as? String == "deepseek-flash")
    #expect((body["thinking"] as? [String: Any])?.count == 1)
    #expect((body["thinking"] as? [String: Any])?["type"] as? String == "disabled")
    #expect(!isJSONBool869(body["temperature"]))
    #expect((body["temperature"] as? NSNumber)?.doubleValue == 0)
    #expect(isJSONBool869(body["stream"]) && (body["stream"] as? Bool) == false)

    let messages = try #require(body["messages"] as? [[String: Any]])
    #expect(messages.count == 1)
    #expect(Set(messages[0].keys) == ["role", "content"])
    #expect(messages[0]["role"] as? String == "user")
    let parts = contentParts869(request)
    #expect(parts.count == 2)
    #expect(parts.map { $0["type"] as? String } == ["text", "image_url"])
    #expect(Set(parts[0].keys) == ["type", "text"])
    let image = try #require(parts[1]["image_url"] as? [String: Any])
    #expect(Set(image.keys) == ["url", "detail"])
    #expect(image["detail"] as? String == "original")
    #expect(image["url"] as? String == "data:image/png;base64," + png.base64EncodedString())
}

@Test(.timeLimit(.minutes(2)))
func issue869WI1CustomRequestCarriesOnlyStandardFields() async throws {
    let endpoint = TableRecognitionEndpoint.custom869("https://gw.example.com:8443/v1/", model: "vision-x \"q\" 中")
    let settings = FakeTableSettings869(.options869(endpoint: endpoint, consentHost: "gw.example.com"))
    let transport = RecordingTransport869()
    let png = makePNG869(3, 2)
    let result = await makeService869(settings: settings, keys: FakeTableKeys869([endpoint: "sk-custom-ä"]),
                                      transport: transport).recognise(png)

    #expect(result == .table(rows: [["A", "B"], ["1", "2"]]))
    #expect(await transport.callCount == 1)
    let request = try #require(await transport.requests.first)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.absoluteString == "https://gw.example.com:8443/v1/chat/completions")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-custom-ä")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let body = bodyObject869(request)
    #expect(Set(body.keys) == customKeys)
    #expect(body["model"] as? String == "vision-x \"q\" 中")
    #expect(isJSONBool869(body["stream"]) && (body["stream"] as? Bool) == false)
    let walked = allKeys869(body)
    #expect(!walked.contains("thinking") && !walked.contains("temperature") && !walked.contains("detail"))
    let parts = contentParts869(request)
    #expect(parts.map { $0["type"] as? String } == ["text", "image_url"])
    let image = try #require(parts[1]["image_url"] as? [String: Any])
    #expect(Set(image.keys) == ["url"])
    #expect(image["url"] as? String == "data:image/png;base64," + png.base64EncodedString())
}

@Test(.timeLimit(.minutes(2)), arguments: [
    ("png", "image/png"), ("jpeg", "image/jpeg"), ("gif", "image/gif"), ("webp", "image/webp"),
])
func issue869WI1DataURLMediaTypeFromMagicBytes(format: String, mediaType: String) async throws {
    let image: Data = switch format {
    case "png": makePNG869(4, 3)
    case "jpeg": makeJPEG869(4, 3)
    case "gif": makeGIF869(4, 3)
    default: webp1x1_869
    }
    if format == "webp" {
        let size = try #require(pixelSize869(image), "ImageIO must read the WebP fixture")
        #expect(size == (1, 1))
    }
    let transport = RecordingTransport869()
    _ = await makeService869(transport: transport).recognise(image)
    #expect(await transport.callCount == 1)
    let request = try #require(await transport.requests.first)
    let payload = try #require(payload869(request))
    #expect(payload.mediaType == mediaType)
    #expect(Data(base64Encoded: payload.base64) == image)
}

@Test(.timeLimit(.minutes(2)))
func issue869WI1ImageBytesRoundTripThroughDataURL() async throws {
    let seed: UInt64 = 0x0869_0001
    var rng = SplitMix869(seed: seed)
    let transport = RecordingTransport869()
    let service = makeService869(transport: transport)
    for iteration in 0..<40 {
        let width = Int(rng.next() % 64) + 1, height = Int(rng.next() % 64) + 1
        let pixelSeed = rng.next()
        var image: Data
        switch rng.next() % 3 {
        case 0: image = makeJPEG869(width, height, seed: pixelSeed)
        case 1: image = makeGIF869(width, height, seed: pixelSeed)
        default:
            image = makePNG869(width, height, seed: pixelSeed)
            image.append(contentsOf: (0..<Int(rng.next() % 257)).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
        }
        _ = await service.recognise(image)
        #expect(await transport.callCount == iteration + 1, "seed \(seed) iteration \(iteration)")
        let request = try #require(await transport.requests.last)
        let payload = try #require(payload869(request), "seed \(seed) iteration \(iteration)")
        #expect(Data(base64Encoded: payload.base64) == image, "seed \(seed) iteration \(iteration)")
    }
}

@Test(.timeLimit(.minutes(2)))
func issue869WI1BaseTrailingSlashesJoinCleanly() async throws {
    let png = makePNG869(3, 2)
    for authority in ["api.deepseek.com", "gw.example.com:8443"] {
        for path in ["", "/v1", "/a/b"] {
            for preset in [TableRecognitionPreset.deepSeek, .custom] {
                for slashes in 0...3 {
                    let base = "https://" + authority + path + String(repeating: "/", count: slashes)
                    let endpoint = TableRecognitionEndpoint(preset: preset, baseURL: base, model: "m-1")
                    let host = String(authority.split(separator: ":")[0])
                    let transport = RecordingTransport869()
                    _ = await makeService869(settings: FakeTableSettings869(.options869(endpoint: endpoint, consentHost: host)),
                                             keys: FakeTableKeys869([endpoint: "sk-1"]),
                                             transport: transport).recognise(png)
                    let url = await transport.requests.first?.url
                    #expect(url?.absoluteString == "https://" + authority + path + "/chat/completions", "\(base) \(preset)")
                    #expect(url?.path.contains("//") == false, "\(base)")
                }
            }
        }
    }
}

@Test(.timeLimit(.minutes(2)))
func issue869WI1PromptStatesTheRules() async throws {
    let deepSeek = RecordingTransport869()
    _ = await makeService869(transport: deepSeek).recognise(makePNG869(3, 2))
    let endpoint = TableRecognitionEndpoint.custom869()
    let custom = RecordingTransport869()
    _ = await makeService869(settings: FakeTableSettings869(.options869(endpoint: endpoint, consentHost: "gw.example.com")),
                             keys: FakeTableKeys869([endpoint: "sk-2"]), transport: custom).recognise(makePNG869(3, 2))
    let deepSeekPrompt = try #require(await deepSeek.requests.first.flatMap(promptText869))
    let customPrompt = try #require(await custom.requests.first.flatMap(promptText869))
    // 「第一行是表头」 is kept on purpose: the owner decided 「第一行当表头，面板里可切换」, so the prompt asks for a
    // header row and the panel (#875) lets the user switch it off.
    for rule in ["Markdown 表格", "逐字照抄", "第一行是表头", "才用 `<br>` 分隔", "不要代码围栏", "不要任何解释"] {
        #expect(deepSeekPrompt.contains(rule), "missing \(rule)")
    }
    #expect(deepSeekPrompt == customPrompt)
    #expect(!deepSeekPrompt.contains("base64,"))
}

@Test(.timeLimit(.minutes(2)))
func issue869WI1SendsOnlyCurrentEndpointsKey() async throws {
    let custom = TableRecognitionEndpoint.custom869()
    let keys = FakeTableKeys869([TableRecognitionEndpoint.deepSeekDefault869: "sk-ds-AAAA", custom: "sk-cu-BBBB"])
    let settings = FakeTableSettings869(.options869(endpoint: custom, consentHost: "gw.example.com"))
    let transport = RecordingTransport869()
    let service = makeService869(settings: settings, keys: keys, transport: transport)

    _ = await service.recognise(makePNG869(3, 2))
    await settings.set(.default869)
    _ = await service.recognise(makePNG869(3, 2))

    let requests = await transport.requests
    #expect(requests.count == 2)
    guard requests.count == 2 else { return }
    func text(_ request: URLRequest) -> String {
        "\(request.allHTTPHeaderFields ?? [:])" + String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    }
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer sk-cu-BBBB")
    #expect(!text(requests[0]).contains("sk-ds-AAAA"))
    #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer sk-ds-AAAA")
    #expect(!text(requests[1]).contains("sk-cu-BBBB"))
}

@Test(.timeLimit(.minutes(2)))
func issue869WI1TrimmedKeyIsSent() async throws {
    let transport = RecordingTransport869()
    _ = await makeService869(keys: FakeTableKeys869([TableRecognitionEndpoint.deepSeekDefault869: "  sk-trim-1\n"]),
                             transport: transport).recognise(makePNG869(3, 2))
    let request = try #require(await transport.requests.first)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-trim-1")
}

@Test(.timeLimit(.minutes(2)), arguments: [("deepseek-chat", "deepseek-chat"), ("", "deepseek-flash"),
                                            ("  ", "deepseek-flash")])
func issue869WI1DeepSeekModelHonouredOrDefaulted(configured: String, sent: String) async throws {
    let endpoint = TableRecognitionEndpoint(preset: .deepSeek, baseURL: "https://api.deepseek.com", model: configured)
    let transport = RecordingTransport869()
    _ = await makeService869(settings: FakeTableSettings869(.options869(endpoint: endpoint)),
                             keys: FakeTableKeys869([endpoint: "sk-1"]), transport: transport).recognise(makePNG869(3, 2))
    #expect(await transport.callCount == 1)
    let request = try #require(await transport.requests.first)
    #expect(bodyObject869(request)["model"] as? String == sent)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-1")
}

@Test(.timeLimit(.minutes(2)), arguments: ["newKey", "switchOff", "consentDeclined"])
func issue869WI2SettingsAndKeyReadFreshEachCall(change: String) async throws {
    let endpoint = TableRecognitionEndpoint.deepSeekDefault869
    let settings = FakeTableSettings869()
    let keys = FakeTableKeys869([endpoint: "sk-old"])
    let transport = RecordingTransport869()
    let service = makeService869(settings: settings, keys: keys, transport: transport)
    _ = await service.recognise(makePNG869(3, 2))
    #expect(await transport.callCount == 1)

    switch change {
    case "newKey": await keys.set("sk-new", for: endpoint)
    case "switchOff": await settings.set(.options869(enabled: false))
    default: await settings.set(.options869(granted: false))
    }
    let second = await service.recognise(makePNG869(3, 2))
    let requests = await transport.requests
    switch change {
    case "newKey":
        #expect(requests.count == 2)
        let request = try #require(requests.last)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-new")
        let text = "\(request.allHTTPHeaderFields ?? [:])" + String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(!text.contains("sk-old"))
    case "switchOff":
        #expect(second == .notSent(.cloudOff))
        #expect(requests.count == 1)
    default:
        #expect(second == .notSent(.consentDeclined))
        #expect(requests.count == 1)
    }
}

// Fix round 1 (opus L9): the model name is trimmed like the key; a blank DeepSeek model falls back to the default.
@Test(.timeLimit(.minutes(2)), arguments: [
    (TableRecognitionEndpoint(preset: .deepSeek, baseURL: "https://api.deepseek.com", model: "  deepseek-chat \n"),
     "api.deepseek.com", "deepseek-chat"),
    (TableRecognitionEndpoint(preset: .deepSeek, baseURL: "https://api.deepseek.com", model: " \t\n"),
     "api.deepseek.com", "deepseek-flash"),
    (TableRecognitionEndpoint.custom869(model: "\tvision-x  "), "gw.example.com", "vision-x"),
])
func issue869Fix1ModelNameIsTrimmed(endpoint: TableRecognitionEndpoint, host: String, sent: String) async throws {
    let transport = RecordingTransport869()
    let result = await makeService869(settings: FakeTableSettings869(.options869(endpoint: endpoint, consentHost: host)),
                                      keys: FakeTableKeys869([endpoint: "sk-trim-model"]), transport: transport)
        .recognise(makePNG869(3, 2))
    #expect(result == .table(rows: [["A", "B"], ["1", "2"]]))
    let request = try #require(await transport.requests.first)
    #expect(bodyObject869(request)["model"] as? String == sent)
}
