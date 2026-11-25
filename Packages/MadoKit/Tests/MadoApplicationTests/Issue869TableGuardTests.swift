import Foundation
import Testing
@testable import MadoApplication

// #869 WI-2: every condition that stops a request sends nothing and says why (AC-2). The image is never downscaled.

private func isSent(_ result: TableRecognitionResult) -> Bool {
    if case .notSent = result { return false }
    return true
}

@Test(.timeLimit(.minutes(2)), arguments: [
    "cloudOff", "invalidEndpoint", "consentNotAsked", "consentDeclined", "consentHostChanged", "noAccessKey",
    "unsupportedImage", "imageTooLarge",
])
func issue869WI2EachGuardReasonSendsNothing(reason: String) async throws {
    var options = TableRecognitionOptions.default869
    var keys = FakeTableKeys869()
    var image = makePNG869(3, 2)
    let expected: TableRecognitionBlock
    switch reason {
    case "cloudOff": options = .options869(enabled: false); expected = .cloudOff
    case "invalidEndpoint":
        let endpoint = TableRecognitionEndpoint(preset: .deepSeek, baseURL: "http://api.deepseek.com", model: "deepseek-flash")
        options = .options869(endpoint: endpoint); keys = FakeTableKeys869([endpoint: "sk-1"]); expected = .invalidEndpoint
    case "consentNotAsked": options = .options869(consentHost: nil); expected = .consentNotAsked
    case "consentDeclined": options = .options869(granted: false); expected = .consentDeclined
    case "consentHostChanged": options = .options869(consentHost: "gw.example.com"); expected = .consentHostChanged
    case "noAccessKey": keys = FakeTableKeys869([:]); expected = .noAccessKey
    case "unsupportedImage": image = makeBMP869(2, 2); expected = .unsupportedImage
    default: image = makePNG869(8193, 1); expected = .imageTooLarge
    }
    let transport = RecordingTransport869()
    let result = await makeService869(settings: FakeTableSettings869(options), keys: keys, transport: transport)
        .recognise(image)
    #expect(result == .notSent(expected))
    #expect(await transport.callCount == 0)
}

@Test(.timeLimit(.minutes(2)), arguments: [
    (TableRecognitionPreset.deepSeek, "http://api.deepseek.com", "m", false),
    (.deepSeek, "api.deepseek.com", "m", false),
    (.deepSeek, "https://", "m", false),
    (.deepSeek, "https://user:pw@api.deepseek.com", "m", false),
    (.deepSeek, "https://user@api.deepseek.com", "m", false),
    (.deepSeek, "https://api.deepseek.com?x=1", "m", false),
    (.deepSeek, "https://api.deepseek.com?", "m", false),
    (.deepSeek, "https://api.deepseek.com/#frag", "m", false),
    (.deepSeek, "ftp://api.deepseek.com", "m", false),
    (.deepSeek, "", "m", false),
    (.custom, "https://api.deepseek.com", "", false),
    (.custom, "https://api.deepseek.com", "  ", false),
    (.custom, "https://api.deepseek.com:8443/v1", "m", true),
    (.deepSeek, "https://api.deepseek.com/", "m", true),
])
func issue869WI2InvalidEndpointDefects(preset: TableRecognitionPreset, base: String, model: String, valid: Bool) async {
    let endpoint = TableRecognitionEndpoint(preset: preset, baseURL: base, model: model)
    let transport = RecordingTransport869()
    let result = await makeService869(settings: FakeTableSettings869(.options869(endpoint: endpoint)),
                                      keys: FakeTableKeys869([endpoint: "sk-1"]), transport: transport)
        .recognise(makePNG869(3, 2))
    if valid {
        #expect(isSent(result), "\(base)")
        #expect(await transport.callCount == 1, "\(base)")
    } else {
        #expect(result == .notSent(.invalidEndpoint), "\(base) model \(model)")
        #expect(await transport.callCount == 0, "\(base)")
    }
}

@Test(.timeLimit(.minutes(2)))
func issue869WI2NoEndpointIsInvalid() async {
    let transport = RecordingTransport869()
    let result = await makeService869(settings: FakeTableSettings869(.options869(endpoint: nil)), transport: transport)
        .recognise(makePNG869(3, 2))
    #expect(result == .notSent(.invalidEndpoint))
    #expect(await transport.callCount == 0)
}

@Test(.timeLimit(.minutes(2)))
func issue869WI2UnsupportedImageFormats() async {
    var rng = SplitMix869(seed: 0x0869_0002)
    let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    let samples: [(String, Data)] = [
        ("empty", Data()),
        ("one byte", Data([0x89])),
        ("png signature only", pngSignature),
        ("png signature + noise", pngSignature + Data((0..<100).map { _ in UInt8(truncatingIfNeeded: rng.next()) })),
        ("jpeg signature + zeros", Data([0xFF, 0xD8, 0xFF]) + Data(count: 64)),
        ("gif signature only", Data("GIF89a".utf8)),
        ("riff wave", Data("RIFF".utf8) + Data([0, 0, 0, 0]) + Data("WAVE".utf8)),
        ("bmp", makeBMP869(2, 2)),
        ("tiff", makeTIFF869(2, 2)),
        ("pdf", Data("%PDF-1.4\n".utf8)),
        ("wide bmp", makeBMP869(8193, 1)),
    ]
    for (name, data) in samples {
        let transport = RecordingTransport869()
        let result = await makeService869(transport: transport).recognise(data)
        #expect(result == .notSent(.unsupportedImage), "\(name)")
        #expect(await transport.callCount == 0, "\(name)")
    }
}

@Test(.timeLimit(.minutes(2)), arguments: [
    (8192, 1, TableRecognitionPreset.deepSeek, true), (1, 8192, .deepSeek, true), (8193, 1, .deepSeek, false),
    (1, 8193, .deepSeek, false), (8193, 1, .custom, false), (8192, 1, .custom, true),
])
func issue869WI2DimensionBoundaries(width: Int, height: Int, preset: TableRecognitionPreset, sent: Bool) async {
    let endpoint = preset == .deepSeek ? TableRecognitionEndpoint.deepSeekDefault869 : .custom869()
    let host = preset == .deepSeek ? "api.deepseek.com" : "gw.example.com"
    let transport = RecordingTransport869()
    let result = await makeService869(settings: FakeTableSettings869(.options869(endpoint: endpoint, consentHost: host)),
                                      keys: FakeTableKeys869([endpoint: "sk-1"]), transport: transport)
        .recognise(makePNG869(width, height))
    if sent {
        #expect(isSent(result))
        #expect(await transport.callCount == 1)
    } else {
        #expect(result == .notSent(.imageTooLarge))
        #expect(await transport.callCount == 0)
    }
}

/// The largest image whose base64 fits DeepSeek's 32 MiB: 25,165,824 bytes → exactly 33,554,432 characters.
@Test(.timeLimit(.minutes(2)))
func issue869WI2LargestRawSizeIsSent() async throws {
    var image = makePNG869(4, 4)
    image.append(Data(count: 25_165_824 - image.count))
    #expect(image.count == 25_165_824)
    let transport = RecordingTransport869()
    let result = await makeService869(transport: transport).recognise(image)
    #expect(isSent(result))
    #expect(await transport.callCount == 1)
    let request = try #require(await transport.requests.first)
    let payload = try #require(payload869(request))
    #expect(payload.base64.utf8.count == 33_554_432)
    #expect(Data(base64Encoded: payload.base64) == image)
}

@Test(.timeLimit(.minutes(2)))
func issue869WI2OneByteOverRawSizeIsRefused() async {
    var image = makePNG869(4, 4)
    image.append(Data(count: 25_165_825 - image.count))
    let deepSeek = RecordingTransport869()
    #expect(await makeService869(transport: deepSeek).recognise(image) == .notSent(.imageTooLarge))
    #expect(await deepSeek.callCount == 0)
    let endpoint = TableRecognitionEndpoint.custom869()
    let custom = RecordingTransport869()
    let result = await makeService869(settings: FakeTableSettings869(.options869(endpoint: endpoint, consentHost: "gw.example.com")),
                                      keys: FakeTableKeys869([endpoint: "sk-1"]), transport: custom).recognise(image)
    #expect(result == .notSent(.imageTooLarge))
    #expect(await custom.callCount == 0)
}

@Test(.timeLimit(.minutes(2)), arguments: [
    ("API.DeepSeek.COM", "https://api.deepseek.com", true),
    ("api.deepseek.com", "https://API.DEEPSEEK.COM", true),
    ("api.deepseek.com", "https://api.deepseek.com:8443", true),
    ("api.deepseek.com", "https://api.deepseek.com.", true),
    ("api.deepseek.com.", "https://api.deepseek.com", true),
    ("api.deepseek.com", "https://api.deepseek.com..", false),
    ("deepseek.com", "https://api.deepseek.com", false),
    ("api.deepseek.com", "https://api.deepseek.com.evil.example", false),
])
func issue869WI2ConsentHostComparison(consentHost: String, base: String, sent: Bool) async {
    let endpoint = TableRecognitionEndpoint(preset: .deepSeek, baseURL: base, model: "deepseek-flash")
    let transport = RecordingTransport869()
    let result = await makeService869(settings: FakeTableSettings869(.options869(endpoint: endpoint, consentHost: consentHost)),
                                      keys: FakeTableKeys869([endpoint: "sk-1"]), transport: transport)
        .recognise(makePNG869(3, 2))
    if sent {
        #expect(isSent(result), "\(consentHost) / \(base)")
        #expect(await transport.callCount == 1)
    } else {
        #expect(result == .notSent(.consentHostChanged), "\(consentHost) / \(base)")
        #expect(await transport.callCount == 0)
    }
}

@Test(.timeLimit(.minutes(2)), arguments: [true, false])
func issue869WI2RecordForOtherHostIsHostChanged(granted: Bool) async {
    let transport = RecordingTransport869()
    let result = await makeService869(settings: FakeTableSettings869(.options869(consentHost: "gw.example.com", granted: granted)),
                                      transport: transport).recognise(makePNG869(3, 2))
    #expect(result == .notSent(.consentHostChanged))
    #expect(await transport.callCount == 0)
}

@Test(.timeLimit(.minutes(2)), arguments: ["nil", "", "   ", "\n\t", "otherEndpoint"])
func issue869WI2NoAccessKeyVariants(variant: String) async {
    var options = TableRecognitionOptions.default869
    let keys: FakeTableKeys869
    switch variant {
    case "nil": keys = FakeTableKeys869([:])
    case "otherEndpoint":
        options = .options869(endpoint: .custom869(), consentHost: "gw.example.com")
        keys = FakeTableKeys869([TableRecognitionEndpoint.deepSeekDefault869: "sk-ds"])
    default: keys = FakeTableKeys869([TableRecognitionEndpoint.deepSeekDefault869: variant])
    }
    let transport = RecordingTransport869()
    let result = await makeService869(settings: FakeTableSettings869(options), keys: keys, transport: transport)
        .recognise(makePNG869(3, 2))
    #expect(result == .notSent(.noAccessKey), "\(variant)")
    #expect(await transport.callCount == 0)
}

/// Every combination of the guard inputs: the first failing guard in the documented order wins, nothing is sent,
/// and the key is not even read when the switch, the endpoint or the consent already stops the request.
@Test(.timeLimit(.minutes(2)))
func issue869WI2FirstFailingGuardWinsAcrossAllCombinations() async {
    let good = makePNG869(3, 2), bmp = makeBMP869(2, 2), wide = makePNG869(8193, 1)
    let valid = TableRecognitionEndpoint.deepSeekDefault869
    let invalid = TableRecognitionEndpoint(preset: .deepSeek, baseURL: "http://api.deepseek.com", model: "deepseek-flash")
    for enabled in [true, false] {
        for endpointValid in [true, false] {
            for consent in ["granted", "nil", "declined", "otherHost"] {
                for hasKey in [true, false] {
                    for image in ["good", "bmp", "wide"] {
                        let endpoint = endpointValid ? valid : invalid
                        let record: TableRecognitionConsentRecord? = switch consent {
                        case "granted": TableRecognitionConsentRecord(host: "api.deepseek.com", granted: true)
                        case "declined": TableRecognitionConsentRecord(host: "api.deepseek.com", granted: false)
                        case "otherHost": TableRecognitionConsentRecord(host: "gw.example.com", granted: true)
                        default: nil
                        }
                        let options = TableRecognitionOptions(cloudEnabled: enabled, endpoint: endpoint, consent: record)
                        let keys = FakeTableKeys869(hasKey ? [endpoint: "sk-1"] : [:])
                        let transport = RecordingTransport869()
                        let data = image == "good" ? good : image == "bmp" ? bmp : wide
                        let result = await makeService869(settings: FakeTableSettings869(options), keys: keys,
                                                          transport: transport).recognise(data)
                        let expected: TableRecognitionBlock? =
                            !enabled ? .cloudOff
                            : !endpointValid ? .invalidEndpoint
                            : consent == "nil" ? .consentNotAsked
                            : consent == "declined" ? .consentDeclined
                            : consent == "otherHost" ? .consentHostChanged
                            : !hasKey ? .noAccessKey
                            : image == "bmp" ? .unsupportedImage
                            : image == "wide" ? .imageTooLarge
                            : nil
                        let label = "\(enabled) \(endpointValid) \(consent) \(hasKey) \(image)"
                        if let expected {
                            #expect(result == .notSent(expected), "\(label)")
                            #expect(await transport.callCount == 0, "\(label)")
                        } else {
                            #expect(isSent(result), "\(label)")
                            #expect(await transport.callCount == 1, "\(label)")
                        }
                        let readsKey = enabled && endpointValid && consent == "granted"
                        #expect(await keys.readCount == (readsKey ? 1 : 0), "key reads: \(label)")
                    }
                }
            }
        }
    }
}

@Test(.timeLimit(.minutes(2)))
func issue869WI2BlockDescriptionsRedactSecrets() async {
    let secretBase = TableRecognitionEndpoint(preset: .deepSeek, baseURL: "https://user:s3cr3t-pw@api.deepseek.com",
                                              model: "deepseek-flash")
    var results = [await makeService869(settings: FakeTableSettings869(.options869(endpoint: secretBase)),
                                        keys: FakeTableKeys869([secretBase: "sk-SECRET-869"])).recognise(makePNG869(3, 2))]
    let secretKeys = FakeTableKeys869([TableRecognitionEndpoint.deepSeekDefault869: "sk-SECRET-869"])
    for options in [TableRecognitionOptions.options869(enabled: false), .options869(consentHost: nil),
                    .options869(granted: false), .options869(consentHost: "gw.example.com")] {
        results.append(await makeService869(settings: FakeTableSettings869(options), keys: secretKeys).recognise(makePNG869(3, 2)))
    }
    results.append(await makeService869(keys: secretKeys).recognise(makeBMP869(2, 2)))
    results.append(await makeService869(keys: secretKeys).recognise(makePNG869(8193, 1)))
    for result in results {
        var dumped = ""
        dump(result, to: &dumped)
        for text in [String(describing: result), String(reflecting: result), dumped] {
            #expect(!text.contains("s3cr3t-pw") && !text.contains("sk-SECRET-869"), "\(text)")
        }
    }
}
