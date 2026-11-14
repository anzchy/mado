import Foundation
import ImageIO
import MadoApplication
@preconcurrency import Vision

public struct OnDeviceTextRecognitionProvider: OnDeviceTextRecognitionProviding {
    private let performRequest: @Sendable (VNImageRequestHandler, VNRecognizeTextRequest) throws -> Void
    private let beforePerform: @Sendable () async -> Void

    public init() {
        performRequest = { handler, request in try handler.perform([request]) }
        beforePerform = {}
    }

    init(
        performRequest: @escaping @Sendable (VNImageRequestHandler, VNRecognizeTextRequest) throws -> Void,
        beforePerform: @escaping @Sendable () async -> Void = {}
    ) {
        self.performRequest = performRequest
        self.beforePerform = beforePerform
    }

    public func recognise(_ image: Data) async throws(TextRecognitionError) -> String {
        let worker = Task.detached(priority: .userInitiated) { () throws -> String in
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithData(image as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw TextRecognitionError.invalidImage
            }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cgImage)
            try await withTaskCancellationHandler {
                await beforePerform()
                try performRequest(handler, request)
            } onCancel: {
                request.cancel()
            }
            try Task.checkCancellation()

            var observations: [VNRecognizedTextObservation] = []
            if let results = request.results {
                observations = results.sorted(by: Self.isBefore)
            }
            var lines: [String] = []
            for observation in observations {
                if let candidate = observation.topCandidates(1).first {
                    lines.append(candidate.string)
                }
            }
            return lines.joined(separator: "\n")
        }

        do {
            return try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
        } catch is CancellationError {
            throw .cancelled
        } catch let error as TextRecognitionError {
            throw error
        } catch {
            if Task.isCancelled { throw .cancelled }
            throw .recognitionFailed
        }
    }

    private static func isBefore(_ left: VNRecognizedTextObservation, _ right: VNRecognizedTextObservation) -> Bool {
        if abs(left.boundingBox.midY - right.boundingBox.midY) > 0.02 {
            return left.boundingBox.midY > right.boundingBox.midY
        }
        return left.boundingBox.minX < right.boundingBox.minX
    }
}
