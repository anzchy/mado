import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

@Test func statesHeaderWithoutIENDIsRejectedDeterministically() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("missing-iend.png")
    // Complete 1×1 RGBA IHDR with its valid CRC; no IEND chunk follows it.
    let header: [UInt8] = [137,80,78,71,13,10,26,10, 0,0,0,13, 73,72,68,82,
        0,0,0,1, 0,0,0,1, 8,6,0,0,0, 31,21,196,137]
    try Data(header).write(to: file)
    #expect((try Data(contentsOf: file)).count == 33)
    // At size 33 the IHDR length guard succeeds exactly (13 == 33 - 8 - 12),
    // advances offset to EOF, and can only throw from requireCompletePNG's loop exit.
    #expect(throws: ImageDecodeError.unreadableImage) {
        try ImageSourceHeader.read(ImageDecodeRequest(fileURL: file, maximumPixelSize: 1),
            budget: 1_000_000, itemID: .ephemeral(UUID()))
    }
}
