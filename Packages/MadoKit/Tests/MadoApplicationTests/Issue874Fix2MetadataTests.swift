import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MadoApplication

// #874 fix round 2 WI-3 (audit i874-confirm1 opus H1, gpt M2): the file's own bytes went to the service with
// everything the file carries besides its pixels: EXIF (capture time, camera, serial numbers), GPS, XMP, IPTC, an
// embedded thumbnail. Now a JPEG or PNG goes as its own encoded image with all of that removed (lossless: the image
// data is copied, never re-encoded); a file that cannot be stripped that way goes as the pixels-only PNG, as before.
// A file that carries none of it goes byte for byte as it is.

private let secrets874G = ["MadoSecretExif874", "MadoSecretXMP874", "MadoSecretIPTC874", "MadoSecretPNG874",
                           "MadoCam874", "MadoTrailer874"]

private func picture874G(_ width: Int, _ height: Int) throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    for row in 0..<height {
        context.setFillColor(CGColor(red: CGFloat(row % 7) / 7, green: 0.4, blue: CGFloat(row % 3) / 3, alpha: 1))
        context.fill(CGRect(x: 0, y: row, width: width, height: 1))
    }
    return try #require(context.makeImage())
}

/// A JPEG or PNG carrying EXIF, GPS, TIFF camera fields, IPTC, XMP and (JPEG) an embedded thumbnail.
func taggedImage874G(_ type: UTType, width: Int = 64, height: Int = 48) throws -> Data {
    let metadata = CGImageMetadataCreateMutable()
    #expect(CGImageMetadataSetValueWithPath(metadata, nil, "dc:description" as CFString, "MadoSecretXMP874" as CFString))
    var properties: [CFString: Any] = [
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 31.2304, kCGImagePropertyGPSLatitudeRef: "N",
                                       kCGImagePropertyGPSLongitude: 121.4737, kCGImagePropertyGPSLongitudeRef: "E"],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "MadoSecretExif874",
                                         kCGImagePropertyExifDateTimeOriginal: "2026:11:27 10:00:00"],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "MadoCam874", kCGImagePropertyTIFFModel: "MadoCam874"],
        kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: "MadoSecretIPTC874"],
        kCGImageDestinationEmbedThumbnail: true,
    ]
    if type == .png { properties[kCGImagePropertyPNGDictionary] = [kCGImagePropertyPNGDescription: "MadoSecretPNG874"] }
    let buffer = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(buffer, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImageAndMetadata(destination, try picture874G(width, height), metadata,
                                          properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return buffer as Data
}

/// ImageIO's own JPEG or PNG with the one EXIF block it always writes removed by hand: a file with no metadata.
func plainImage874G(_ type: UTType, width: Int = 64, height: Int = 48) throws -> Data {
    let buffer = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(buffer, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try picture874G(width, height), nil)
    #expect(CGImageDestinationFinalize(destination))
    var bytes = [UInt8](buffer as Data)
    if type == .jpeg {
        // SOI, then segments; drop each APP1 (0xFFE1) before the first SOS.
        var index = 2
        while bytes[index + 1] != 0xDA {
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            if bytes[index + 1] == 0xE1 { bytes.removeSubrange(index ..< index + 2 + length) } else { index += 2 + length }
        }
    } else {
        // Signature, then chunks; drop eXIf.
        var index = 8
        while index < bytes.count {
            let length = bytes[index ..< index + 4].reduce(0) { $0 << 8 | Int($1) }
            if String(decoding: bytes[index + 4 ..< index + 8], as: UTF8.self) == "eXIf" {
                bytes.removeSubrange(index ..< index + 12 + length)
            } else { index += 12 + length }
        }
    }
    return Data(bytes)
}

private func contains874G(_ data: Data, _ text: String) -> Bool { data.range(of: Data(text.utf8)) != nil }

/// What ImageIO finds in `data` besides the pixels.
private func carriedMetadata874G(_ data: Data) throws -> [String] {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    var found = [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
                 kCGImagePropertyTIFFDictionary].filter { properties[$0] != nil }.map { $0 as String }
    if let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any],
       png[kCGImagePropertyPNGDescription] != nil { found.append("PNG text") }
    if let tags = CGImageSourceCopyMetadataAtIndex(source, 0, nil).flatMap({ CGImageMetadataCopyTags($0) as? [Any] }),
       !tags.isEmpty { found.append("XMP") }
    return found
}

/// JPEG start-of-image markers in `data`: an embedded thumbnail is a second JPEG inside the file. (ImageIO makes a
/// thumbnail for any image, so asking it is no test.) Entropy-coded data never holds 0xFFD8.
private func jpegStarts874G(_ data: Data) -> Int {
    let bytes = [UInt8](data)
    return (0 ..< max(0, bytes.count - 2)).filter { bytes[$0] == 0xFF && bytes[$0 + 1] == 0xD8 && bytes[$0 + 2] == 0xFF }.count
}

private func pixels874G(_ data: Data) throws -> Data {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    return try #require(image.dataProvider?.data as Data?)
}

@Test(arguments: [UTType.jpeg, .png])
func issue874Fix2ATaggedFileGoesWithoutItsMetadataAndWithItsPixelsUnchanged(_ type: UTType) throws {
    let tagged = try taggedImage874G(type)
    // The fixture really carries all of it.
    #expect(try carriedMetadata874G(tagged).contains(kCGImagePropertyGPSDictionary as String))
    #expect(try carriedMetadata874G(tagged).contains("XMP"))
    #expect(secrets874G.contains { contains874G(tagged, $0) })
    if type == .jpeg { #expect(jpegStarts874G(tagged) >= 2, "the fixture embeds a thumbnail") }
    let sent = try #require(TableRecognitionSource.payload(from: tagged), "\(type.identifier) still goes as its own image")
    #expect(TableImageFormat.mediaType(of: sent) == TableImageFormat.mediaType(of: tagged))
    #expect(try carriedMetadata874G(sent) == [], "\(type.identifier): nothing besides the pixels")
    for secret in secrets874G { #expect(!contains874G(sent, secret), "\(type.identifier): \(secret)") }
    #expect(!contains874G(sent, "Exif\0\0") && !contains874G(sent, "x:xmpmeta") && !contains874G(sent, "Photoshop 3.0"))
    if type == .jpeg { #expect(jpegStarts874G(sent) == 1, "no embedded thumbnail") }
    #expect(try pixels874G(sent) == pixels874G(tagged), "the image data is copied, not re-encoded")
    #expect(sent.count < tagged.count)
}

@Test func issue874Fix2DataAfterTheEndOfAJPEGIsNotSent() throws {
    var file = try plainImage874G(.jpeg)
    file.append(Data("MadoTrailer874".utf8))
    let sent = try #require(TableRecognitionSource.payload(from: file))
    #expect(!contains874G(sent, "MadoTrailer874"))
    #expect(sent == file.dropLast("MadoTrailer874".utf8.count))
}

@Test(arguments: [UTType.jpeg, .png])
func issue874Fix2AFileWithoutMetadataGoesByteForByte(_ type: UTType) throws {
    let plain = try plainImage874G(type)
    #expect(try carriedMetadata874G(plain) == [])
    #expect(TableRecognitionSource.payload(from: plain) == plain)
}

@Test func issue874Fix2A24MegapixelJPEGWithoutMetadataStillGoesAsItIs() throws {
    let plain = try plainImage874G(.jpeg, width: 6000, height: 4000)
    #expect(TableRecognitionSource.payload(from: plain) == plain)
}

@Test func issue874Fix2WhatCannotBeStrippedGoesAsThePixelsOnlyPNG() throws {
    // GIF (and WebP) are not stripped here: nil sends the PNG of the pixels.
    #expect(TableRecognitionSource.payload(from: makeGIF869(4, 3)) == nil)
    // A JPEG cut short before its end.
    let plain = try plainImage874G(.jpeg)
    #expect(TableRecognitionSource.payload(from: plain.prefix(plain.count - 40)) == nil)
    // A PNG without its end chunk.
    let png = try plainImage874G(.png)
    #expect(TableRecognitionSource.payload(from: png.prefix(png.count - 12)) == nil)
}
