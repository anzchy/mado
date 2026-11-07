import Foundation
import Testing
import MadoCore
import MadoApplication

private actor LossHeldInspectorReader: InspectorMetadataReading {
    var gate: CheckedContinuation<InspectorMetadata, Never>?
    var completed = false
    func read(_ url: URL, access: AccessRequest) async throws -> InspectorMetadata {
        let result = await withCheckedContinuation { gate = $0 }
        completed = true
        return result
    }
    func release() { gate?.resume(returning: .init(pixelWidth: 300, pixelHeight: 200, thumbnailData: Data([1, 2, 3]))); gate = nil }
    var held: Bool { gate != nil }
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue233InspectorClearRejectsReleasedMetadataAndThumbnail() async throws {
    let reader = LossHeldInspectorReader()
    let model = InspectorModel(reader: reader)
    let url = URL(fileURLWithPath: "/tmp/lost.png")
    model.select(itemID: nil, url: url, access: .fileGrant(url))
    try await waitUntil { await reader.held }
    #expect(model.name == "lost.png")
    #expect(model.value == .loading)
    model.select(itemID: nil, url: nil, access: nil)
    #expect(model.name == nil)
    #expect(model.value == .unknown)
    await reader.release()
    try await waitUntil { await reader.completed }
    #expect(await reader.completed)
    // Give the model's awaiting task a main-actor turn after the reader has returned.
    try? await Task.sleep(for: .milliseconds(20))
    #expect(model.name == nil)
    #expect(model.value == .unknown)
}
