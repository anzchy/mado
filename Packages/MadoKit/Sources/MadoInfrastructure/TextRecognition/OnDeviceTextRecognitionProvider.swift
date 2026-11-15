import Foundation
import ImageIO
import MadoApplication
@preconcurrency import Vision

public struct OnDeviceTextRecognitionProvider: OnDeviceTextRecognitionProviding {
    struct RecognizedTextBox {
        let text: String
        let bounds: CGRect
    }

    static func readingOrder(_ boxes: [RecognizedTextBox]) -> [RecognizedTextBox] {
        let sorted = boxes.sorted {
            if $0.bounds.maxY != $1.bounds.maxY { return $0.bounds.maxY > $1.bounds.maxY }
            if $0.bounds.minX != $1.bounds.minX { return $0.bounds.minX < $1.bounds.minX }
            return $0.text < $1.text
        }
        var rows: [[RecognizedTextBox]] = []
        for box in sorted {
            if let index = rows.firstIndex(where: { row in
                guard let previous = row.last else { return false }
                let overlap = min(previous.bounds.maxY, box.bounds.maxY) - max(previous.bounds.minY, box.bounds.minY)
                return overlap > 0.5 * min(previous.bounds.height, box.bounds.height)
            }) {
                rows[index].append(box)
            } else {
                rows.append([box])
            }
        }
        return rows.flatMap { row in
            row.sorted {
                if $0.bounds.minX != $1.bounds.minX { return $0.bounds.minX < $1.bounds.minX }
                if $0.bounds.maxY != $1.bounds.maxY { return $0.bounds.maxY > $1.bounds.maxY }
                return $0.text < $1.text
            }
        }
    }
    private let performRequest: @Sendable (VNImageRequestHandler, VNRecognizeTextRequest) throws -> Void
    private let beforePerform: @Sendable () async -> Void
    private let cancelRequest: @Sendable (VNRecognizeTextRequest) -> Void
    /// Vision's `perform` is synchronous and can wait on Vision's own queues; it runs here,
    /// never on a Swift cooperative thread, so it cannot starve the pool (#706).
    private let performQueue = DispatchQueue(label: "app.mado.text-recognition.perform", qos: .userInitiated)
    private let selectionQueue = DispatchQueue(label: "app.mado.text-recognition.selection", qos: .utility)

    public init() {
        self.init(performRequest: { handler, request in try handler.perform([request]) })
    }

    init(
        performRequest: @escaping @Sendable (VNImageRequestHandler, VNRecognizeTextRequest) throws -> Void,
        beforePerform: @escaping @Sendable () async -> Void = {},
        cancelRequest: @escaping @Sendable (VNRecognizeTextRequest) -> Void = { $0.cancel() }
    ) {
        self.performRequest = performRequest
        self.beforePerform = beforePerform
        self.cancelRequest = cancelRequest
    }

    public func recognise(_ image: Data) async throws(TextRecognitionError) -> String {
        try await recogniseLines(image, priority: .userInitiated).map(\.text).joined(separator: "\n")
    }

    public func recogniseLines(_ image: Data) async throws(TextRecognitionError) -> [TextRecognitionLine] {
        try await recogniseLines(image, priority: .utility)
    }

    private func recogniseLines(_ image: Data, priority: TaskPriority) async throws(TextRecognitionError) -> [TextRecognitionLine] {
        let worker = Task.detached(priority: priority) { () throws -> [TextRecognitionLine] in
            try Task.checkCancellation()
            let (cgImage, orientation) = try Self.preparedImage(image)

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
            let cancellation = PerformCancellation()
            try await withTaskCancellationHandler {
                await beforePerform()
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                    (priority == .utility ? selectionQueue : performQueue).async {
                        if cancellation.isCancelled { return done.resume(throwing: CancellationError()) }
                        do { try performRequest(handler, request); done.resume() }
                        catch { done.resume(throwing: error) }
                    }
                }
            } onCancel: {
                // Vision's cancel can block until its detector yields; never block the
                // canceller, which may hold the task's status lock (#706).
                cancellation.cancel()
                DispatchQueue.global(qos: .userInitiated).async { cancelRequest(request) }
            }
            try Task.checkCancellation()

            var boxes: [RecognizedTextBox] = []
            var lines: [TextRecognitionLine] = []
            if let results = request.results {
                for observation in results {
                    if let candidate = observation.topCandidates(1).first {
                        boxes.append(RecognizedTextBox(text: candidate.string, bounds: observation.boundingBox))
                        var characterBoxes: [CGRect] = []
                        var start = candidate.string.startIndex
                        for _ in candidate.string {
                            let end = candidate.string.index(after: start)
                            if let rangeBox = try? candidate.boundingBox(for: start..<end) {
                                characterBoxes.append(rangeBox.boundingBox)
                            }
                            start = end
                        }
                        if characterBoxes.count != candidate.string.count { characterBoxes = [] }
                        lines.append(TextRecognitionLine(text: candidate.string, box: observation.boundingBox,
                                                         characterBoxes: characterBoxes))
                    }
                }
            }
            let ordered = Self.readingOrder(boxes)
            return ordered.compactMap { box in lines.first { $0.text == box.text && $0.box == box.bounds } }
        }

        do {
            return try await withTaskCancellationHandler {
                let text = try await worker.value
                if Task.isCancelled { throw CancellationError() }
                return text
            } onCancel: {
                worker.cancel()
            }
        } catch is CancellationError {
            throw .cancelled
        } catch let error as TextRecognitionError {
            if Task.isCancelled { throw .cancelled }
            throw error
        } catch {
            if Task.isCancelled { throw .cancelled }
            let detail = error as NSError
            throw .recognitionFailed(domain: detail.domain, code: detail.code)
        }
    }

    static func preparedImage(_ image: Data) throws -> (CGImage, CGImagePropertyOrientation) {
        guard let source = CGImageSourceCreateWithData(image as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0,
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: thumbnailLimit(width: width, height: height),
                kCGImageSourceCreateThumbnailWithTransform: false
              ] as CFDictionary) else {
            throw TextRecognitionError.invalidImage
        }
        let rawOrientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        return (cgImage, orientation(rawValue: rawOrientation))
    }

    static func thumbnailLimit(width: Int, height: Int) -> Int {
        let long = Double(max(width, height))
        let short = Double(min(width, height))
        let pixelCount = Double(width) * Double(height)
        let scale = min(1, 4096 / short, sqrt(40_000_000 / pixelCount))
        return max(1, Int((long * scale).rounded(.down)))
    }

    static func orientation(rawValue: UInt32) -> CGImagePropertyOrientation {
        switch rawValue {
        case 1: .up
        case 2: .upMirrored
        case 3: .down
        case 4: .downMirrored
        case 5: .leftMirrored
        case 6: .right
        case 7: .rightMirrored
        case 8: .left
        default: .up
        }
    }

}

/// Marks a recognition cancelled so a perform still waiting on the serial queue never starts.
private final class PerformCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
