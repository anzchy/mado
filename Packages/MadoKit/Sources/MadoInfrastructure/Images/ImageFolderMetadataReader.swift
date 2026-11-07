import Foundation
import ImageIO
import MadoCore

public enum FolderMetadataReadError: Error { case unreadableHeader, changedDuringRead }

/// Reads only source properties; never creates an image or thumbnail.
public struct ImageFolderMetadataReader: FolderMetadataReading {
    public init() {}
    public func read(_ url: URL) throws -> FolderImageMetadata {
        let before = try FileRevisionReader.read(url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw FolderMetadataReadError.unreadableHeader
        }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let original = exif?[kCGImagePropertyExifDateTimeOriginal] as? String
        let digitized = exif?[kCGImagePropertyExifDateTimeDigitized] as? String
        let dateString = original ?? digitized ?? tiff?[kCGImagePropertyTIFFDateTime] as? String
        let offset = original != nil ? exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String
            : digitized != nil ? exif?[kCGImagePropertyExifOffsetTimeDigitized] as? String : nil
        let date = dateString.flatMap { Self.captureDate($0, offset: offset) }
        let width = properties[kCGImagePropertyPixelWidth] as? Int
        let height = properties[kCGImagePropertyPixelHeight] as? Int
        guard try FileRevisionReader.read(url) == before else { throw FolderMetadataReadError.changedDuringRead }
        return .init(captureDate: date, pixelWidth: width.flatMap { $0 > 0 ? $0 : nil },
            pixelHeight: height.flatMap { $0 > 0 ? $0 : nil })
    }
    static func captureDate(_ value: String, offset: String? = nil) -> Date? {
        let zone: TimeZone
        if let offset {
            let bytes = Array(offset.utf8)
            guard bytes.count == 6, bytes[3] == 58, bytes[0] == 43 || bytes[0] == 45,
                  let hours = Int(String(decoding: bytes[1..<3], as: UTF8.self)),
                  let minutes = Int(String(decoding: bytes[4..<6], as: UTF8.self)),
                  hours <= 23, minutes < 60,
                  let parsed = TimeZone(secondsFromGMT: (bytes[0] == 45 ? -1 : 1) * (hours * 3600 + minutes * 60))
            else { return captureDate(value) }
            zone = parsed
        } else {
            guard let utc = TimeZone(secondsFromGMT: 0) else { return nil }
            zone = utc
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.isLenient = false
        return formatter.date(from: value)
    }
}
