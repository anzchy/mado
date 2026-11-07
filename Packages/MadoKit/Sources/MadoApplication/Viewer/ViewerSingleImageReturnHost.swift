/// Native effect for Esc from an image opened on its own: the host knows whether a file is shown;
/// the Session decides when Esc reaches it (after menu and Inspector/panel focus).
@MainActor public protocol ViewerSingleImageReturnHost: AnyObject {
    var canReturnToFolder: Bool { get }
    func returnSingleImageToFolder()
}
