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
    private let cancelRequest: (@Sendable (VNRecognizeTextRequest) -> Void)?

    public init() {
        performRequest = { handler, request in try handler.perform([request]) }
        beforePerform = {}
        cancelRequest = nil
    }

    init(
        performRequest: @escaping @Sendable (VNImageRequestHandler, VNRecognizeTextRequest) throws -> Void,
        beforePerform: @escaping @Sendable () async -> Void = {},
        cancelRequest: (@Sendable (VNRecognizeTextRequest) -> Void)? = nil
    ) {
        self.performRequest = performRequest
        self.beforePerform = beforePerform
        self.cancelRequest = cancelRequest
    }

    public func recognise(_ image: Data) async throws(TextRecognitionError) -> String {
        let worker = Task.detached(priority: .userInitiated) { () throws -> String in
            try Task.checkCancellation()
            let (cgImage, orientation) = try Self.preparedImage(image)

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
            try await withTaskCancellationHandler {
                await beforePerform()
                try performRequest(handler, request)
            } onCancel: {
                if let cancelRequest { cancelRequest(request) }
                else { request.cancel() }
            }
            try Task.checkCancellation()

            var boxes: [RecognizedTextBox] = []
            if let results = request.results {
                for observation in results {
                    if let candidate = observation.topCandidates(1).first {
                        boxes.append(RecognizedTextBox(text: candidate.string, bounds: observation.boundingBox))
                    }
                }
            }
            return Self.readingOrder(boxes).map(\.text).joined(separator: "\n")
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
            throw error
        } catch {
            if Task.isCancelled { throw .cancelled }
            let detail = error as NSError
            throw .recognitionFailed(domain: detail.domain, code: detail.code)
        }
    }

    static func preparedImage(_ image: Data) throws -> (CGImage, CGImagePropertyOrientation) {
        guard let source = CGImageSourceCreateWithData(image as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096,
                kCGImageSourceCreateThumbnailWithTransform: false
              ] as CFDictionary) else {
            throw TextRecognitionError.invalidImage
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let rawOrientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        return (cgImage, CGImagePropertyOrientation(rawValue: rawOrientation)!)
    }

}
