import Foundation
import Testing
import MadoCore
import MadoInfrastructure

private struct ReplacingDecoder: ImageDecoding {
    func decode(_ request: ImageDecodeRequest) throws -> DecodedImage {
        // Deterministically replace the file after the pipeline's admission header
        // was read, but before the real decoder reads its own header.
        try Data(contentsOf: fixture("coordinate-grid.png")).write(to: request.fileURL)
        return try ImageIODecoder().decode(request)
    }
}
@Test(.timeLimit(.minutes(2))) func changedSourceCannotOutgrowItsAdmittedReservation() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data(contentsOf: fixture("alpha-gradient.png")).write(to: file)
    let pipeline = ImageIOPipeline(decoder: ReplacingDecoder())
    await #expect(performing: {
        try await pipeline.image(for: ImageDecodeRequest(fileURL: file, maximumPixelSize: 128))
    }, throws: loadError(.resourceLimit))
}

private struct RevisionChangingDecoder: ImageDecoding {
    func decode(_ request: ImageDecodeRequest) throws -> DecodedImage {
        let image = try ImageIODecoder().decode(request)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_234_567)],
                                             ofItemAtPath: request.fileURL.path)
        return image
    }
}
@Test(.timeLimit(.minutes(2))) func decodedResultCarriesPostDecodeRevision() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data(contentsOf: fixture("alpha-gradient.png")).write(to: file)
    let pipeline = ImageIOPipeline(decoder: RevisionChangingDecoder())
    let request = try await pipeline.request(for: file, maximumPixelSize: 128)
    let decoded = try await pipeline.image(for: request)
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    let expected = FileRevision(byteCount: (attributes[.size] as! NSNumber).intValue,
                                modificationDate: Date(timeIntervalSince1970: 1_234_567),
                                resourceIdentifier: request.renderKey?.revision.resourceIdentifier)
    #expect(decoded.revision == expected)
    #expect(decoded.revision != request.renderKey?.revision)
}
