import Accelerate
import CommonCrypto
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// An uncompressed RGBA TIFF of deterministic pseudo-random noise, so it cannot shrink when re-encoded.
/// `alphaValue` sets every pixel's alpha; otherwise `transparent` makes the left half transparent and the rest opaque.
/// #798: the pixels come from an AES-CTR keystream with a fixed key and the alpha from vImage, both outside Swift loops.
/// A per-pixel Swift loop here cost about 1.5 s of CPU per image in debug builds, on a cooperative thread.
func noiseTIFF(width: Int, height: Int, transparent: Bool = false, alphaValue: UInt8? = nil) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let buffer = try #require(context.data)
    try fillWithKeystream(buffer, count: context.bytesPerRow * height)
    let half = transparent && alphaValue == nil ? width / 2 : 0
    try setAlpha(alphaValue ?? 255, in: buffer + half * 4, width: width - half, height: height, bytesPerRow: context.bytesPerRow)
    try setAlpha(0, in: buffer, width: half, height: height, bytesPerRow: context.bytesPerRow)
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

/// Overwrites `count` bytes with the AES-128-CTR keystream of a fixed key and counter, the same bytes on every call.
private func fillWithKeystream(_ buffer: UnsafeMutableRawPointer, count: Int) throws {
    let key = [UInt8](repeating: 0x5A, count: kCCKeySizeAES128)
    let counter = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
    var cryptor: CCCryptorRef?
    try #require(CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding), counter, key, key.count, nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor) == kCCSuccess)
    defer { CCCryptorRelease(cryptor) }
    memset(buffer, 0, count)
    var moved = 0
    try #require(CCCryptorUpdate(cryptor, buffer, count, buffer, count, &moved) == kCCSuccess)
    try #require(moved == count)
}

/// Sets the fourth byte of every pixel in a `width` x `height` RGBA region to `alpha`; a zero-width region is left alone.
private func setAlpha(_ alpha: UInt8, in pixels: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int) throws {
    guard width > 0 else { return }
    var region = vImage_Buffer(data: pixels, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: bytesPerRow)
    // vImage names the channels A, R, G, B; mask 0x1 is the fourth byte, which is alpha in this RGBA buffer.
    try #require(vImageOverwriteChannelsWithScalar_ARGB8888(alpha, &region, &region, 0x1, vImage_Flags(kvImageNoFlags)) == kvImageNoError)
}
