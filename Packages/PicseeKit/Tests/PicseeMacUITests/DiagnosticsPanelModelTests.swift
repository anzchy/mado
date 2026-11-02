import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
import PicseeCore
@testable import PicseeInfrastructure
@testable import PicseeMacUI

/// Returns the queued snapshots in turn (the last one repeats) and counts reads.
/// While `hold` is set, each read waits for `releaseReads()`.
private final class ScriptedDiagnostics: DiagnosticsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [DiagnosticsSnapshot]
    private var count = 0
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []
    init(_ script: [DiagnosticsSnapshot]) { self.script = script }
    /// Set before the source is shared; called with the read count when the source is released.
    var released: (@Sendable (Int) -> Void)?
    deinit { released?(count) }
    var reads: Int { lock.withLock { count } }
    var heldReads: Int { lock.withLock { held.count } }
    func hold() { lock.withLock { holding = true } }
    func releaseReads() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            holding = false
            defer { held.removeAll() }
            return held
        }
        for reader in waiting { reader.resume() }
    }
    func diagnostics() async -> DiagnosticsSnapshot {
        let (snapshot, mustHold) = lock.withLock { () -> (DiagnosticsSnapshot, Bool) in
            count += 1
            return (script.count > 1 ? script.removeFirst() : script[0], holding)
        }
        if mustHold { await withCheckedContinuation { reader in lock.withLock { held.append(reader) } } }
        return snapshot
    }
}

/// The read count a released `ScriptedDiagnostics` reports; nil until then.
private final class ReadsAtRelease: @unchecked Sendable {
    private let lock = NSLock()
    private var reads: Int?
    var value: Int? { lock.withLock { reads } }
    func set(_ count: Int) { lock.withLock { reads = count } }
}

/// An injected clock: every sleep waits for `advance()`, and a cancelled sleep throws.
private final class ManualSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var cancelledEarly: Set<UUID> = []
    private var asked: [Duration] = []
    private var cancelledCount = 0
    private var waiters: [UUID: (count: Int, waiter: CheckedContinuation<Bool, Never>)] = [:]
    var requested: [Duration] { lock.withLock { asked } }
    var pendingCount: Int { lock.withLock { pending.count } }
    var cancelled: Int { lock.withLock { cancelledCount } }
    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (sleeper: CheckedContinuation<Void, Error>) in
                let (early, reached) = lock.withLock { () -> (Bool, [CheckedContinuation<Bool, Never>]) in
                    asked.append(duration)
                    if cancelledEarly.remove(id) != nil { cancelledCount += 1; return (true, []) }
                    pending[id] = sleeper
                    let reached = waiters.filter { $0.value.count <= asked.count }
                    for key in reached.keys { waiters[key] = nil }
                    return (false, reached.values.map(\.waiter))
                }
                if early { sleeper.resume(throwing: CancellationError()) }
                for waiter in reached { waiter.resume(returning: true) }
            }
        } onCancel: {
            let sleeper = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                guard let sleeper = pending.removeValue(forKey: id) else { cancelledEarly.insert(id); return nil }
                cancelledCount += 1
                return sleeper
            }
            sleeper?.resume(throwing: CancellationError())
        }
    }
    /// Whether the `count`-th sleep comes to be requested and pending. The sleep itself resumes the waiter, so the
    /// wait needs no main-actor turn and no wall-clock deadline: a poll against a deadline failed on a loaded CI
    /// runner, where the main actor every @MainActor test shares was too busy to give the refresh loop its turns
    /// before the deadline passed. False only when the waiting task is cancelled (the suite's time limit bounds it).
    func sleeping(_ count: Int) async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (waiter: CheckedContinuation<Bool, Never>) in
                let ready = lock.withLock { () -> Bool? in
                    if Task.isCancelled { return false }
                    if asked.count >= count && !pending.isEmpty { return true }
                    waiters[id] = (count, waiter)
                    return nil
                }
                if let ready { waiter.resume(returning: ready) }
            }
        } onCancel: {
            lock.withLock { waiters.removeValue(forKey: id)?.waiter }?.resume(returning: false)
        }
    }
    func advance() {
        let sleepers = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            defer { pending.removeAll() }
            return Array(pending.values)
        }
        for sleeper in sleepers { sleeper.resume() }
    }
}

/// Waits for a condition the sleeper can't signal, sleeping between looks so the polls add little to a busy main
/// actor. Bounded like `waitUntil`: throws when the wait ends before the condition holds (#392).
@MainActor private func until(_ condition: @MainActor () -> Bool) async throws -> Bool {
    try await waitUntil { condition() }
    return condition()
}

@MainActor private func value(_ model: DiagnosticsPanelModel, _ id: String) -> String? {
    model.sections.flatMap(\.rows).first { $0.id == id }?.value
}

private let fullSnapshot = DiagnosticsSnapshot(
    budget: .init(limit: 536_870_912, pinned: 1_024, evictable: 2_048, staging: 12_288, peak: 40_960),
    memoryCache: .init(entries: 3, bytes: 3_072, hits: 7, misses: 2),
    diskCache: .init(entries: 5, storedBytes: 81_920, hits: 4, misses: 6),
    decoding: .init(running: 1, waiting: 2, finished: 9))

private func catalogValue(_ key: String, _ language: String) throws -> String? {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("App/Resources/Localizable.xcstrings"))
    let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let strings = try #require(catalog["strings"] as? [String: Any])
    let localizations = (strings[key] as? [String: Any])?["localizations"] as? [String: Any]
    return ((localizations?[language] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
}

@Suite(.timeLimit(.minutes(2))) @MainActor struct DiagnosticsPanelModelTests {
    @Test func diagnosticsPanelShowsUnknownForEveryMissingValue() async throws {
        let source = ScriptedDiagnostics([DiagnosticsSnapshot(
            diskCache: .init(entries: nil, storedBytes: nil, hits: 4, misses: 6),
            decoding: .init(running: 1, waiting: 2, finished: 9))])
        let sleeper = ManualSleeper()
        let model = DiagnosticsPanelModel(source: source, sleep: { try await sleeper.sleep($0) })
        let ids = ["budget.limit", "budget.pinned", "budget.evictable", "budget.staging", "budget.peak",
                   "memory.entries", "memory.size", "memory.hits", "memory.misses",
                   "disk.entries", "disk.size", "disk.hits", "disk.misses",
                   "decoding.running", "decoding.waiting", "decoding.finished"]
        // Before the first read nothing is known.
        #expect(model.sections.flatMap(\.rows).map(\.id) == ids)
        #expect(model.sections.flatMap(\.rows).allSatisfy { $0.value == DiagnosticsPanelModel.unknown })
        #expect(DiagnosticsPanelModel.unknown == "Unknown")

        model.setVisible(true)
        try #require(await sleeper.sleeping(1))
        for id in ids.prefix(11) { #expect(value(model, id) == "Unknown", "\(id)") }
        #expect(value(model, "disk.hits") == "4" && value(model, "disk.misses") == "6")
        #expect(value(model, "decoding.running") == "1" && value(model, "decoding.waiting") == "2")
        #expect(value(model, "decoding.finished") == "9")
        model.setVisible(false)
    }

    @Test func diagnosticsPanelRendersCountsAndSizes() async throws {
        let source = ScriptedDiagnostics([fullSnapshot])
        let sleeper = ManualSleeper()
        let model = DiagnosticsPanelModel(source: source, sleep: { try await sleeper.sleep($0) })
        model.setVisible(true)
        try #require(await sleeper.sleeping(1))
        let memory = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) }
        #expect(value(model, "budget.limit") == memory(536_870_912))
        #expect(value(model, "budget.pinned") == memory(1_024))
        #expect(value(model, "budget.evictable") == memory(2_048))
        #expect(value(model, "budget.staging") == memory(12_288))
        #expect(value(model, "budget.peak") == memory(40_960))
        #expect(value(model, "memory.entries") == "3" && value(model, "memory.size") == memory(3_072))
        #expect(value(model, "memory.hits") == "7" && value(model, "memory.misses") == "2")
        #expect(value(model, "disk.entries") == "5")
        #expect(value(model, "disk.size") == ByteCountFormatter.string(fromByteCount: 81_920, countStyle: .file))
        #expect(value(model, "disk.hits") == "4" && value(model, "disk.misses") == "6")
        #expect(model.sections.map(\.id) == ["budget", "memory", "disk", "decoding"])
        model.setVisible(false)
    }

    @Test func diagnosticsPanelTitlesAreBilingual() throws {
        let model = DiagnosticsPanelModel(source: ScriptedDiagnostics([fullSnapshot]))
        let keys = model.sections.map(\.title) + model.sections.flatMap(\.rows).map(\.title) + [DiagnosticsPanelModel.unknown, "Diagnostics"]
        for key in keys {
            #expect(try catalogValue(key, "en")?.isEmpty == false, "English translation required for \(key)")
            let chinese = try catalogValue(key, "zh-Hans")
            #expect(chinese?.isEmpty == false && chinese != key, "Chinese translation required for \(key)")
        }
        #expect(try catalogValue("Unknown", "zh-Hans") == "未知")
    }

    @Test func diagnosticsPanelShowsNoPathFromARealFolder() async throws {
        let folderName = "Private-\(UUID().uuidString)"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("secret-name.png")
        let context = try #require(CGContext(data: nil, width: 96, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))

        let disk = ThumbnailDiskCache(directory: folder.appendingPathComponent("cache"))
        let pipeline = ImageIOPipeline(thumbnailCache: disk)
        let root = ItemIdentityRoot(id: AccessRootID(), url: folder)
        let request = try await pipeline.request(for: file, maximumPixelSize: 32, identityRoot: root)
        let image = try await pipeline.image(for: request)
        _ = try await pipeline.image(for: request)
        let ticket = try #require(try await disk.prepare(request))
        _ = try await disk.load(ticket)
        try await disk.store(image, for: ticket)
        _ = try await disk.load(ticket)

        let sleeper = ManualSleeper()
        let model = DiagnosticsPanelModel(source: pipeline, sleep: { try await sleeper.sleep($0) })
        model.setVisible(true)
        try #require(await sleeper.sleeping(1))
        model.setVisible(false)
        let rows = model.sections.flatMap(\.rows)
        // The read was real: these figures came from the folder's loads.
        #expect(value(model, "memory.hits") == "1" && value(model, "disk.hits") == "1" && value(model, "disk.entries") == "1")
        let shown = model.sections.flatMap { [$0.id, $0.title] } + rows.flatMap { [$0.id, $0.title, $0.value] }
        for text in shown {
            #expect(!text.contains("/"), "path separator in \(text)")
            #expect(!text.contains(NSHomeDirectory()), "home directory in \(text)")
            #expect(!text.contains(folderName) && !text.contains("secret-name"), "file or folder name in \(text)")
        }
    }

    @Test func diagnosticsPanelRefreshesOnItsTimerWhileVisible() async throws {
        let first = fullSnapshot
        var second = fullSnapshot
        second.decoding = .init(running: 0, waiting: 5, finished: 12)
        let source = ScriptedDiagnostics([first, second])
        let sleeper = ManualSleeper()
        let model = DiagnosticsPanelModel(source: source, sleep: { try await sleeper.sleep($0) })
        model.setVisible(true)
        #expect(model.isVisible)
        try #require(await sleeper.sleeping(1))
        #expect(source.reads == 1 && value(model, "decoding.waiting") == "2")
        sleeper.advance()
        try #require(await sleeper.sleeping(2))
        #expect(source.reads == 2 && value(model, "decoding.waiting") == "5" && value(model, "decoding.finished") == "12")
        sleeper.advance()
        try #require(await sleeper.sleeping(3))
        #expect(source.reads == 3)
        #expect(sleeper.requested == [.seconds(1), .seconds(1), .seconds(1)])
        model.setVisible(false)
    }

    @Test func diagnosticsPanelStopsWhenHiddenAndResumesWhenShown() async throws {
        let source = ScriptedDiagnostics([fullSnapshot])
        let sleeper = ManualSleeper()
        let model = DiagnosticsPanelModel(source: source, sleep: { try await sleeper.sleep($0) })
        model.setVisible(true)
        try #require(await sleeper.sleeping(1))
        model.setVisible(false)
        #expect(!model.isVisible)
        try #require(try await until { sleeper.cancelled == 1 && sleeper.pendingCount == 0 })
        sleeper.advance()
        try await Task.sleep(for: .milliseconds(50))
        #expect(source.reads == 1 && sleeper.requested.count == 1)

        model.setVisible(true)
        try #require(await sleeper.sleeping(2))
        #expect(source.reads == 2)
        model.setVisible(false)
    }

    @Test func diagnosticsPanelRunsOneLoopHoweverVisibilityToggles() async throws {
        let source = ScriptedDiagnostics([fullSnapshot])
        let sleeper = ManualSleeper()
        let model = DiagnosticsPanelModel(source: source, sleep: { try await sleeper.sleep($0) })
        model.setVisible(true)
        model.setVisible(true)
        try #require(await sleeper.sleeping(1))
        sleeper.advance()
        try #require(await sleeper.sleeping(2))
        #expect(source.reads == 2 && sleeper.pendingCount == 1)

        // Hide and show while a read is suspended: the old loop must end with its read, not keep going.
        source.hold()
        sleeper.advance()
        try #require(try await until { source.heldReads == 1 })
        model.setVisible(false)
        model.setVisible(true)
        try #require(try await until { source.heldReads == 2 })
        source.releaseReads()
        try #require(await sleeper.sleeping(3))
        try await Task.sleep(for: .milliseconds(50))
        #expect(sleeper.pendingCount == 1 && sleeper.requested.count == 3 && source.reads == 4)
        sleeper.advance()
        try #require(await sleeper.sleeping(4))
        try await Task.sleep(for: .milliseconds(50))
        #expect(source.reads == 5 && sleeper.pendingCount == 1)
        model.setVisible(false)
    }

    @Test func diagnosticsPanelStartsNoReadAfterHidingWhenAPauseHasJustEnded() async throws {
        let source = ScriptedDiagnostics([fullSnapshot])
        let sleeper = ManualSleeper()
        // Only the model and its loop hold the token, so with the model gone the token's release marks the loop's end.
        final class Token: Sendable {}
        var token: Token? = Token()
        weak var loopToken = token
        var model: DiagnosticsPanelModel? = DiagnosticsPanelModel(source: source, sleep: { [token] in
            _ = token
            try await sleeper.sleep($0)
        })
        token = nil
        model?.setVisible(true)
        try #require(await sleeper.sleeping(1))
        #expect(source.reads == 1)

        // The pause ends, but the loop can't take the main actor back before the panel hides in this same turn.
        sleeper.advance()
        model?.setVisible(false)
        model = nil
        try #require(try await until { loopToken == nil })
        #expect(source.reads == 1)
    }
}

@Suite(.timeLimit(.minutes(2))) @MainActor struct DiagnosticsPanelClockTests {
    @Test func diagnosticsPanelDefaultClockRefreshesUntilHidden() async throws {
        // Only the model and its loop hold the source, so with the model gone the source's release marks the loop's
        // end and reports the final count: no wall-clock margin decides whether the loop stopped (#327).
        let released = ReadsAtRelease()
        var source: ScriptedDiagnostics? = ScriptedDiagnostics([fullSnapshot])
        source?.released = { released.set($0) }
        weak var loopSource = source
        var model: DiagnosticsPanelModel? = DiagnosticsPanelModel(source: try #require(source), interval: .milliseconds(10))
        source = nil
        model?.setVisible(true)
        try #require(try await until { (loopSource?.reads ?? 0) >= 3 })
        let readsAtHide = try #require(loopSource).reads
        model?.setVisible(false)
        #expect(value(try #require(model), "decoding.finished") == "9")
        model = nil
        try #require(try await until { released.value != nil })
        // A read already called when the panel hid may count after it; no read starts after it.
        let finalReads = try #require(released.value)
        #expect(finalReads >= readsAtHide && finalReads <= readsAtHide + 1)
    }
}

@Suite(.timeLimit(.minutes(2))) @MainActor struct DiagnosticsPanelIndexCostTests {
    @Test func diagnosticsPanelTicksDoNotScanTheDiskIndexEachTime() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("image.png")
        let context = try #require(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.5, green: 0.3, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        // The disk cache's own clock stands still while the panel ticks.
        let disk = ThumbnailDiskCache(directory: folder.appendingPathComponent("cache"), statsClock: { 500 })
        let pipeline = ImageIOPipeline(thumbnailCache: disk)
        let request = try await pipeline.request(for: file, maximumPixelSize: 32,
                                                 identityRoot: ItemIdentityRoot(id: AccessRootID(), url: folder))
        let ticket = try #require(try await disk.prepare(request))
        try await disk.store(try await pipeline.image(for: request), for: ticket)

        let sleeper = ManualSleeper()
        let model = DiagnosticsPanelModel(source: pipeline, sleep: { try await sleeper.sleep($0) })
        model.setVisible(true)
        for tick in 1...5 {
            try #require(await sleeper.sleeping(tick))
            sleeper.advance()
        }
        model.setVisible(false)
        #expect(value(model, "disk.entries") == "1")
        #expect(await disk.indexScans == 1)
    }
}

/// The accessibility trait set a view carries, read from its value dump (SwiftUI builds no
/// accessibility tree for an offscreen hosting view in a test).
private func traitSets(_ view: some View) -> [String] {
    var text = ""
    dump(view, to: &text)
    let lines = text.components(separatedBy: "\n")
    return lines.indices.compactMap { index in
        guard lines[index].contains("traits: Optional") else { return nil }
        return lines[index...].first { $0.contains("rawValue:") }?.trimmingCharacters(in: .whitespaces)
    }
}

@Test @MainActor func diagnosticsPanelSectionTitlesAreHeadings() {
    let heading = traitSets(Text("x").accessibilityAddTraits(.isHeader))
    #expect(heading.count == 1)
    #expect(traitSets(Text("x")).isEmpty)
    for title in DiagnosticsPanelModel(source: ScriptedDiagnostics([fullSnapshot])).sections.map(\.title) {
        #expect(traitSets(DiagnosticsPanelView.sectionTitle(title)) == heading, "\(title)")
    }
}

@Test @MainActor func diagnosticsPanelViewLaysOutUnknownAndMeasuredRows() async throws {
    _ = NSApplication.shared
    let sleeper = ManualSleeper()
    let model = DiagnosticsPanelModel(source: ScriptedDiagnostics([fullSnapshot]), sleep: { try await sleeper.sleep($0) })
    let host = NSHostingView(rootView: DiagnosticsPanelView(model: model))
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 340, height: 520),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    let unknownSize = host.fittingSize
    #expect(unknownSize.width >= 300 && unknownSize.height >= 360)
    model.setVisible(true)
    try #require(await sleeper.sleeping(1))
    model.setVisible(false)
    host.layoutSubtreeIfNeeded()
    #expect(host.fittingSize.width >= 300 && value(model, "memory.hits") == "7")
}

/// Every request the disk cache can hold (grid thumbnails and viewer images up to 1024 px under a folder grant)
/// loads through it and decodes a durable miss fresh, so only the rest reach the memory lookup.
private let memoryLookupNote = "Hits and misses count memory lookups, made only by images the disk cache can’t hold: larger than 1024 px (such as Actual Pixels), opened as a single file without a folder grant, or not prepared by the disk cache. Everything else counts under Thumbnail Disk Cache; pinned pixels still show in Entries and Size."
private let diskLookupNote = "Counts grid thumbnails and viewer images up to 1024 px from folders you granted."

/// The accessibility label a view value carries, as its dumped text (nil when it has none).
private func accessibilityLabelDump(_ view: some View) -> String? {
    var text = ""
    dump(view, to: &text)
    let lines = text.components(separatedBy: "\n")
    guard let start = lines.firstIndex(where: { $0.contains("label: Optional") }) else { return nil }
    let indent = lines[start].prefix { $0 == " " }.count
    let body = lines[(start + 1)...].prefix { $0.prefix { $0 == " " }.count > indent }
    return ([lines[start]] + body).joined(separator: "\n")
}

@Test @MainActor func diagnosticsPanelHeadingsCarryTheirTitleAsLabel() {
    #expect(accessibilityLabelDump(Text("x").accessibilityAddTraits(.isHeader)) == nil)
    for title in DiagnosticsPanelModel(source: ScriptedDiagnostics([fullSnapshot])).sections.map(\.title) {
        let label = accessibilityLabelDump(DiagnosticsPanelView.sectionTitle(title))
        #expect(label?.contains("key: \"\(title)\"") == true, "\(title): \(label ?? "no label")")
    }
}

@Test @MainActor func diagnosticsPanelNotesNameTheDiskCacheBoundary() throws {
    let sections = DiagnosticsPanelModel(source: ScriptedDiagnostics([fullSnapshot])).sections
    #expect(sections.first { $0.id == "memory" }?.note == memoryLookupNote)
    #expect(sections.first { $0.id == "disk" }?.note == diskLookupNote)
    #expect(sections.filter { !["memory", "disk"].contains($0.id) }.allSatisfy { $0.note == nil })
    for note in [memoryLookupNote, diskLookupNote] {
        #expect(try catalogValue(note, "en") == note)
        let chinese = try catalogValue(note, "zh-Hans")
        #expect(chinese?.isEmpty == false && chinese != note)
    }
}
