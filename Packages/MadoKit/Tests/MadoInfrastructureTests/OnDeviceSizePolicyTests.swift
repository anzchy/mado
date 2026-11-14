import Foundation
import Testing
@testable import MadoInfrastructure

private func tallNarrowFixture() throws -> Data {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    return try Data(contentsOf: root.appendingPathComponent("TestAssets/TextRecognition/mixed-tall-narrow.jpg"))
}

@Test(.timeLimit(.minutes(2)))
func issue687Fix2TallNarrowImageKeepsItsWidth() throws {
    let bytes = try tallNarrowFixture()
    let (prepared, _) = try OnDeviceTextRecognitionProvider.preparedImage(bytes)
    #expect(prepared.width == 1170)
    #expect(prepared.height == 12000)
}

@Test(.timeLimit(.minutes(2)))
func issue687Fix2HugeImageStillHasBoundedPixelCount() {
    let limit = OnDeviceTextRecognitionProvider.thumbnailLimit(width: 8000, height: 8000)
    #expect(limit < 8000)
    #expect(limit * limit <= 40_000_000)
    #expect(OnDeviceTextRecognitionProvider.thumbnailLimit(width: 1170, height: 12000) == 12000)
}
