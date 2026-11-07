import AppKit

public final class ChromeDragStrip: NSView {
    public override var mouseDownCanMoveWindow: Bool { true }
}

public enum ChromeTitlebarPolicy {
    public static func trafficLightsVisible(isGridVisible: Bool, viewerVisible: Bool) -> Bool {
        isGridVisible || viewerVisible
    }
    public static func apply(to window: NSWindow, visible: Bool, fullScreen: Bool) {
        // Smallest wrapped layout: 206pt widest group + 16pt side margins, three 40pt rows.
        window.contentMinSize = NSSize(width: 238, height: 168)
        window.isMovableByWindowBackground = true
        // Restore native controls in full screen; the system controls their titlebar's reveal.
        let show = visible || fullScreen
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = !show
        }
        window.titleVisibility = show ? .visible : .hidden
    }
}
