import Foundation

/// Window-local authority to present an asynchronous access operation's result.
@MainActor public final class AccessIntent {
    fileprivate var token = UUID()
    public init() {}
    public var current: AccessOperation { AccessOperation(owner: self, token: token) }
    public func begin() -> AccessOperation { token = UUID(); return current }
    /// Listing or a grant prompt is speculative until a destination is opened.
    public func navigation() -> AccessOperation { current }
    public func invalidate() { token = UUID() }
}

@MainActor public struct AccessOperation {
    fileprivate let owner: AccessIntent
    fileprivate let token: UUID
    public var isCurrent: Bool { owner.token == token && !Task.isCancelled }
    public func check() throws {
        guard isCurrent else { throw CancellationError() }
    }
    /// The listing and Recent store are asynchronous boundaries supplied by the composition root.
    public func firstImage(list: @MainActor () async throws -> [URL],
                           remember: @MainActor () async throws -> Void) async throws -> URL? {
        let images = try await wait(list)
        guard let first = FolderNavigation(images: images).images.first else { return nil }
        try await wait(remember)
        return first
    }
    public func wait<T>(_ body: @MainActor () async throws -> T) async throws -> T {
        try check()
        do {
            let result = try await body()
            try check()
            return result
        } catch {
            try check()
            throw error
        }
    }
}

@MainActor public final class RootScanAdmission {
    private var claimedGeneration: UUID?
    public init() {}
    public func claim(_ generation: UUID) -> Bool {
        guard claimedGeneration != generation else { return false }
        claimedGeneration = generation
        return true
    }
}
