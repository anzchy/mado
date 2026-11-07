import Foundation
import ImageIO
import Testing
@testable import MadoInfrastructure

@Test func issue108ImageIOMetadataReaderUsesRealHeaderProperties() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
    defer { try? FileManager.default.removeItem(at: url) }
    let space = CGColorSpaceCreateDeviceRGB()
    let pixels: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255]
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    let image = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: 8, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
    let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: "2020:04:05 06:07:08"]
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyExifDictionary: exif] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    let result = try ImageFolderMetadataReader().read(url)
    #expect(result.pixelWidth == 2 && result.pixelHeight == 2)
    #expect(result.captureDate == ImageFolderMetadataReader.captureDate("2020:04:05 06:07:08"))
    #expect(throws: (any Error).self) {
        try ImageFolderMetadataReader().read(FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
    }
}

@Test func issue108CorruptImageMetadataRemainsUnknown() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("not an image".utf8).write(to: url)
    #expect(throws: FolderMetadataReadError.unreadableHeader) {
        try ImageFolderMetadataReader().read(url)
    }
}

@Test func issue108CaptureDateFallsBackToTIFFHeader() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tiff")
    defer { try? FileManager.default.removeItem(at: url) }
    let pixels: [UInt8] = [255, 0, 0, 255]
    let image = CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent)!
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image,
        [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFDateTime: "2021:05:06 07:08:09"]] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    let metadata = try ImageFolderMetadataReader().read(url)
    #expect(metadata.captureDate == ImageFolderMetadataReader.captureDate("2021:05:06 07:08:09"))
}

@Test func issue108ExifOffsetChangesAbsoluteCaptureOrder() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
    defer { try? FileManager.default.removeItem(at: url) }
    let pixels: [UInt8] = [255, 0, 0, 255]
    let image = CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent)!
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image,
        [kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: "2020:04:05 06:07:08",
            kCGImagePropertyExifOffsetTimeOriginal: "+08:00"
        ]] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    let metadata = try ImageFolderMetadataReader().read(url)
    #expect(metadata.captureDate == ImageFolderMetadataReader.captureDate("2020:04:04 22:07:08"))
}

@Test func issue108MalformedCaptureOffsetFallsBackToUTC() {
    #expect(ImageFolderMetadataReader.captureDate("2020:04:05 06:07:08", offset: "+99:00")
        == ImageFolderMetadataReader.captureDate("2020:04:05 06:07:08"))
    #expect(ImageFolderMetadataReader.captureDate("2020:04:05 06:07:08", offset: "bad")
        == ImageFolderMetadataReader.captureDate("2020:04:05 06:07:08"))
    #expect(ImageFolderMetadataReader.captureDate("2020:04:05 06:07:08", offset: "-02:00")
        == ImageFolderMetadataReader.captureDate("2020:04:05 08:07:08"))
}
