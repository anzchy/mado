import AppKit
import Foundation
import Darwin
import MadoCore
import MadoApplication
import MadoInfrastructure

private final class AccessMonitorNotification: @unchecked Sendable {
    let center: NotificationCenter
    let token: any NSObjectProtocol
    init(center: NotificationCenter, name: Notification.Name,
         handler: @escaping @Sendable (Notification) -> Void) {
        self.center = center
        token = center.addObserver(forName: name, object: nil, queue: nil, using: handler)
    }
    deinit { center.removeObserver(token) }
}

/// One application-wide bridge from disk events and real root reads to access state.
@MainActor final class AccessMonitor {
    struct ReadContext: Sendable {
        let permit: AccessWorkPermit
        let stamp: AccessWorkStamp
    }
    let state: AccessState
    let files: FileAccess
    let mounts: (any DiskMountPort)?
    private let sourceExists: @Sendable (URL) throws -> Bool
    private struct SourceCheckKey: Hashable {
        let stamp: AccessWorkStamp
        let file: URL
    }
    /// Same-source failures join the same scoped stat; distinct evidence stays independent.
    private var sourceChecks: [SourceCheckKey: Task<Bool, Never>] = [:]
    private var port: (any DiskMountPort)?
    private var diagnosticObservation: UUID?
    private var startup: Task<Void, Never>?
    private var events: Task<Void, Never>?
    private var notifications: [AccessMonitorNotification] = []
    private var mountEventRevision: UInt64 = 0
    private var latestMountEvents: [String: (revision: UInt64, mounted: Bool)] = [:]
    private var recoveryObservers: [UUID: @MainActor (AccessRecoveryAttempt) -> Void] = [:]
    private var reauthorizationRequests: [AccessRootID: UUID] = [:]
    private var volumeNames: [String: String] = [:]
    /// The loss counter that opened each root's announcement episode, and whether it announced recovery.
    private var announcementEpisodes: [AccessRootID: (lossCounter: UInt64, recovered: Bool)] = [:]
    private var waitingWindows: [AccessRootID: Set<ObjectIdentifier>] = [:]
    private var recoveryTasks: [AccessRootID: Task<Void, Never>] = [:]
    private var recoveryRequests: [AccessRootID: UUID] = [:]
    private var readinessObservers: [UUID: @MainActor (AccessRootID) -> Void] = [:]
    /// At most one real root check runs per root and access counter.
    private var rootChecks: [AccessRootID: (counter: UInt64?, task: Task<AccessLossCause?, Never>)] = [:]
    private var recheck: Task<Void, Never>?
    private var trackedRoots: Set<AccessRootID> = []
    private var admittedURLs: [AccessRootID: URL] = [:]
    func beginWaiting(_ rootID: AccessRootID, window: ObjectIdentifier) {
        waitingWindows[rootID, default: []].insert(window)
    }
    func endWaiting(_ rootID: AccessRootID, window: ObjectIdentifier) {
        waitingWindows[rootID]?.remove(window)
        if waitingWindows[rootID]?.isEmpty == true {
            waitingWindows.removeValue(forKey: rootID)
        }
    }
    func volumeName(for rootID: AccessRootID) -> String? {
        state.snapshot(for: rootID)?.volumeUUID.flatMap { volumeNames[$0] }
    }
    /// One loss and one recovery notification per root and loss episode, even with
    /// several windows. Only a newer loss opens a new episode; redisplaying a waiting
    /// window cannot move an episode back from recovered to lost.
    func claimAnnouncement(for rootID: AccessRootID, recovered: Bool) -> Bool {
        guard let snapshot = state.snapshot(for: rootID) else {
            announcementEpisodes.removeValue(forKey: rootID)
            return false
        }
        if recovered {
            guard announcementEpisodes[rootID]?.recovered == false else { return false }
            announcementEpisodes[rootID]?.recovered = true
            return true
        }
        guard case .lost = snapshot.availability,
              announcementEpisodes[rootID].map({ snapshot.counter > $0.lossCounter }) ?? true else { return false }
        announcementEpisodes[rootID] = (snapshot.counter, false)
        return true
    }

    nonisolated init(files: FileAccess, mounts: (any DiskMountPort)? = nil,
                     sourceExists: @escaping @Sendable (URL) throws -> Bool = AccessMonitor.probeSourceExists) {
        self.files = files
        self.mounts = mounts
        self.sourceExists = sourceExists
        self.state = AccessState()
    }
    deinit { events?.cancel() }

    func start() async {
        if let startup { await startup.value; return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let port = mounts ?? SystemDiskMountPort(diagnostics: files.diagnostics)
            self.port = port
            diagnosticObservation = state.observe { [weak self] change in
                guard let self, case .lost(let id, let counter) = change,
                      let snapshot = state.snapshot(for: id),
                      case .lost(let cause) = snapshot.availability else { return }
                files.diagnostics.emit("AccessRootLost root=\(id.rawValue.uuidString) counter=\(counter) cause=\(String(describing: cause)) volume=\(snapshot.volumeUUID ?? "unknown")")
            }
            let stream = await port.events()
            events = Task { @MainActor [weak self] in
                defer { (port as? SystemDiskMountPort)?.stop() }
                for await event in stream {
                    guard !Task.isCancelled else { break }
                    self?.receive(event)
                }
            }
            // Subscribe before enumerating roots. The latest event map also covers
            // an unmount delivered while a root's metadata is being queried.
            for record in await files.records() { await registerEntry(record.id) }
            notifications = [
                AccessMonitorNotification(center: .default, name: NSApplication.didBecomeActiveNotification) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.requestRecheck() }
                },
                AccessMonitorNotification(center: NSWorkspace.shared.notificationCenter, name: NSWorkspace.didWakeNotification) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.requestRecheck() }
                }
            ]
        }
        startup = task
        await task.value
    }

    private func receive(_ event: DiskMountEvent) {
        switch event {
        case .unmounted(let volume):
            files.diagnostics.emit("AccessVolume event=unmount outcome=received volume=\(volume.uuid ?? "unknown")", path: volume.url)
            guard let uuid = volume.uuid else { return }
            for id in Array(recoveryTasks.keys) {
                guard state.snapshot(for: id)?.volumeUUID == uuid else { continue }
                cancelRecovery(id)
            }
            if let name = volume.name { volumeNames[uuid] = name }
            mountEventRevision &+= 1
            latestMountEvents[uuid] = (mountEventRevision, false)
            state.diskUnmounted(volumeUUID: uuid)
        case .mounted(let volume):
            files.diagnostics.emit("AccessVolume event=mount outcome=received volume=\(volume.uuid ?? "unknown")", path: volume.url)
            guard let uuid = volume.uuid else { return }
            if let name = volume.name { volumeNames[uuid] = name }
            mountEventRevision &+= 1
            latestMountEvents[uuid] = (mountEventRevision, true)
            for attempt in state.diskMounted(volumeUUID: uuid) { publishRecovery(attempt) }
        }
    }
    func register(_ id: AccessRootID) async {
        await start()
        await registerEntry(id)
    }
    private func registerEntry(_ id: AccessRootID) async {
        trackedRoots.insert(id)
        guard state.snapshot(for: id) == nil else { return }
        let volume = await files.savedVolume(id)
        if let uuid = volume?.uuid, let name = volume?.name { volumeNames[uuid] = name }
        let root = await files.rootURL(id)
        let mounted: Bool
        if let uuid = volume?.uuid { mounted = await isMounted(uuid) }
        else { mounted = true }
        guard state.snapshot(for: id) == nil else { return }
        state.register(id, volumeUUID: volume?.uuid)
        admittedURLs[id] = root?.standardizedFileURL.resolvingSymlinksInPath()
        if let uuid = volume?.uuid, !mounted {
            state.diskUnmounted(volumeUUID: uuid)
        } else if root == nil, let port {
            // Initialization may have rejected a missing or Trashed bookmark.
            // Classify its saved evidence instead of treating a nil cache as a cause.
            let stamp = state.stamp(for: id)
            let result = await files.verifySavedRootForRecovery(id, mounts: port)
            if let cause = Self.lossCause(for: result.classification.cause) {
                _ = state.reportRootFailure(id, cause: cause, from: stamp)
            }
        }
    }
    func reauthorize(_ id: AccessRootID, explicitSelection: Bool = false, preservingReadableAuthority: Bool = false) async {
        trackedRoots.insert(id)
        cancelRecovery(id)
        let request = UUID()
        reauthorizationRequests[id] = request
        defer {
            if reauthorizationRequests[id] == request { reauthorizationRequests.removeValue(forKey: id) }
        }
        await start()
        guard reauthorizationRequests[id] == request else { return }
        guard let grant = await files.savedGrantSnapshot(id) else {
            guard reauthorizationRequests[id] == request else { return }
            if let current = state.snapshot(for: id) {
                markUnavailable(id, volumeUUID: current.volumeUUID, cause: .unknown)
            }
            return
        }
        guard reauthorizationRequests[id] == request else { return }
        let volume = grant.bookmarkVolume
        let counter = state.snapshot(for: id)?.counter
        let verificationRevision = volume.uuid.flatMap { latestMountEvents[$0]?.revision }
        let failure: AccessLossCause?
        if explicitSelection {
            do { _ = try await files.verifyExplicitSelection(id); failure = nil }
            catch { failure = .unknown }
            guard ownsReauthorization(id, request: request, counter: counter) else { return }
        } else if volume.uuid != nil, let port, let root = grant.rootURL {
            let result = await files.verifySavedRootForRecovery(id, folder: root, mounts: port)
            guard ownsReauthorization(id, request: request, counter: counter) else { return }
            guard result.bookmarkVolume.uuid == volume.uuid else {
                markUnavailable(id, volumeUUID: volume.uuid, cause: .unknown)
                return
            }
            failure = Self.lossCause(for: result.classification.cause)
        } else {
            // The persistent grant is already app-wide. Cancellation of the
            // initiating UI task must not turn a skipped check into success.
            let verification = Task { @MainActor [self] in await rootReadFailure(id) }
            failure = await verification.value
            guard ownsReauthorization(id, request: request, counter: counter) else { return }
        }
        if let uuid = volume.uuid {
            let revision = latestMountEvents[uuid]?.revision
            let mounted = await port?.mountedVolumes() ?? []
            guard ownsReauthorization(id, request: request, counter: counter) else { return }
            let latest = latestMountEvents[uuid]
            let connected = latest?.revision != revision ? latest?.mounted == true
                : mounted.contains { $0.uuid == uuid }
            guard connected else { markUnavailable(id, volumeUUID: uuid, cause: .diskNotConnected); return }
            guard latest?.revision == verificationRevision else {
                markUnavailable(id, volumeUUID: uuid, cause: .unknown); return
            }
        }
        if let failure { markUnavailable(id, volumeUUID: volume.uuid, cause: failure); return }
        do {
            if preservingReadableAuthority, state.snapshot(for: id)?.availability == .readable,
               let root = grant.rootURL, admittedURLs[id] == root.standardizedFileURL.resolvingSymlinksInPath() {
                try grant.admitting { }
                return
            }
            // No suspension separates this generation proof from the state
            // mutation. State observers run after the grant fence is released.
            try state.reauthorize(id, volumeUUID: volume.uuid, admitting: { update in
                try grant.admitting(update)
            })
            admittedURLs[id] = grant.rootURL?.standardizedFileURL.resolvingSymlinksInPath()
        } catch {
            guard ownsReauthorization(id, request: request, counter: counter) else { return }
            markUnavailable(id, volumeUUID: volume.uuid, cause: .unknown)
        }
    }
    private func ownsReauthorization(_ id: AccessRootID, request: UUID, counter: UInt64?) -> Bool {
        reauthorizationRequests[id] == request && state.snapshot(for: id)?.counter == counter
    }
    private func markUnavailable(_ id: AccessRootID, volumeUUID: String?, cause: AccessLossCause) {
        if state.snapshot(for: id)?.volumeUUID != volumeUUID || state.snapshot(for: id) == nil {
            state.register(id, volumeUUID: volumeUUID)
        }
        if state.snapshot(for: id)?.availability == .readable {
            _ = state.reportRootFailure(id, cause: cause, from: state.stamp(for: id))
        } else if cause == .diskNotConnected, let volumeUUID {
            state.diskUnmounted(volumeUUID: volumeUUID)
        } else if let attempt = state.recoveryAttempt(for: id) {
            _ = state.refineRecoveryFailure(attempt, cause: cause)
        }
    }
    private static func lossCause(for cause: AccessProbeCause) -> AccessLossCause? {
        switch cause {
        case .readable: nil
        case .diskNotConnected: .diskNotConnected
        case .accessExpired: .accessExpired
        case .notFound: .notFound
        case .unknown: .unknown
        }
    }
    func readContext(for id: AccessRootID) async throws -> ReadContext {
        await register(id)
        try Task.checkCancellation()
        guard let permit = state.permit(for: id) else { throw FileAccessError.needsReconnection(id) }
        return ReadContext(permit: permit, stamp: state.stamp(for: id))
    }

    /// A descendant's failure is only evidence to check the root, never proof
    /// that the whole root lost access. The captured counter survives every await.
    /// Decode, format and budget failures say nothing about access and start no check,
    /// unless the failed file itself is gone.
    func reportReadFailure(_ id: AccessRootID, from stamp: AccessWorkStamp, error: (any Error)? = nil,
                           file: URL? = nil) async {
        guard stamp.rootID == id, !Task.isCancelled, state.mayDeliver(stamp) else { return }
        if let error {
            switch Self.failureEvidence(error) {
            case .content: return
            case .undecodable:
                guard let file, await sharedSourceIsMissing(file, from: stamp),
                      !Task.isCancelled, state.mayDeliver(stamp) else { return }
            case .access: break
            }
        }
        await start()
        guard !Task.isCancelled, state.mayDeliver(stamp) else { return }
        let cause = await sharedRootCheck(id)
        guard !Task.isCancelled, let cause, state.mayDeliver(stamp) else { return }
        _ = state.reportRootFailure(id, cause: cause, from: stamp)
    }
    private enum FailureEvidence { case content, undecodable, access }
    /// This classification is pure; only undecodable sources need filesystem evidence.
    private static func failureEvidence(_ error: any Error) -> FailureEvidence {
        switch error {
        case is FolderScanLimitError: return .content
        case let failure as ImageLoadError:
            switch failure.kind {
            case .sourceChanged: return .access
            case .resourceLimit, .cancelled: return .content
            case .corruptImage, .unsupportedFormat: return .undecodable
            }
        case let failure as ImageDecodeError:
            switch failure {
            case .budgetExceeded: return .content
            case .invalidRequest: return .access
            case .unreadableImage: return .undecodable
            }
        default: return .access
        }
    }
    /// Only ENOENT proves absence. EPERM, EACCES and other indeterminate failures
    /// cannot turn an ordinary damaged image into evidence that its root failed.
    nonisolated private static func probeSourceExists(_ file: URL) throws -> Bool {
        var info = stat()
        let (result, code) = file.path.withCString { path in
            let result = Darwin.fstatat(AT_FDCWD, path, &info, 0)
            return (result, errno)
        }
        if result == 0 { return true }
        if code == ENOENT { return false }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
    private func sharedSourceIsMissing(_ file: URL, from stamp: AccessWorkStamp) async -> Bool {
        let key = SourceCheckKey(stamp: stamp, file: file)
        if let task = sourceChecks[key] { return await task.value }
        let task = Task { [files, sourceExists] in
            do {
                // The lease validates containment and keeps the root scope live until
                // the detached stat has really returned, including when a caller cancels.
                let exists = try await files.withLease(.root(stamp.rootID, file: file)) { _ in
                    try await Task.detached { try sourceExists(file) }.value
                }
                return !exists
            } catch { return false }
        }
        sourceChecks[key] = task
        let missing = await task.value
        if sourceChecks[key] == task { sourceChecks.removeValue(forKey: key) }
        return missing
    }
    /// Callers re-check their own cancellation and stamp after awaiting the shared result.
    private func sharedRootCheck(_ id: AccessRootID) async -> AccessLossCause? {
        let counter = state.snapshot(for: id)?.counter
        if let check = rootChecks[id], check.counter == counter { return await check.task.value }
        let task = Task { @MainActor [self] in await rootReadFailure(id) }
        rootChecks[id] = (counter, task)
        let cause = await task.value
        if rootChecks[id]?.task == task { rootChecks.removeValue(forKey: id) }
        return cause
    }
    private func rootReadFailure(_ id: AccessRootID) async -> AccessLossCause? {
        guard !Task.isCancelled else { return nil }
        let volume = await files.savedVolume(id)
        if let uuid = volume?.uuid, !(await isMounted(uuid)) {
            return .diskNotConnected
        }
        let root: URL
        do { root = try await files.probeRootURL(id) }
        catch is CancellationError { return nil }
        catch { return await savedRootReadFailure(id) }
        do {
            return try await files.withLease(.root(id, file: root)) { lease in
                do {
                    _ = try FileManager.default.contentsOfDirectory(at: lease.url, includingPropertiesForKeys: nil)
                    return nil
                } catch where AccessReadFailure.isPermissionDenied(error) {
                    // Resolution and scope have already succeeded. Only the root's
                    // actual read refusal establishes this cause; a child cannot.
                    return AccessLossCause.accessExpired
                }
            }
        } catch is CancellationError { return nil }
        catch { return await savedRootReadFailure(id) }
    }
    private func savedRootReadFailure(_ id: AccessRootID) async -> AccessLossCause? {
        guard !Task.isCancelled, let port else { return Task.isCancelled ? nil : .unknown }
        // Probe deliberately throws a public reconnection error. Recover its
        // specific cause from the saved bookmark, even after roots was cleared.
        let result = await files.verifySavedRootForRecovery(id, mounts: port)
        return Task.isCancelled ? nil : Self.lossCause(for: result.classification.cause)
    }
    private func isMounted(_ uuid: String) async -> Bool {
        let revision = latestMountEvents[uuid]?.revision
        let mounted = await port?.mountedVolumes() ?? []
        // Only an event delivered during enumeration may override its snapshot.
        // A remembered mount must not mask a later missed unmount on foreground.
        if let latest = latestMountEvents[uuid], latest.revision != revision { return latest.mounted }
        return mounted.contains { $0.uuid == uuid }
    }
    /// Repeated activation or wake while a recheck runs joins that recheck.
    private func requestRecheck() {
        guard recheck == nil else { return }
        recheck = Task { @MainActor [weak self] in
            await self?.recheckRoots()
            self?.recheck = nil
        }
    }
    private func recheckRoots() async {
        for record in await files.records() {
            guard !Task.isCancelled else { return }
            await registerEntry(record.id)
            if state.snapshot(for: record.id)?.availability == .readable {
                await reportReadFailure(record.id, from: state.stamp(for: record.id))
                guard !Task.isCancelled else { return }
                if state.snapshot(for: record.id)?.availability == .readable {
                    for observer in Array(readinessObservers.values) { observer(record.id) }
                }
            } else {
                if let uuid = state.snapshot(for: record.id)?.volumeUUID {
                    if await isMounted(uuid) { _ = state.diskMounted(volumeUUID: uuid) }
                    else { state.diskUnmounted(volumeUUID: uuid) }
                }
                if let attempt = state.recoveryAttempt(for: record.id) { publishRecovery(attempt) }
            }
        }
    }
    @discardableResult func observeReadiness(_ observer: @escaping @MainActor (AccessRootID) -> Void) -> UUID {
        let id = UUID(); readinessObservers[id] = observer; return id
    }
    func removeReadinessObserver(_ id: UUID) { readinessObservers.removeValue(forKey: id) }
    @discardableResult func observeRecovery(_ observer: @escaping @MainActor (AccessRecoveryAttempt) -> Void) -> UUID {
        let id = UUID(); recoveryObservers[id] = observer; return id
    }
    func removeRecoveryObserver(_ id: UUID) { recoveryObservers.removeValue(forKey: id) }
    private func publishRecovery(_ attempt: AccessRecoveryAttempt) {
        for observer in Array(recoveryObservers.values) { observer(attempt) }
        guard recoveryTasks[attempt.rootID] == nil else { return }
        let request = UUID()
        recoveryRequests[attempt.rootID] = request
        recoveryTasks[attempt.rootID] = Task { @MainActor [weak self] in
            guard let self else { return }
            var diagnosticOutcome = "refused"
            var diagnosticStage = "grantOrSuperseded"
            files.diagnostics.emit("AccessRecovery outcome=attempt root=\(attempt.rootID.rawValue.uuidString) counter=\(attempt.counter) request=\(request.uuidString)")
            defer {
                files.diagnostics.emit("AccessRecovery outcome=\(diagnosticOutcome) stage=\(diagnosticStage) root=\(attempt.rootID.rawValue.uuidString) counter=\(attempt.counter) request=\(request.uuidString)")
                if recoveryRequests[attempt.rootID] == request {
                    recoveryTasks.removeValue(forKey: attempt.rootID)
                    recoveryRequests.removeValue(forKey: attempt.rootID)
                }
            }
            guard let port, let grant = await files.savedGrantSnapshot(attempt.rootID),
                  ownsRecovery(attempt, request: request) else { return }
            let revision = attempt.volumeUUID.flatMap { latestMountEvents[$0]?.revision }
            diagnosticStage = "verificationOrSuperseded"
            let result = await files.verifySavedRootForRecovery(attempt.rootID, mounts: port)
            guard ownsRecovery(attempt, request: request) else { return }
            guard result.classification.cause == .readable, result.rootURL != nil,
                  result.bookmarkVolume.uuid == attempt.volumeUUID,
                  grant.bookmarkVolume.uuid == attempt.volumeUUID else {
                _ = state.refineRecoveryFailure(attempt, cause:
                    Self.lossCause(for: result.classification.cause) ?? .unknown)
                return
            }
            diagnosticStage = "mountedState"
            if let uuid = attempt.volumeUUID {
                let connected = await isMounted(uuid)
                guard ownsRecovery(attempt, request: request) else { return }
                guard connected else {
                    _ = state.refineRecoveryFailure(attempt, cause: .diskNotConnected); return
                }
                guard latestMountEvents[uuid]?.revision == revision else {
                    _ = state.refineRecoveryFailure(attempt, cause: .unknown); return
                }
            }
            diagnosticStage = "admission"
            do {
                let published = try state.completeRecovery(attempt, verified: true, admitting: { update in
                    try grant.admitting(update)
                })
                diagnosticOutcome = published ? "published" : "refused"
            } catch {
                files.diagnostics.emit("AccessRecovery stage=admission error=\(AccessDiagnostics.errorKind(error)) root=\(attempt.rootID.rawValue.uuidString)")
                guard ownsRecovery(attempt, request: request) else { return }
                _ = state.refineRecoveryFailure(attempt, cause: .unknown)
            }
        }
    }
    private func ownsRecovery(_ attempt: AccessRecoveryAttempt, request: UUID) -> Bool {
        !Task.isCancelled && recoveryRequests[attempt.rootID] == request && state.recoveryAttempt(for: attempt.rootID) == attempt
    }
    /// Replacement must retire automatic recovery before its persistent grant changes.
    func beginReplacement(_ id: AccessRootID) {
        cancelRecovery(id)
        reauthorizationRequests.removeValue(forKey: id)
    }
    /// Undo may remove grants created by another window after the snapshot. Notify
    /// those windows before forgetting authority, so pixels and AX clear together.
    func reconcilePersistedRoots() async {
        let captured = Dictionary(uniqueKeysWithValues: trackedRoots.compactMap { id in
            state.snapshot(for: id).map { (id, $0) }
        })
        let persisted = Set(await files.records().map(\.id))
        for (id, snapshot) in captured {
            guard !persisted.contains(id) && state.snapshot(for: id) == snapshot else { continue }
            beginReplacement(id)
            if snapshot.availability == .readable {
                _ = state.reportRootFailure(id, cause: .notFound, from: state.stamp(for: id))
            }
            state.forget(id)
            trackedRoots.remove(id)
            admittedURLs.removeValue(forKey: id)
        }
    }
    /// Restoring storage restores no reader authority from the previous episode.
    func restoreLostRoot(_ id: AccessRootID, volumeUUID: String?, cause: AccessLossCause) {
        beginReplacement(id)
        trackedRoots.insert(id)
        state.forget(id)
        state.register(id, volumeUUID: volumeUUID)
        _ = state.reportRootFailure(id, cause: cause, from: state.stamp(for: id))
    }
    private func cancelRecovery(_ id: AccessRootID) {
        recoveryTasks.removeValue(forKey: id)?.cancel()
        recoveryRequests.removeValue(forKey: id)
    }
}
