import CoreServices
import Foundation
import MadoCore

/// FSEvents adapter: file-level events since now, delivered on the stream's own serial queue until `stop()` returns.
public struct FSEventSource: FolderEventSource {
    public static let latency: Double = 0.05
    typealias Create = @Sendable (FSEventStreamCallback, UnsafeMutablePointer<FSEventStreamContext>, URL) -> FSEventStreamRef?
    private let create: Create, startStream: @Sendable (FSEventStreamRef) -> Bool
    public init() { self.init(create: Self.makeStream) }
    /// Test seams for an OS that cannot create or refuses to start a stream.
    init(create: @escaping Create = Self.makeStream, start: @escaping @Sendable (FSEventStreamRef) -> Bool = FSEventStreamStart) {
        self.create = create; startStream = start
    }
    private static let makeStream: Create = { callback, context, url in
        FSEventStreamCreate(nil, callback, context, [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
    }
    /// RootChanged is not here: FSEvents sends it only with WatchRoot, and the root moving is P2-08.
    static let dropFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
        | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped)
    static func hint(path: String, flags: FSEventStreamEventFlags) -> FolderChangeHint {
        flags & dropFlags != 0 ? .mustRescan : .changed(URL(fileURLWithPath: path))
    }

    /// `ref` and `stopped` are touched only on `queue`; the FSEvents context retains this object until the stream is released.
    private final class Stream: FolderEventStream, @unchecked Sendable {
        let queue = DispatchQueue(label: "mado.fsevents"), key = DispatchSpecificKey<Void>()
        let onHints: @Sendable ([FolderChangeHint]) -> Void
        var ref: FSEventStreamRef?, stopped = false
        init(_ onHints: @escaping @Sendable ([FolderChangeHint]) -> Void) {
            self.onHints = onHints; queue.setSpecific(key: key, value: ())
        }
        /// Off the queue, tears down synchronously behind any in-flight callback; inside a callback, later callbacks are dropped.
        func stop() {
            if DispatchQueue.getSpecific(key: key) != nil { stopped = true; queue.async { self.teardown() } }
            else { queue.sync { stopped = true; teardown() } }
        }
        private func teardown() {
            guard let ref else { return }
            self.ref = nil
            FSEventStreamStop(ref); FSEventStreamInvalidate(ref); FSEventStreamRelease(ref)
        }
    }

    public func start(watching url: URL, onHints: @escaping @Sendable ([FolderChangeHint]) -> Void) throws -> any FolderEventStream {
        let stream = Stream(onHints)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(stream).toOpaque(),
            retain: { info in info.map { _ = Unmanaged<Stream>.fromOpaque($0).retain(); return $0 } },
            release: { info in info.map { Unmanaged<Stream>.fromOpaque($0).release() } }, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let stream = Unmanaged<Stream>.fromOpaque(info).takeUnretainedValue()
            guard !stream.stopped else { return }
            let cPaths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            stream.onHints((0..<count).map { FSEventSource.hint(path: String(cString: cPaths[$0]), flags: flags[$0]) })
        }
        guard let ref = create(callback, &context, url) else { throw FolderWatchError.streamCreateFailed }
        // A refused stream is invalidated and released at once, so nothing is delivered and its context is freed.
        let started = stream.queue.sync {
            FSEventStreamSetDispatchQueue(ref, stream.queue)
            guard startStream(ref) else { FSEventStreamInvalidate(ref); FSEventStreamRelease(ref); return false }
            stream.ref = ref; return true
        }
        // Invalidation may queue the context release; draining the queue frees the handler before the throw.
        guard started else { stream.queue.sync {}; throw FolderWatchError.streamStartRefused }
        return stream
    }
}

/// Production WatchScheduling: monotonic uptime milliseconds; actions run on a global queue.
public struct DispatchWatchScheduler: WatchScheduling {
    private struct Item: WatchCancellable, @unchecked Sendable { let item: DispatchWorkItem; func cancel() { item.cancel() } }
    public init() {}
    public var nowMilliseconds: Int { Int(DispatchTime.now().uptimeNanoseconds / 1_000_000) }
    public func schedule(afterMilliseconds: Int, _ action: @escaping @Sendable () -> Void) -> any WatchCancellable {
        let item = DispatchWorkItem(block: action)
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(afterMilliseconds), execute: item)
        return Item(item: item)
    }
}
