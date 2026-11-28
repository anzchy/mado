import Foundation

/// Removes from a JPEG or PNG everything it carries besides its image and colour data (#874 fix2 WI-3): EXIF (capture
/// time, camera, serial numbers, the embedded thumbnail), GPS, XMP, IPTC, comments, text chunks and anything after
/// the image's end. Lossless: the kept segments and chunks are copied byte for byte, nothing is decoded or
/// re-encoded, so a file that carries none of it comes back unchanged. Nil when the file is another format or its
/// structure is not what the walk expects; the caller then sends the pixels-only PNG.
enum TableImageMetadata {
    static func stripped(_ data: Data) -> Data? {
        switch TableImageFormat.mediaType(of: data) {
        case "image/jpeg": return jpeg([UInt8](data))
        case "image/png": return png([UInt8](data))
        default: return nil
        }
    }

    // MARK: JPEG

    /// Walks the markers from SOI to EOI, copying the entropy-coded data after each SOS as it is.
    private static func jpeg(_ bytes: [UInt8]) -> Data? {
        let count = bytes.count
        var out = Data([0xFF, 0xD8])
        out.reserveCapacity(count)
        var index = 2
        while index < count {
            guard bytes[index] == 0xFF else { return nil }
            while index < count, bytes[index] == 0xFF { index += 1 } // fill bytes before a marker
            guard index < count else { return nil }
            let marker = bytes[index]
            index += 1
            switch marker {
            case 0xD9:
                out.append(contentsOf: [0xFF, 0xD9])
                return out // anything after the end of the image is dropped
            case 0xD0...0xD7, 0x01:
                out.append(contentsOf: [0xFF, marker])
                continue
            default:
                break
            }
            guard index + 2 <= count else { return nil }
            let length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
            guard length >= 2, index + length <= count else { return nil }
            guard let keep = keepsJPEGSegment(marker, payload: bytes[(index + 2) ..< (index + length)]) else {
                return nil
            }
            if keep {
                out.append(contentsOf: [0xFF, marker])
                out.append(contentsOf: bytes[index ..< (index + length)])
            }
            index += length
            if marker == 0xDA {
                // The scan runs to the next marker that is not a stuffed 0xFF00 or a restart marker.
                let start = index
                while index + 1 < count,
                      !(bytes[index] == 0xFF && bytes[index + 1] != 0x00 && !(0xD0...0xD7).contains(bytes[index + 1])) {
                    index += 1
                }
                guard index + 1 < count else { return nil }
                out.append(contentsOf: bytes[start ..< index])
            }
        }
        return nil
    }

    /// True keeps the segment, false drops it, nil means the file is not one this walk knows.
    private static func keepsJPEGSegment(_ marker: UInt8, payload: ArraySlice<UInt8>) -> Bool? {
        switch marker {
        case 0xE0:
            // JFIF without its optional thumbnail (density only); any other APP0, such as a JFXX thumbnail, goes.
            let jfif = Array("JFIF".utf8) + [0]
            return payload.count == 14 && payload.starts(with: jfif)
                && payload[payload.startIndex + 12] == 0 && payload[payload.startIndex + 13] == 0
        case 0xE2: return payload.starts(with: Array("ICC_PROFILE".utf8) + [0]) // the colour profile
        case 0xEE: return payload.starts(with: Array("Adobe".utf8)) // the colour transform decoders need
        case 0xE1, 0xE3...0xED, 0xEF, 0xFE: return false // EXIF, XMP, IPTC and the other APPn; comments
        case 0xC0...0xCF, 0xDA...0xDF: return true // frame, tables, scan, restart interval
        default: return nil
        }
    }

    // MARK: PNG

    /// The chunks that make up the image and its colour; every other ancillary chunk (tEXt, zTXt, iTXt, eXIf, tIME,
    /// and private ones) is dropped.
    private static let keptPNGChunks: Set<String> = ["IHDR", "PLTE", "IDAT", "IEND", "tRNS", "gAMA", "cHRM", "sRGB",
                                                    "iCCP", "sBIT", "bKGD", "pHYs", "cICP", "acTL", "fcTL", "fdAT"]

    private static func png(_ bytes: [UInt8]) -> Data? {
        let count = bytes.count
        var out = Data(bytes[0 ..< 8])
        out.reserveCapacity(count)
        var index = 8
        while index + 12 <= count {
            let length = bytes[index ..< (index + 4)].reduce(0) { $0 << 8 | Int($1) }
            guard length <= count - index - 12 else { return nil }
            let type = String(decoding: bytes[(index + 4) ..< (index + 8)], as: UTF8.self)
            let end = index + 12 + length
            if keptPNGChunks.contains(type) {
                out.append(contentsOf: bytes[index ..< end])
            } else if bytes[index + 4] & 0x20 == 0 {
                return nil // an unknown critical chunk cannot be dropped
            }
            if type == "IEND" { return out }
            index = end
        }
        return nil
    }
}
