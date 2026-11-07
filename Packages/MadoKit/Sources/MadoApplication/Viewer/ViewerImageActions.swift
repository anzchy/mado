import MadoCore

extension ViewerSession {
    public func cancelImageOpening() { endFolderScan(); closeImage() }
    public func dismissCancelledImageFailure(_ error: any Error) -> Bool {
        guard (error as? ImageLoadError)?.kind == .cancelled || error is CancellationError else { return false }
        cancelImageOpening()
        return true
    }
}
