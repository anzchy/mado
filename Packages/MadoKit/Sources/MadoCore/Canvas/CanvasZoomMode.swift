/// The persistent intent, independent of a particular viewport's fitted scale.
public enum CanvasZoomMode: Equatable, Sendable {
    case fit
    case actualPixels
    case custom(Double)
}
