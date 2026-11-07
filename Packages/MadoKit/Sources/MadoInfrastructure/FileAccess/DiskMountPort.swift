import Foundation
import AppKit

public enum DiskMountEvent: Equatable, Sendable {
    case mounted(AccessProbeVolume)
    case unmounted(AccessProbeVolume)
}

/// Supplies stable mounted-volume identity and change notifications.
public protocol DiskMountPort: Sendable {
    func mountedVolumes() async -> [AccessProbeVolume]
    func events() async -> AsyncStream<DiskMountEvent>
}

@MainActor public final class SystemDiskMountPort: DiskMountPort {
    private let diagnostics: AccessDiagnostics
    private let center: NotificationCenter
    private let provider: @Sendable () -> [AccessProbeVolume]
    private var knownByPath: [String: AccessProbeVolume]
    private let stream: AsyncStream<DiskMountEvent>
    private let continuation: AsyncStream<DiskMountEvent>.Continuation
    private var observers: [any NSObjectProtocol] = []
    public init(center: NotificationCenter = NSWorkspace.shared.notificationCenter,
                mountedVolumes: @escaping @Sendable () -> [AccessProbeVolume] = {
                    AccessProbeFactGatherer.mountedVolumes(at: FileManager.default.mountedVolumeURLs(
                        includingResourceValuesForKeys: [.volumeUUIDStringKey, .volumeNameKey, .volumeURLKey],
                        options: []))
                }, diagnostics: AccessDiagnostics = AccessDiagnostics()) {
        self.diagnostics = diagnostics
        self.center = center
        provider = mountedVolumes
        let streamPair = AsyncStream<DiskMountEvent>.makeStream()
        stream = streamPair.stream
        continuation = streamPair.continuation
        knownByPath = Dictionary(uniqueKeysWithValues: mountedVolumes().compactMap { volume in
            volume.url.map { ($0.standardizedFileURL.path, volume) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didUnmountNotification,
                                            object: nil, queue: nil) { [weak self] note in
            let path = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.standardizedFileURL.path
            Task { @MainActor [weak self] in self?.receiveUnmount(path: path) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didMountNotification,
                                            object: nil, queue: nil) { [weak self] note in
            let path = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.standardizedFileURL.path
            Task { @MainActor [weak self] in self?.receiveMount(path: path) }
        })
    }
    public func mountedVolumes() async -> [AccessProbeVolume] { provider() }
    public func events() async -> AsyncStream<DiskMountEvent> { stream }
    private func receiveUnmount(path: String?) {
        let uuid = path.flatMap { knownByPath[$0]?.uuid }
        diagnostics.emit("AccessVolume event=unmount outcome=received volume=\(uuid ?? "unknown")",
                         path: path.map { URL(fileURLWithPath: $0) })
        if let path, let removed = knownByPath.removeValue(forKey: path) {
            if removed.uuid != nil { continuation.yield(.unmounted(removed)) }
            return
        }
        // A notification without the URL still has a useful before/after UUID diff.
        let current = provider()
        let mountedUUIDs = Set(current.compactMap(\.uuid))
        for (path, volume) in knownByPath where volume.uuid.map({ !mountedUUIDs.contains($0) }) == true {
            knownByPath.removeValue(forKey: path)
            continuation.yield(.unmounted(volume))
        }
    }
    private func receiveMount(path: String?) {
        let current = provider()
        let received = path.flatMap { path in current.first { $0.url?.standardizedFileURL.path == path } }
        diagnostics.emit("AccessVolume event=mount outcome=received volume=\(received?.uuid ?? "unknown")",
                         path: path.map { URL(fileURLWithPath: $0) })
        let arrivals = current.filter { volume in
            guard let volumePath = volume.url?.standardizedFileURL.path else { return false }
            return (path == nil || path == volumePath) && knownByPath[volumePath]?.uuid != volume.uuid
        }
        for volume in arrivals {
            guard let volumePath = volume.url?.standardizedFileURL.path else { continue }
            knownByPath[volumePath] = volume
            if volume.uuid != nil { continuation.yield(.mounted(volume)) }
        }
    }
    public func stop() {
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
        continuation.finish()
    }
}
