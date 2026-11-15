import Darwin
import Foundation
import MadoApplication

/// What a launch found when it asked for the helper's single-instance lock (#685 fix r3, device N1).
enum CaptureHelperInstanceClaim: Equatable {
    /// This process holds the lock until it exits or releases it.
    case acquired
    /// Another helper holds it: this launch must exit before it shows a bar or registers a hotkey.
    case heldElsewhere
    /// The lock file could not be opened or locked for another reason; there is nothing to coordinate with.
    case unavailable
}

@MainActor protocol CaptureHelperInstanceLockPort: AnyObject {
    func claim() -> CaptureHelperInstanceClaim
}

/// An exclusive, non-blocking `flock` on one file. The descriptor stays open while the lock is held, so the kernel
/// releases it when the process ends, however it ends. flock locks belong to the open file description, so a second
/// claim through another instance conflicts even inside one process.
@MainActor final class FlockCaptureHelperInstanceLock: CaptureHelperInstanceLockPort {
    static let fileName = "capture-helper.lock"
    let url: URL
    private var descriptor: Int32 = -1

    init(url: URL) { self.url = url }

    /// The lock file in the App Group container, shared by every copy of the helper. The helper's own container is
    /// the fallback: it is shared by every copy too, since they have one bundle ID.
    static func appGroup() -> FlockCaptureHelperInstanceLock {
        let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: CaptureBarIdentity.appGroupID)
            ?? FileManager.default.temporaryDirectory
        return FlockCaptureHelperInstanceLock(url: folder.appendingPathComponent(fileName, isDirectory: false))
    }

    func claim() -> CaptureHelperInstanceClaim {
        if descriptor >= 0 { return .acquired }
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return .unavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            close(fd)
            return failure == EWOULDBLOCK ? .heldElsewhere : .unavailable
        }
        descriptor = fd
        return .acquired
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}

/// The helper's launch decision, made before any UI, hotkey or Screen Recording work.
@MainActor enum CaptureHelperStartup {
    static func launch(lock: any CaptureHelperInstanceLockPort, exit: () -> Void, start: () -> Void) {
        if lock.claim() == .heldElsewhere { exit() } else { start() }
    }
}
