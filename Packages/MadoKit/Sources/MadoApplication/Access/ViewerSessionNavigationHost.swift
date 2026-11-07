/// Optional native folder navigation when the Session has no frozen Preview Set.
/// File Grants can request the grant sheet through this same host path.
@MainActor public protocol ViewerSessionNavigationHost: ViewerSessionHost {
    var canNavigate: Bool { get }
    func navigate(_ direction: NavigationDirection)
}
