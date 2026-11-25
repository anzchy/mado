import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import MadoApplication

// Shared fakes and synthetic fixtures for the #869 table recognition tests. No real keys, no real images.

/// Records every request and answers from a script; optionally holds each call at a gate the test opens.
actor RecordingTransport869: HTTPTransport {
    enum Reply: Sendable { case response(HTTPResponse), failure(any Error) }
    private var script: [Reply]
    private let fallback: Reply
    private(set) var requests: [URLRequest] = []
    private let gated: Bool
    private var gate: CheckedContinuation<Void, Never>?
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var hasEntered = false

    init(_ script: [Reply] = [], fallback: Reply = .response(goodReply869()), gated: Bool = false) {
        self.script = script
        self.fallback = fallback
        self.gated = gated
    }

    var callCount: Int { requests.count }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        if gated {
            await withCheckedContinuation { continuation in
                gate = continuation
                hasEntered = true
                enteredWaiter?.resume()
                enteredWaiter = nil
            }
        }
        let reply = script.isEmpty ? fallback : script.removeFirst()
        switch reply {
        case .response(let response): return response
        case .failure(let error): throw error
        }
    }

    var didEnter: Bool { hasEntered }

    /// Waits until a call is held at the gate.
    func entered() async {
        if hasEntered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }

    func open() { gate?.resume(); gate = nil }
}

/// Settings whose answer the test can change between calls, and optionally hold until the test opens a gate.
actor FakeTableSettings869: TableRecognitionSettings {
    var current: TableRecognitionOptions
    private let gated: Bool
    private var gate: CheckedContinuation<Void, Never>?
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var hasEntered = false

    init(_ options: TableRecognitionOptions = .default869, gated: Bool = false) {
        current = options
        self.gated = gated
    }

    func set(_ options: TableRecognitionOptions) { current = options }

    func options() async -> TableRecognitionOptions {
        if gated {
            await withCheckedContinuation { continuation in
                gate = continuation
                hasEntered = true
                enteredWaiter?.resume()
                enteredWaiter = nil
            }
        }
        return current
    }

    func entered() async {
        if hasEntered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }

    func open() { gate?.resume(); gate = nil }
}

/// Keys per endpoint; counts reads, and can hold a read until the test opens a gate.
actor FakeTableKeys869: TableRecognitionCredentialStore {
    private var keys: [TableRecognitionEndpoint: String]
    private(set) var readCount = 0
    private let gated: Bool
    private var gate: CheckedContinuation<Void, Never>?
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var hasEntered = false

    init(_ keys: [TableRecognitionEndpoint: String] = [TableRecognitionEndpoint.deepSeekDefault869: "sk-test-ds-0001"],
         gated: Bool = false) {
        self.keys = keys
        self.gated = gated
    }

    func set(_ key: String?, for endpoint: TableRecognitionEndpoint) { keys[endpoint] = key }

    func accessKey(for endpoint: TableRecognitionEndpoint) async -> String? {
        readCount += 1
        if gated {
            await withCheckedContinuation { continuation in
                gate = continuation
                hasEntered = true
                enteredWaiter?.resume()
                enteredWaiter = nil
            }
        }
        return keys[endpoint]
    }

    func entered() async {
        if hasEntered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }

    func open() { gate?.resume(); gate = nil }
}

extension TableRecognitionEndpoint {
    static let deepSeekDefault869 = TableRecognitionEndpoint(preset: .deepSeek, baseURL: "https://api.deepseek.com",
                                                             model: "deepseek-flash")
    static func custom869(_ base: String = "https://gw.example.com/v1", model: String = "vision-x") -> Self {
        TableRecognitionEndpoint(preset: .custom, baseURL: base, model: model)
    }
}

extension TableRecognitionOptions {
    static let default869 = TableRecognitionOptions(cloudEnabled: true, endpoint: .deepSeekDefault869,
                                                    consent: TableRecognitionConsentRecord(host: "api.deepseek.com",
                                                                                           granted: true))
    static func options869(enabled: Bool = true, endpoint: TableRecognitionEndpoint? = .deepSeekDefault869,
                           consentHost: String? = "api.deepseek.com", granted: Bool = true) -> Self {
        TableRecognitionOptions(cloudEnabled: enabled, endpoint: endpoint,
                                consent: consentHost.map { TableRecognitionConsentRecord(host: $0, granted: granted) })
    }
}

func makeService869(settings: FakeTableSettings869 = FakeTableSettings869(),
                    keys: FakeTableKeys869 = FakeTableKeys869(),
                    transport: RecordingTransport869 = RecordingTransport869()) -> TableRecognitionService {
    TableRecognitionService(settings: settings, credentials: keys, transport: transport)
}

// MARK: - Replies

func chatReply869(content: String?, finish: String? = "stop") -> Data {
    let message: [String: Any] = ["role": "assistant", "content": content.map { $0 as Any } ?? NSNull()]
    let choice: [String: Any] = ["index": 0, "message": message, "finish_reason": finish.map { $0 as Any } ?? NSNull()]
    return try! JSONSerialization.data(withJSONObject: ["choices": [choice]])
}

let goodTable869 = "| A | B |\n|---|---|\n| 1 | 2 |"
func goodReply869(status: Int = 200) -> HTTPResponse {
    HTTPResponse(statusCode: status, body: chatReply869(content: goodTable869))
}
func reply869(_ status: Int, _ body: String) -> RecordingTransport869.Reply {
    .response(HTTPResponse(statusCode: status, body: Data(body.utf8)))
}

// MARK: - Request inspection

func bodyObject869(_ request: URLRequest) -> [String: Any] {
    guard let body = request.httpBody,
          let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [:] }
    return object
}

func contentParts869(_ request: URLRequest) -> [[String: Any]] {
    let messages = bodyObject869(request)["messages"] as? [[String: Any]]
    return messages?.first?["content"] as? [[String: Any]] ?? []
}

/// The data URL's media type and base64 payload.
func payload869(_ request: URLRequest) -> (mediaType: String, base64: String)? {
    guard let part = contentParts869(request).first(where: { $0["type"] as? String == "image_url" }),
          let imageURL = part["image_url"] as? [String: Any], let url = imageURL["url"] as? String,
          url.hasPrefix("data:"), let semicolon = url.firstIndex(of: ";"),
          let comma = url.firstIndex(of: ",") else { return nil }
    let mediaType = String(url[url.index(url.startIndex, offsetBy: 5)..<semicolon])
    return (mediaType, String(url[url.index(after: comma)...]))
}

func promptText869(_ request: URLRequest) -> String? {
    contentParts869(request).first(where: { $0["type"] as? String == "text" })?["text"] as? String
}

/// Every key at any depth of a decoded JSON tree.
func allKeys869(_ value: Any) -> Set<String> {
    if let dictionary = value as? [String: Any] {
        return dictionary.reduce(into: Set(dictionary.keys)) { $0.formUnion(allKeys869($1.value)) }
    }
    if let array = value as? [Any] { return array.reduce(into: Set<String>()) { $0.formUnion(allKeys869($1)) } }
    return []
}

func isJSONBool869(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber else { return false }
    return CFGetTypeID(number) == CFBooleanGetTypeID()
}

// MARK: - Images

private func image869(width: Int, height: Int, seed: UInt64) -> CGImage {
    var rng = SplitMix869(seed: seed)
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for index in stride(from: 0, to: pixels.count, by: 4) {
        pixels[index] = UInt8(truncatingIfNeeded: rng.next())
        pixels[index + 1] = UInt8(truncatingIfNeeded: rng.next())
        pixels[index + 2] = UInt8(truncatingIfNeeded: rng.next())
    }
    let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    return context.makeImage()!
}

func encode869(_ image: CGImage, type: UTType) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination))
    return data as Data
}

func makePNG869(_ width: Int, _ height: Int, seed: UInt64 = 1) -> Data {
    encode869(image869(width: width, height: height, seed: seed), type: .png)
}
func makeJPEG869(_ width: Int, _ height: Int, seed: UInt64 = 1) -> Data {
    encode869(image869(width: width, height: height, seed: seed), type: .jpeg)
}
func makeGIF869(_ width: Int, _ height: Int, seed: UInt64 = 1) -> Data {
    encode869(image869(width: width, height: height, seed: seed), type: .gif)
}
func makeBMP869(_ width: Int, _ height: Int) -> Data { encode869(image869(width: width, height: height, seed: 2), type: .bmp) }
func makeTIFF869(_ width: Int, _ height: Int) -> Data { encode869(image869(width: width, height: height, seed: 3), type: .tiff) }

/// A 1×1 lossless WebP (synthetic, 26 bytes after the RIFF header).
let webp1x1_869 = Data([
    0x52, 0x49, 0x46, 0x46, 0x1A, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x4C,
    0x0D, 0x00, 0x00, 0x00, 0x2F, 0x00, 0x00, 0x00, 0x10, 0x07, 0x10, 0x11, 0x11, 0x88, 0x88, 0xFE,
    0x07, 0x00,
])

func pixelSize869(_ data: Data) -> (Int, Int)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return (width, height)
}

// MARK: - Seeded randomness

struct SplitMix869: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

actor Flag869 {
    private(set) var value = false
    func set() { value = true }
}

/// Waits until the transport holds a call, or the task has finished without sending; true when a call is held.
func awaitHeldSend869<T: Sendable>(_ transport: RecordingTransport869, _ task: Task<T, Never>) async -> Bool {
    let done = Flag869()
    Task { _ = await task.value; await done.set() }
    while await !transport.didEnter {
        if await done.value { return false }
        await Task.yield()
    }
    return true
}
