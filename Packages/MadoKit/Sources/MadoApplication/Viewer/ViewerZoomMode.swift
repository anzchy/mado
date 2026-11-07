import MadoCore

/// Session intent uses the same value that the pure viewport rule consumes.
public typealias ViewerZoomMode = CanvasZoomMode

extension ViewerSessionHost {
    /// Compatibility for hosts that only consume effects; native hosts return the final clamped zoom.
    public func performCanvasZoom(_ command: CommandID, from entry: CommandEntry) -> Double? {
        performCanvas(command, from: entry)
        return nil
    }
}
