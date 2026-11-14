import ImageIO
import Testing
@testable import MadoInfrastructure

@Test(.timeLimit(.minutes(2)))
func issue687Fix2UnknownOrientationUsesUprightFallback() {
    #expect(OnDeviceTextRecognitionProvider.orientation(rawValue: 6) == .right)
    #expect(OnDeviceTextRecognitionProvider.orientation(rawValue: 0) == .up)
    #expect(OnDeviceTextRecognitionProvider.orientation(rawValue: 9) == .up)
}

@Test(.timeLimit(.minutes(2)))
func issue687Fix2ValidOrientationValuesKeepTheirMeaning() {
    let expected: [CGImagePropertyOrientation] = [
        .up, .upMirrored, .down, .downMirrored,
        .leftMirrored, .right, .rightMirrored, .left
    ]
    for (index, orientation) in expected.enumerated() {
        #expect(OnDeviceTextRecognitionProvider.orientation(rawValue: UInt32(index + 1)) == orientation)
    }
}
