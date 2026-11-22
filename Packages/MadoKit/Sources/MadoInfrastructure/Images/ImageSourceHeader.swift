import Foundation
import ImageIO
import MadoCore

struct ImageSourceHeader: Sendable {
    let bytesPerPixel: Int
    let itemID: ItemID
    let width: Int
    let height: Int
    let revision: FileRevision
    /// EXIF orientations 5…8 rotate the stored pixels a quarter turn.
    let rotated: Bool
    // ImageIO can return partial pixels for incomplete PNGs. Check chunk boundaries without reading payloads.
    private static func requireCompletePNG(_ url: URL) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        var offset: UInt64 = 8
        while offset + 12 <= size {
            try file.seek(toOffset: offset)
            guard let header = try file.read(upToCount: 8), header.count == 8 else { throw ImageDecodeError.unreadableImage }
            let length = header.prefix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard length <= size - offset - 12 else { throw ImageDecodeError.unreadableImage }
            if Array(header.suffix(4)) == [73, 69, 78, 68] { return }
            offset += length + 12
        }
        throw ImageDecodeError.unreadableImage
    }
    /// Issue 807: ImageIO decodes a truncated JPEG scan as a partial image and still reports the source complete.
    /// Walk the primary image's markers from SOI: segment lengths skip headers without reading payloads, and
    /// entropy-coded data is skipped to its next marker. The image must reach EOI before the file ends. Bytes after
    /// EOI (MPF images, appended trailers, padding) are not inspected. Stray bytes between segments are skipped as
    /// libjpeg does, so only a missing end is refused.
    static func requireCompleteJPEG(_ url: URL) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            guard count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { throw ImageDecodeError.unreadableImage }
            /// The next 0xFF at or after `from`, or nil.
            func nextFF(_ from: Int) -> Int? {
                guard from < count, let base = raw.baseAddress,
                      let hit = memchr(base + from, 0xFF, count - from) else { return nil }
                return base.distance(to: UnsafeRawPointer(hit))
            }
            var offset = 2
            while true {
                guard var marker = nextFF(offset) else { throw ImageDecodeError.unreadableImage }
                while marker < count, bytes[marker] == 0xFF { marker += 1 }   // Fill bytes before a marker.
                guard marker < count else { throw ImageDecodeError.unreadableImage }
                let code = bytes[marker]
                offset = marker + 1
                switch code {
                case 0xD9: return                                              // EOI.
                case 0x00, 0x01, 0xD0...0xD7: continue                        // Stuffed byte, TEM, RSTn.
                case 0xD8: throw ImageDecodeError.unreadableImage              // A second SOI inside the image.
                default:
                    guard offset + 2 <= count else { throw ImageDecodeError.unreadableImage }
                    let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
                    guard length >= 2, offset + length <= count else { throw ImageDecodeError.unreadableImage }
                    offset += length
                    guard code == 0xDA else { continue }
                    // Entropy-coded data after SOS: FF00 and RSTn belong to the scan; any other marker ends it.
                    while true {
                        guard let ff = nextFF(offset), ff + 1 < count else { throw ImageDecodeError.unreadableImage }
                        let next = bytes[ff + 1]
                        if next == 0x00 || (0xD0...0xD7).contains(next) { offset = ff + 2; continue }
                        if next == 0xFF { offset = ff + 1; continue }
                        offset = ff
                        break
                    }
                }
            }
        }
    }
    static func pixelBytes(_ properties: [CFString: Any]) -> Int {
        let model = properties[kCGImagePropertyColorModel] as? String
        let components = model == (kCGImagePropertyColorModelGray as String) ? 1 : 3
        return DecodeBudget.bytesPerPixel(depth: properties[kCGImagePropertyDepth] as? Int ?? 8,
            components: components, hasAlpha: properties[kCGImagePropertyHasAlpha] as? Bool ?? false,
            isFloat: properties[kCGImagePropertyIsFloat] as? Bool ?? false)
    }
    static func read(_ request: ImageDecodeRequest, budget: Int, itemID: ItemID) throws -> ImageSourceHeader {
        guard request.fileURL.isFileURL, request.maximumPixelSize > 0 else { throw ImageDecodeError.invalidRequest }
        // A header-only PNG may be too incomplete for ImageIO properties. Inspect
        // its fixed IHDR fields first, without reading the payload or allocating pixels.
        let file = try? FileHandle(forReadingFrom: request.fileURL)
        let prefix = try? file?.read(upToCount: 24)
        try? file?.close()
        if let data = prefix, data.count == 24,
           Array(data.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10],
           Array(data[12..<16]) == [73, 72, 68, 82] {
            let width = data[16..<20].reduce(0) { ($0 << 8) | Int($1) }
            let height = data[20..<24].reduce(0) { ($0 << 8) | Int($1) }
            _ = try DecodeBudget.sourceCost(width: width, height: height, budget: Int.max)
            try requireCompletePNG(request.fileURL)
        }
        if let data = prefix, data.count >= 3, Array(data.prefix(3)) == [0xFF, 0xD8, 0xFF] {
            try requireCompleteJPEG(request.fileURL)
        }
        guard let source = CGImageSourceCreateWithURL(request.fileURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw ImageDecodeError.unreadableImage }
        let bytesPerPixel = pixelBytes(properties)
        _ = try DecodeBudget.outputCost(width: width, height: height, maximumPixelSize: request.maximumPixelSize, bytesPerPixel: bytesPerPixel, budget: budget)
        guard CGImageSourceGetStatus(source) == .statusComplete else { throw ImageDecodeError.unreadableImage }
        return ImageSourceHeader(bytesPerPixel: bytesPerPixel, itemID: itemID, width: width, height: height,
                                 revision: try FileRevisionReader.read(request.fileURL),
                                 rotated: (5...8).contains(properties[kCGImagePropertyOrientation] as? Int ?? 1))
    }
}
