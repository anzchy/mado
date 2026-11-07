/// Tells a grid when the shared pipeline admits prefetch again after memory pressure (#139).
public protocol PrefetchResuming: Sendable {
    /// Returns once prefetch is permitted, or soon after the calling task is cancelled.
    func prefetchResumes() async
}
