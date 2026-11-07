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
