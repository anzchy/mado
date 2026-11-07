import AppKit
import Foundation
import Testing
import MadoInfrastructure

private final class DiskPortVolumeSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var volumes: [AccessProbeVolume]
    private var reads = 0
    init(_ volumes: [AccessProbeVolume]) { self.volumes = volumes }
    func get() -> [AccessProbeVolume] {
        lock.withLock { reads += 1; return volumes }
    }
    func set(_ volumes: [AccessProbeVolume]) { lock.withLock { self.volumes = volumes } }
    var readCount: Int { lock.withLock { reads } }
}

@MainActor private final class DiskPortEventSink {
    var values: [DiskMountEvent] = []
    private var waiters: [UUID: (count: Int, continuation: CheckedContinuation<Bool, Never>)] = [:]
    func consume(_ stream: AsyncStream<DiskMountEvent>) -> Task<Void, Never> {
        Task { @MainActor in
            for await event in stream {
                values.append(event)
                for id in Array(waiters.keys) where values.count >= waiters[id]!.count {
                    waiters.removeValue(forKey: id)?.continuation.resume(returning: true)
                }
            }
            for id in Array(waiters.keys) {
                waiters.removeValue(forKey: id)?.continuation.resume(returning: false)
            }
        }
    }
    func receipt(of count: Int) async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if values.count >= count { continuation.resume(returning: true) }
                else if Task.isCancelled { continuation.resume(returning: false) }
                else { waiters[id] = (count, continuation) }
            }
        } onCancel: {
            Task { @MainActor in self.waiters.removeValue(forKey: id)?.continuation.resume(returning: false) }
        }
    }
}

@MainActor private func diskPortWaitForEvents(_ count: Int, in sink: DiskPortEventSink) async {
    // Notification delivery and consumption share MainActor with the full native
    // test suite. Await receipt without racing scheduler latency against a timer;
    // the enclosing test's time limit still bounds a truly missing event.
    let received = await sink.receipt(of: count)
    #expect(received)
}

@MainActor private func diskPortWait(_ condition: @MainActor () -> Bool) async {
    // This acknowledgement can also be delayed behind MainActor work. Use the
    // enclosing test's cancellation rather than another wall-clock deadline.
    while !condition(), !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(condition())
}

private func diskPortVolume(_ uuid: String?, path: String, name: String = "Photos") -> AccessProbeVolume {
    AccessProbeVolume(uuid: uuid, url: URL(fileURLWithPath: path, isDirectory: true), name: name)
}

@MainActor @Test func t229DiskPortDefaultProviderIncludesTheRealTemporaryDirectoryVolume() async throws {
    let center = NotificationCenter()
    let port = SystemDiskMountPort(center: center)
    defer { port.stop() }
    let temporaryVolumeUUID = try #require(FileManager.default.temporaryDirectory
        .resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
    let mounted = await port.mountedVolumes()
    #expect(mounted.contains { $0.uuid == temporaryVolumeUUID })
    #expect(mounted.filter { $0.uuid == temporaryVolumeUUID }.allSatisfy { $0.url?.isFileURL == true })
}

@MainActor @Test(.timeLimit(.minutes(3)))
func t229DiskPortMissingURLDiffEmitsOnlyRemovedUUIDsAndDoesNotRepeatThem() async {
    let removed = diskPortVolume("removed", path: "/Volumes/Removed")
    let retained = diskPortVolume("retained", path: "/Volumes/Retained")
    let unidentified = diskPortVolume(nil, path: "/Volumes/NoIdentity")
    let snapshot = DiskPortVolumeSnapshot([removed, retained, unidentified])
    let center = NotificationCenter()
    let port = SystemDiskMountPort(center: center, mountedVolumes: { snapshot.get() })
    let sink = DiskPortEventSink()
    let consumption = sink.consume(await port.events())

    snapshot.set([retained])
    center.post(name: NSWorkspace.didUnmountNotification, object: nil)
    await diskPortWaitForEvents(1, in: sink)
    #expect(sink.values == [.unmounted(removed)])

    let readsBeforeDuplicate = snapshot.readCount
    center.post(name: NSWorkspace.didUnmountNotification, object: nil)
    await diskPortWait { snapshot.readCount > readsBeforeDuplicate }
    port.stop()
    await consumption.value
    #expect(sink.values == [.unmounted(removed)])
    #expect(await port.mountedVolumes() == [retained])
}

@MainActor @Test(.timeLimit(.minutes(3)))
func t229DiskPortUnknownUnmountURLUsesUUIDDiffAndStopFinishesBufferedEvents() async {
    let first = diskPortVolume("first", path: "/Volumes/First")
    let second = diskPortVolume("second", path: "/Volumes/Second")
    let snapshot = DiskPortVolumeSnapshot([first, second])
    let center = NotificationCenter()
    let port = SystemDiskMountPort(center: center, mountedVolumes: { snapshot.get() })
    let sink = DiskPortEventSink()
    let consumption = sink.consume(await port.events())

    snapshot.set([])
    center.post(name: NSWorkspace.didUnmountNotification, object: nil,
        userInfo: [NSWorkspace.volumeURLUserInfoKey: URL(fileURLWithPath: "/Volumes/Unknown")])
    await diskPortWaitForEvents(2, in: sink)
    port.stop()
    port.stop()
    await consumption.value
    #expect(sink.values.count == 2)
    #expect(sink.values.contains(.unmounted(first)))
    #expect(sink.values.contains(.unmounted(second)))

    // Stopping finishes future subscribers too; later OS notifications cannot
    // repopulate the terminated event stream.
    snapshot.set([first, second])
    center.post(name: NSWorkspace.didMountNotification, object: nil)
    center.post(name: NSWorkspace.didUnmountNotification, object: nil)
    var iterator = await port.events().makeAsyncIterator()
    #expect(await iterator.next() == nil)
}
