import Foundation

public enum TextRecognitionIntent: Sendable {
    case selection
    case explicit
}

public enum TextRecognitionEngine: Sendable {
    case onDevice
    case cloud
}

public enum TextRecognitionError: Error, Equatable, Sendable {
    case invalidImage
    case cancelled
    case recognitionFailed
}

public struct TextRecognitionResult: Sendable {
    public let text: String
    public let characterCount: Int
    public let engine: TextRecognitionEngine
    public let isEmpty: Bool

    public init(text: String, characterCount: Int, engine: TextRecognitionEngine, isEmpty: Bool) {
        self.text = text
        self.characterCount = characterCount
        self.engine = engine
        self.isEmpty = isEmpty
    }
}

public protocol OnDeviceTextRecognitionProviding: Sendable {
    func recognise(_ image: Data) async throws(TextRecognitionError) -> String
}

public protocol CloudTextRecognitionProviding: Sendable {
    func recognise(_ image: Data) async throws(TextRecognitionError) -> String
}

public struct TextRecognitionService: Sendable {
    private let onDevice: any OnDeviceTextRecognitionProviding

    public init(onDevice: any OnDeviceTextRecognitionProviding) {
        self.onDevice = onDevice
    }

    public func recognise(_ image: Data, intent: TextRecognitionIntent) async throws(TextRecognitionError) -> TextRecognitionResult {
        let text = try await onDevice.recognise(image)
        return TextRecognitionResult(
            text: text,
            characterCount: text.count,
            engine: .onDevice,
            isEmpty: text.isEmpty
        )
    }
}
