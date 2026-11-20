import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// #798: the Baidu upload tests build large noise TIFFs synchronously on a cooperative thread. A per-pixel Swift loop
/// there took about 1.5 s of CPU per image locally (several times that on the 3-core CI runner, CI run 44724946406)
/// and held the pool while the unrelated Infrastructure suites waited. These pin the cost and every property the
/// upload tests rely on: an uncompressed TIFF, exact alpha, incompressible pixels and the same bytes on every call.
struct Issue798NoiseTIFFTests {
    /// Thread CPU time, not wall time: waiting behind other tests does not count.
    @Test(.timeLimit(.minutes(2)))
    func issue798NoiseTIFFBuildsWithinCPUBudget() throws {
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let image = try noiseTIFF(width: 1800, height: 1300, alphaValue: 254)
        let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e9
        #expect(cpu < 0.25, "noise TIFF took \(cpu) s of thread CPU")
        #expect(image.count > 1800 * 1300 * 4)
    }

    @Test(.timeLimit(.minutes(2)))
    func issue798NoiseTIFFIsUncompressedDeterministicAndIncompressible() throws {
        let first = try noiseTIFF(width: 300, height: 200)
        #expect(first == (try noiseTIFF(width: 300, height: 200)))
        #expect(first.count > 300 * 200 * 4)
        #expect(first.count < 300 * 200 * 4 + 64 * 1024)
        let source = try #require(CGImageSourceCreateWithData(first as CFData, nil))
        #expect((CGImageSourceGetType(source) as String?) == UTType.tiff.identifier)
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 300 && image.height == 200)
        let png = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        #expect(png.length > 300 * 200 * 3 * 95 / 100, "noise compressed to \(png.length) bytes")
    }

    @Test(.timeLimit(.minutes(2)), arguments: [
        (UInt8?.some(254), false), (UInt8?.none, false), (UInt8?.none, true)
    ])
    func issue798NoiseTIFFAlphaIsExact(alphaValue: UInt8?, transparent: Bool) throws {
        let width = 20, height = 20
        let data = try noiseTIFF(width: width, height: height, transparent: transparent, alphaValue: alphaValue)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.bitsPerPixel == 32 && image.bitsPerComponent == 8)
        #expect(image.alphaInfo == .premultipliedLast)
        let bytes = try #require(image.dataProvider?.data as Data?)
        for y in 0..<height {
            for x in 0..<width {
                let expected = alphaValue ?? (transparent && x < width / 2 ? 0 : 255)
                #expect(bytes[y * image.bytesPerRow + x * 4 + 3] == expected, "alpha at \(x),\(y)")
            }
        }
    }
}
