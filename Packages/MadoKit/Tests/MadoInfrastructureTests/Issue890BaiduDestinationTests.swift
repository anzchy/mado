import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
import MadoApplication
@testable import MadoInfrastructure

// #890 WI-1: the Baidu provider names Baidu's fixed destination on both its requests.

private actor Destinations890: HTTPTransport {
    private(set) var seen: [HTTPDestination] = []
    private var bodies = [#"{"access_token":"TOKEN","expires_in":120}"#, #"{"words_result":[{"words":"hi"}]}"#]
    func send(_ request: URLRequest, to destination: HTTPDestination) async throws -> HTTPResponse {
        seen.append(destination)
        return HTTPResponse(statusCode: 200, body: Data(bodies.removeFirst().utf8))
    }
}

func png890(width: Int = 20, height: Int = 20) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

@Test(.timeLimit(.minutes(2)))
func issue890WI1BaiduNamesItsFixedDestination() async throws {
    let transport = Destinations890()
    let text = try await BaiduTextRecognitionProvider(transport: transport)
        .recognise(try png890(), credentials: CloudCredentials(apiKey: "api", secretKey: "secret"))
    #expect(text == "hi")
    #expect(await transport.seen == [.baiduOCR, .baiduOCR])
}
