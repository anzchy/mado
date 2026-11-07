import Foundation
import os
import PicseeCore

/// Only the cancellation flag crosses the worker/actor boundary; guarded by lock.
final class DecodeTrace: @unchecked Sendable {
    private static let log = OSLog(subsystem: "io.github.anzchy.mado", category: "decode")
    private let id: OSSignpostID
    private let lock = NSLock()
    private var cancelled = false
    init() {
        id = OSSignpostID(log: Self.log)
        os_signpost(.begin, log: Self.log, name: "DecodeQueueWait", signpostID: id)
    }
    func cancel() { lock.withLock { cancelled = true } }
    func reserve(_ bytes: Int) {
        os_signpost(.begin, log: Self.log, name: "MemoryReservation", signpostID: id, "bytes=%ld", bytes)
    }
    func cancelWaiting() {
        os_signpost(.end, log: Self.log, name: "DecodeQueueWait", signpostID: id, "outcome=cancelled")
    }
    func decode(_ request: ImageDecodeRequest, decoder: any ImageDecoding) -> Result<DecodedImage, Error> {
        let unnecessary = lock.withLock { cancelled }
        os_signpost(.end, log: Self.log, name: "DecodeQueueWait", signpostID: id, "outcome=%{public}s", unnecessary ? "cancelled" : "success")
        if unnecessary { return .failure(CancellationError()) }
        os_signpost(.begin, log: Self.log, name: "Decode", signpostID: id)
        let result = Result { try decoder.decode(request) }
        let status = outcome(result)
        let bytes: Int
        let width: Int, height: Int
        let format: String
        switch result {
        case .success(let image):
            bytes = image.image.bytesPerRow * image.image.height
            width = image.image.width; height = image.image.height
            format = image.formatIdentifier ?? "unknown"
        case .failure: bytes = 0; width = 0; height = 0; format = "unknown"
        }
        os_signpost(.end, log: Self.log, name: "Decode", signpostID: id, "outcome=%{public}s bytes=%ld pixels=%ldx%ld format=%{public}s", status, bytes, width, height, format)
        let logger = Logger(subsystem: "io.github.anzchy.mado", category: "decode")
        logger.notice("Decode outcome=\(status, privacy: .public) bytes=\(bytes, privacy: .public) pixels=\(width, privacy: .public)x\(height, privacy: .public) format=\(format, privacy: .public) file=\(request.fileURL.lastPathComponent, privacy: .private)")
        return result
    }
    /// Ends an interval for a reservation held outside the executor (a disk-cache payload decode).
    func staged(_ name: StaticString) {
        os_signpost(.end, log: Self.log, name: name, signpostID: id, "outcome=staged")
    }
    func release(_ result: Result<DecodedImage, Error>) {
        os_signpost(.end, log: Self.log, name: "MemoryReservation", signpostID: id, "outcome=%{public}s", outcome(result))
    }
    private func outcome(_ result: Result<DecodedImage, Error>) -> String {
        if lock.withLock({ cancelled }) { return "cancelled" }
        switch result {
        case .success: return "success"
        case .failure: return "failed"
        }
    }
}
