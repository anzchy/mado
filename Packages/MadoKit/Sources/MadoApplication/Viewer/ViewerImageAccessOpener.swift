import Foundation

extension ViewerImageLoader {
    /// Sample access authority for each source acquisition, including retry and display renewal.
    public static func accessOpener(intent: AccessIntent,
        open: @escaping @MainActor @Sendable (AccessOperation) async throws -> AccessImageSource) -> Opener {
        return { try await open(intent.current) }
    }
}
