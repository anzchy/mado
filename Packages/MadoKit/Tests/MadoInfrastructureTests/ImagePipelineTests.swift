import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import MadoCore
import MadoInfrastructure

private struct ThreadProbeDecoder: ImageDecoding {
    enum Failure: Error { case ranOnMainThread, wrongExecutor }
    func decode(_ request: ImageDecodeRequest) throws -> DecodedImage {
        if Thread.isMainThread { throw Failure.ranOnMainThread }
        guard let queue = OperationQueue.current,
              queue.name == "io.github.anzchy.mado.first-image-decode",
              queue.maxConcurrentOperationCount == 1 else { throw Failure.wrongExecutor }
        return try ImageIODecoder().decode(request)
    }
}

@Suite @MainActor struct ImagePipelineTests {
    private func withImage(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("small.png")
        let context = try #require(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8,
            bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        try await body(file)
    }

    @Test func requestsDecodeOffMainAndRespectPixelLimit() async throws {
        try await withImage { file in
            let pipeline = ImageIOPipeline(decoder: ThreadProbeDecoder(), configuration: DecodeConfiguration(workers: 1))
            for maximum in [1, 8, 64, 128] {
                let result = try await pipeline.image(for: ImageDecodeRequest(fileURL: file, maximumPixelSize: maximum))
                #expect(result.image.width > 0 && result.image.height > 0)
                #expect(result.image.width <= maximum && result.image.height <= maximum)
                #expect(result.sourcePixelSize == CGSize(width: 64, height: 32))
            }
            // Also exercise the production default decoder, not only the probe.
            let result = try await ImageIOPipeline().image(for: ImageDecodeRequest(fileURL: file, maximumPixelSize: 8))
            #expect(result.image.width == 8)
            #expect(result.image.height == 4)
        }
    }

    @Test func corruptFilesAndInvalidRequestsFailCleanly() async throws {
        try await withImage { file in
            try Data("not an image".utf8).write(to: file)
            let pipeline = ImageIOPipeline()
            await #expect(performing: {
                try await pipeline.image(for: ImageDecodeRequest(fileURL: file, maximumPixelSize: 8))
            }, throws: loadError(.unsupportedFormat))
            await #expect(performing: {
                try await pipeline.image(for: ImageDecodeRequest(fileURL: file, maximumPixelSize: 0))
            }, throws: loadError(.sourceChanged))
            await #expect(performing: {
                try await pipeline.image(for: ImageDecodeRequest(fileURL: URL(string: "https://invalid.example/image")!, maximumPixelSize: 8))
            }, throws: loadError(.sourceChanged))
        }
    }
    @Test func zoomSequenceDecodesOnlyPreviewAndOneDetailOnPipelineQueue() async throws {
        try await withImage { file in
            let pipeline = ImageIOPipeline(decoder: ThreadProbeDecoder(), configuration: DecodeConfiguration(workers: 1))
            let source = CGSize(width: 64, height: 32)
            let viewport = CGSize(width: 8, height: 8)
            var completed = 0
            var decodedEdges: [Int] = []
            for zoom in [0.125] + (1...100).map({ 0.125 * pow(1.025, Double($0)) }) + [1, 64, 0.125, 2] {
                let maximum = CanvasDecodePolicy.maximumPixelSize(source: source, viewport: viewport, zoom: zoom)
                if maximum > completed {
                    let result = try await pipeline.image(for: ImageDecodeRequest(fileURL: file, maximumPixelSize: maximum))
                    decodedEdges.append(result.image.width)
                    completed = maximum
                }
            }
            #expect(decodedEdges == [8, 64])
        }
    }

}
