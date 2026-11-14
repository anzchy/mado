import CoreGraphics

public extension CaptureRequest {
    func cropDisplayImage(_ image: CGImage) -> CGImage? {
        guard let rect = regionPixelRect else { return nil }
        return image.cropping(to: rect)
    }
}
