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
    // Round 2 replaces the long-edge cap with a short-edge and total-pixel cap.
    #expect(max(prepared.width, prepared.height) <= 5000)
    #expect(prepared.width * prepared.height <= 40_000_000)
    let text = try await OnDeviceTextRecognitionProvider().recognise(bytes)
    #expect(text.contains("Hello Mado"))
}

@Test(.timeLimit(.minutes(2)))
func issue687FixDenseFortyLineFixtureKeepsIndentedRowInOrder() async throws {
    let text = try await OnDeviceTextRecognitionProvider().recognise(fixFixture("dense-40.png"))
    let compact = text.replacingOccurrences(of: " ", with: "")
    let previous = try #require(compact.range(of: "LINE18"))
    let indented = try #require(compact.range(of: "LINE19"))
    let next = try #require(compact.range(of: "LINE20"))
    #expect(previous.lowerBound < indented.lowerBound)
    #expect(indented.lowerBound < next.lowerBound)
    #expect(text.split(separator: "\n").count >= 35)
}
