/// Window effects only; visibility rules remain in the Session.
@MainActor public protocol ViewerChromeHost: AnyObject {
    func applyChrome(toolsVisible: Bool, trafficLightsVisible: Bool)
    func focusChromeTool(reverse: Bool, entering: Bool) -> Bool
    /// #444: whether this window can show the folder sidebar beside the viewer (entered from a folder grid).
    var viewerSidebarAvailable: Bool { get }
    /// #444: the native effect of a viewer bottom-tool intent the Session has already allowed.
    func performChromeIntent(_ intent: ViewerChromeIntent)
}
public extension ViewerChromeHost {
    var viewerSidebarAvailable: Bool { false }
    func performChromeIntent(_ intent: ViewerChromeIntent) {}
}
public enum ChromePointerRegion: Sendable { case canvas, bottom, top, outside }
/// #444: the viewer's leading-pod actions that are not base commands (page 14: 侧栏 / 返回网格).
public enum ViewerChromeIntent: Sendable, Equatable { case toggleSidebar, returnToGrid }
