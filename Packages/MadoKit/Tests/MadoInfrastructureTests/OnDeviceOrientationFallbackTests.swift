import ImageIO
import Testing
@testable import MadoInfrastructure

@Test(.timeLimit(.minutes(2)))
func issue687Fix2UnknownOrientationUsesUprightFallback() {
    #expect(OnDeviceTextRecognitionProvider.orientation(rawValue: 6) == .right)
    #expect(OnDeviceTextRecognitionProvider.orientation(rawValue: 0) == .up)
    #expect(OnDeviceTextRecognitionProvider.orientation(rawValue: 9) == .up)
}
