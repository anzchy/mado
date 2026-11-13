import CoreGraphics
import Foundation
import Testing
import MadoCore
import MadoInfrastructure

final class ControlledExecutor: DecodeExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var work: [@Sendable () -> Void] = []
    func submit(_ block: @escaping @Sendable () -> Void) { lock.withLock { work.append(block) } }
    var count: Int { lock.withLock { work.count } }
    func runFirst() { let block = lock.withLock { work.removeFirst() }; block() }
}
struct TinyDecoder: ImageDecoding {
    func decode(_ request: ImageDecodeRequest) throws -> DecodedImage {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return DecodedImage(image: context.makeImage()!, sourcePixelSize: CGSize(width: 1, height: 1))
    }
}
func decodeKey(_ number: Int) -> RenderKey {
    RenderKey(itemID: ItemID.ephemeral(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!),
              revision: FileRevision(byteCount: 1, modificationDate: nil), maximumPixelSize: 1)
}
let tinyRequest = ImageDecodeRequest(fileURL: URL(fileURLWithPath: "/unused"), maximumPixelSize: 1)

@Test(.timeLimit(.minutes(2))) func admissionReservesCurrentSlotAndAllPermitsAtomically() async throws {
    let executor = ControlledExecutor()
    let admission = DecodeAdmission(configuration: DecodeConfiguration(budget: 30), executor: executor, decoder: TinyDecoder())
    let a = await admission.subscribe(tinyRequest, key: decodeKey(1), cost: 10, heavy: true, priority: .visible)
    let b = await admission.subscribe(tinyRequest, key: decodeKey(2), cost: 10, heavy: false, priority: .visible)
    _ = await admission.subscribe(tinyRequest, key: decodeKey(3), cost: 10, heavy: false, priority: .prefetch)
    _ = await admission.subscribe(tinyRequest, key: decodeKey(4), cost: 10, heavy: true, priority: .current)
    let c = await admission.subscribe(tinyRequest, key: decodeKey(5), cost: 10, heavy: false, priority: .current)
    let activity = await admission.activity()
    #expect(executor.count == 3)
    #expect(activity.running == 3 && activity.nonCurrent == 2 && activity.visible == 2)
    #expect(activity.heavy == 1 && activity.reservedBytes == 30 && activity.waiting == 2)
    // A priority change cannot change resources already taken at admission.
    await a.raisePriority(to: .current)
    #expect(await admission.activity().nonCurrent == 2)
    // Real completion, not a consumer event, allows the next highest priority task.
    if executor.count == 3 {
        executor.runFirst(); _ = try await a.value()
        #expect(await admission.activity().heavy == 1)
        executor.runFirst(); _ = try await b.value()
        executor.runFirst(); _ = try await c.value()
        while executor.count > 0 { executor.runFirst(); await Task.yield() }
    }
}
