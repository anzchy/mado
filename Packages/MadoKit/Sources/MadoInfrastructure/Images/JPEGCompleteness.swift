import Foundation
import MadoCore

/// Issue 807: ImageIO decodes a truncated JPEG scan as a partial image and still reports the source complete, so the
/// header refuses a JPEG whose primary image does not reach EOI before the file ends.
///
/// Cost: the check runs on every header read, before any thumbnail cache lookup. The common case reads only the
/// marker segments up to the first scan plus the last few KB:
/// - The segments before the first SOS are walked by their lengths. A segment that runs past the end (for example an
///   EXIF thumbnail cut exactly at its own EOI) is refused here.
/// - If the file, after trailing zero padding, ends in EOI past the first scan header, it is accepted. Inside
///   entropy-coded data FF D9 can only be the real EOI, so a cut inside a scan never ends that way. The one case this
///   can miss is a cut landing on the bytes FF D9 inside a table segment between progressive scans.
/// - Otherwise (trailers, MPF data cut part-way, a real truncation) the whole primary image is walked.
/// Verdicts are memoised per file revision, so a repeated header read of an unchanged file reads no image bytes.
///
/// Files are read with FileHandle in bounded chunks, not mapped, so a file truncated in place during the walk fails
/// with a read error instead of a SIGBUS.
final class JPEGCompleteness: @unchecked Sendable {
    struct Report: Equatable, Sendable {
        enum Path: Equatable, Sendable { case tail, walk, memo }
        let path: Path
        let bytesRead: Int
    }

    static let shared = JPEGCompleteness()
    static let tailBytes = 4096
    private static let memoLimit = 4096

    private struct Key: Hashable { let path: String; let revision: FileRevision }
    private let lock = NSLock()
    private var memo: [Key: Bool] = [:]
    private var observed: [String: [Report]] = [:]

    /// Throws `ImageDecodeError.unreadableImage` unless the primary JPEG image reaches EOI. Without a revision
    /// nothing is memoised.
    @discardableResult
    func check(_ url: URL, revision: FileRevision?) throws -> Report {
        let path = url.standardizedFileURL.path
        let key = revision.map { Key(path: path, revision: $0) }
        if let key, let complete = lock.withLock({ memo[key] }) {
            record(Report(path: .memo, bytesRead: 0), for: path)
            guard complete else { throw ImageDecodeError.unreadableImage }
            return Report(path: .memo, bytesRead: 0)
        }
        var reader = try ChunkedReader(url)
        defer { reader.close() }
        let complete: Bool
        let route: Report.Path
        do {
            (complete, route) = try Self.decide(&reader)
        } catch let error as ImageDecodeError where error == .unreadableImage {
            (complete, route) = (false, .walk)
        }
        let report = Report(path: route, bytesRead: reader.bytesRead)
        if let key {
            lock.withLock {
                if memo.count >= Self.memoLimit { memo.removeAll(keepingCapacity: true) }
                memo[key] = complete
            }
        }
        record(report, for: path)
        guard complete else { throw ImageDecodeError.unreadableImage }
        return report
    }

    /// Test seam: after `observe`, every check of that file appends its report.
    func observe(_ url: URL) { lock.withLock { observed[url.standardizedFileURL.path] = [] } }
    func reports(for url: URL) -> [Report] {
        lock.withLock { () -> [Report] in if let list = observed[url.standardizedFileURL.path] { return list }; return [] }
    }
    private func record(_ report: Report, for path: String) {
        lock.withLock { if observed[path] != nil { observed[path]?.append(report) } }
    }

    private static func decide(_ reader: inout ChunkedReader) throws -> (Bool, Report.Path) {
        guard case .scan(let scanStart) = try walk(&reader, stopAtFirstScan: true) else { return (true, .walk) }
        let size = reader.size
        let count = min(tailBytes, size - scanStart)
        var tail = ArraySlice(try reader.read(at: size - count, count: count))
        while tail.last == 0 { tail = tail.dropLast() }
        if tail.count >= 2, tail[tail.endIndex - 2] == 0xFF, tail[tail.endIndex - 1] == 0xD9 { return (true, .tail) }
        _ = try walk(&reader, stopAtFirstScan: false)
        return (true, .walk)
    }

    private enum Stop { case eoi, scan(Int) }

    /// Walks the primary image's markers from SOI: segment lengths skip headers without reading payloads, and
    /// entropy-coded data is skipped to its next marker. Stray bytes between segments are skipped as libjpeg does.
    private static func walk(_ reader: inout ChunkedReader, stopAtFirstScan: Bool) throws -> Stop {
        guard reader.size >= 4, try reader.byte(0) == 0xFF, try reader.byte(1) == 0xD8 else {
            throw ImageDecodeError.unreadableImage
        }
        var offset = 2
        while var marker = try reader.nextFF(offset) {
            while try reader.byte(marker) == 0xFF { marker += 1 }   // Fill bytes before a marker.
            guard let code = try reader.byte(marker) else { throw ImageDecodeError.unreadableImage }
            offset = marker + 1
            switch code {
            case 0xD9: return .eoi
            case 0x00, 0x01, 0xD0...0xD7: continue                    // Stuffed byte, TEM, RSTn.
            case 0xD8: throw ImageDecodeError.unreadableImage          // A second SOI inside the image.
            default:
                guard let high = try reader.byte(offset), let low = try reader.byte(offset + 1) else {
                    throw ImageDecodeError.unreadableImage
                }
                let length = Int(high) << 8 | Int(low)
                guard length >= 2, offset + length <= reader.size else { throw ImageDecodeError.unreadableImage }
                offset += length
                guard code == 0xDA else { continue }
                if stopAtFirstScan { return .scan(offset) }
                // Entropy-coded data after SOS: FF00 and RSTn belong to the scan; any other marker ends it.
                while true {
                    guard let ff = try reader.nextFF(offset), let next = try reader.byte(ff + 1) else {
                        throw ImageDecodeError.unreadableImage
                    }
                    if next == 0x00 || (0xD0...0xD7).contains(next) { offset = ff + 2; continue }
                    if next == 0xFF { offset = ff + 1; continue }
                    offset = ff
                    break
                }
            }
        }
        throw ImageDecodeError.unreadableImage   // The file ended before EOI.
    }
}

/// Sequential and random reads through one 64 KB window, counting the bytes read from the file.
private struct ChunkedReader {
    static let chunk = 64 * 1024
    let size: Int
    private(set) var bytesRead = 0
    private let file: FileHandle
    private var window: [UInt8] = []
    private var windowStart = 0

    init(_ url: URL) throws {
        file = try FileHandle(forReadingFrom: url)
        do { size = Int(try file.seekToEnd()) } catch { try? file.close(); throw error }
    }
    func close() { try? file.close() }

    mutating func read(at offset: Int, count: Int) throws -> [UInt8] {
        try file.seek(toOffset: UInt64(offset))
        let data = try file.read(upToCount: count)
        if let data { bytesRead += data.count }
        guard let data, data.count == count else { throw ImageDecodeError.unreadableImage }   // Shrunk while reading.
        return [UInt8](data)
    }

    private mutating func load(_ offset: Int) throws {
        window = try read(at: offset, count: min(Self.chunk, size - offset))
        windowStart = offset
    }

    /// The byte at `offset`, or nil past the end.
    mutating func byte(_ offset: Int) throws -> UInt8? {
        guard offset < size else { return nil }
        if offset < windowStart || offset >= windowStart + window.count { try load(offset) }
        return window[offset - windowStart]
    }

    /// The offset of the next 0xFF at or after `from`, or nil.
    mutating func nextFF(_ from: Int) throws -> Int? {
        var start = from
        while start < size {
            if start < windowStart || start >= windowStart + window.count { try load(start) }
            let local = start - windowStart
            let hit = window.withUnsafeBufferPointer { buffer -> Int? in
                guard let base = buffer.baseAddress,
                      let found = memchr(base + local, 0xFF, buffer.count - local) else { return nil }
                return UnsafeRawPointer(base).distance(to: UnsafeRawPointer(found))
            }
            if let hit { return windowStart + hit }
            start = windowStart + window.count
        }
        return nil
    }
}
