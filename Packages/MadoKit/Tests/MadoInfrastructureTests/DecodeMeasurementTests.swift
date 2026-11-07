import CoreGraphics
import Darwin
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import MadoCore
import MadoInfrastructure

private func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    precondition(status == KERN_SUCCESS)
    return info.phys_footprint
}
private final class FootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private let timer: DispatchSourceTimer
    init() {
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "mado.measure.footprint"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
    }
    func sample() { let bytes = footprint(); lock.withLock { peak = max(peak, bytes) } }
    func stop() -> UInt64 { timer.cancel(); sample(); return lock.withLock { peak } }
}
private final class MeasuredDecoder: ImageDecoding, @unchecked Sendable {
    private let lock = NSLock()
    private var last = 0.0
    var milliseconds: Double { lock.withLock { last } }
    func decode(_ request: ImageDecodeRequest) throws -> DecodedImage {
        let start = ContinuousClock.now
        let result = try ImageIODecoder().decode(request)
        let time = elapsed(start)
        lock.withLock { last = time }
        return result
    }
}
private func elapsed(_ start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: .now).components
    return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
}
private func summary(_ values: [Double]) -> String {
    let sorted = values.sorted()
    return "n=\(sorted.count) min=\(sorted.first!) p50=\(sorted[Int(ceil(Double(sorted.count) * 0.50)) - 1]) p95=\(sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]) max=\(sorted.last!)"
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PICSEE_DECODE_MEASURE"] == "1"))
func measureRealPhotoDecodesAndConcurrency() async throws {
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".picsee/testassets/photos")
    let jpeg = root.appendingPathComponent("5B_JPEG_SDR.jpg")
    let heic = root.appendingPathComponent("3B_HEIC_SDR.heic")
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("mado-measure-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    var inputs: [(String, URL, Int)] = [("real-45.4MP-jpeg", jpeg, 8256), ("real-45.4MP-heic", heic, 8256)]
    for (label, edge) in [("derived-about12MP", 4240), ("derived-about2MP", 1728)] {
        let image = try ImageIODecoder().decode(ImageDecodeRequest(fileURL: jpeg, maximumPixelSize: edge)).image
        let file = temporary.appendingPathComponent(label).appendingPathExtension("jpg")
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        inputs.append((label, file, edge))
        print("DERIVED label=\(label) from=5B_JPEG_SDR.jpg source=8256x5504 output=\(image.width)x\(image.height) jpegQuality=0.9")
    }
    print("CONDITIONS Release; no Mado cache; OS page cache uncontrolled/warm from derivation; 30 repetitions; decode requests use source longest edge; requestMs includes header+admission+decode+delivery; decodeMs is the synchronous ImageIODecoder call; footprint sampled every 1ms (observed peak, may miss shorter peaks)")
    for (label, file, edge) in inputs {
        let decoder = MeasuredDecoder()
        let pipeline = ImageIOPipeline(decoder: decoder)
        var times: [Double] = []
        for sample in 1...30 {
            let start = ContinuousClock.now
            let result = try await pipeline.image(for: ImageDecodeRequest(fileURL: file, maximumPixelSize: edge))
            let milliseconds = elapsed(start)
            times.append(decoder.milliseconds)
            print("DECODE label=\(label) sample=\(sample) source=\(Int(result.sourcePixelSize.width))x\(Int(result.sourcePixelSize.height)) output=\(result.image.width)x\(result.image.height) bytes=\(result.image.bytesPerRow * result.image.height) format=\(result.formatIdentifier ?? "unknown") decodeMs=\(decoder.milliseconds) requestMs=\(milliseconds)")
        }
        print("DECODE_SUMMARY label=\(label) ms \(summary(times))")
    }
    // Each trial uses a fresh pipeline. Two background photo-derived requests are
    // either absent or submitted as prefetch; the current image gets a 512px preview.
    // The 12MP request stays below the heavy threshold; the real photo is heavy.
    for workers in 1...3 {
        for prefetch in [false, true] {
            var times: [Double] = [], peaks: [Double] = []
            for sample in 1...30 {
                let pipeline = ImageIOPipeline(configuration: DecodeConfiguration(workers: workers))
                let sampler = FootprintSampler()
                let baseline = footprint()
                let background = inputs.suffix(2).map { entry in
                    Task {
                        if prefetch {
                            _ = try await pipeline.image(for: ImageDecodeRequest(fileURL: entry.1, maximumPixelSize: entry.2, priority: .prefetch))
                        }
                    }
                }
                let start = ContinuousClock.now
                let image = try await pipeline.image(for: ImageDecodeRequest(fileURL: jpeg, maximumPixelSize: 512, isPreview: true))
                let first = elapsed(start)
                // Also complete viewport refinement before sampling ends.
                _ = try await pipeline.image(for: ImageDecodeRequest(fileURL: jpeg, maximumPixelSize: 1920))
                // N=1 reserves its only slot for current work; cancel unadmitted prefetch.
                if workers == 1 { background.forEach { $0.cancel() } }
                for task in background { do { try await task.value } catch { #expect(error is CancellationError) } }
                let peak = sampler.stop()
                times.append(first); peaks.append(Double(peak))
                print("CONCURRENCY N=\(workers) heavy=1 prefetch=\(prefetch) sample=\(sample) firstPreviewMs=\(first) preview=\(image.image.width)x\(image.image.height) baselineFootprint=\(baseline) observedPeakFootprint=\(peak)")
            }
            print("CONCURRENCY_SUMMARY N=\(workers) heavy=1 prefetch=\(prefetch) firstPreviewMs \(summary(times)) footprintBytes \(summary(peaks))")
        }
    }
}
