import Foundation
import ImageIO
import Testing
@testable import MadoInfrastructure
import MadoApplication

private func fixFixture(_ name: String) throws -> Data {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    return try Data(contentsOf: root.appendingPathComponent("TestAssets/TextRecognition/\(name)"))
}

@Test(.timeLimit(.minutes(2)))
func issue687FixOrientationSixRecognisesUprightText() async throws {
    let bytes = try fixFixture("mixed-orientation-6.jpg")
    let (_, orientation) = try OnDeviceTextRecognitionProvider.preparedImage(bytes)
    #expect(orientation == .right)
    let text = try await OnDeviceTextRecognitionProvider().recognise(bytes)
    #expect(text.contains("中文"))
    #expect(text.contains("Hello Mado"))
}

@Test(.timeLimit(.minutes(2)))
func issue687FixOversizeInputIsCappedAndRecognised() async throws {
    let bytes = try fixFixture("mixed-oversize.jpg")
    let (prepared, _) = try OnDeviceTextRecognitionProvider.preparedImage(bytes)
    #expect(max(prepared.width, prepared.height) <= 4096)
    let text = try await OnDeviceTextRecognitionProvider().recognise(bytes)
    #expect(text.contains("Hello Mado"))
}
