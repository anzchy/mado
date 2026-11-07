import MadoCore

@MainActor public final class GridSearchProjectionScheduler {
    private var task: Task<Void, Never>?
    private var revision = 0
    public init() {}
    public func schedule(_ source: FolderSnapshot, term: String,
                         onResult: @escaping @MainActor (FolderSnapshot) -> Void) {
        cancel()
        let current = revision
        task = Task {
            do {
                if !term.isEmpty { try await Task.sleep(for: .milliseconds(120)) }
                let filtered = await Task.detached(priority: .userInitiated) {
                    source.filteringFilename(term)
                }.value
                try Task.checkCancellation()
                guard revision == current else { return }
                onResult(filtered)
            } catch { return }
        }
    }
    public func cancel() {
        revision &+= 1
        task?.cancel()
        task = nil
    }
    func waitForPending() async { await task?.value }
}
