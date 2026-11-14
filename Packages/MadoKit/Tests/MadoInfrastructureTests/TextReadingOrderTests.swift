import CoreGraphics
import Testing
@testable import MadoInfrastructure

private func box(_ text: String, x: CGFloat, y: CGFloat, h: CGFloat = 0.012) -> OnDeviceTextRecognitionProvider.RecognizedTextBox {
    .init(text: text, bounds: CGRect(x: x, y: y, width: 0.12, height: h))
}

private func orderedText(_ boxes: [OnDeviceTextRecognitionProvider.RecognizedTextBox]) -> [String] {
    OnDeviceTextRecognitionProvider.readingOrder(boxes).map(\.text)
}

@Test(.timeLimit(.minutes(2)))
func issue687FixDenseAndIndentedRowsAreInReadingOrder() {
    let boxes = [
        box("third", x: 0.01, y: 0.866),
        box("second indented", x: 0.4, y: 0.883),
        box("first", x: 0.02, y: 0.9),
        box("fourth", x: 0.01, y: 0.849)
    ]
    let expected = ["first", "second indented", "third", "fourth"]
    #expect(orderedText(boxes) == expected)
    #expect(orderedText(boxes.reversed()) == expected)
}

@Test(.timeLimit(.minutes(2)))
func issue687FixTallImageNearbyRowsDoNotMerge() {
    let boxes = [
        box("lower", x: 0.01, y: 0.490, h: 0.004),
        box("upper indented", x: 0.5, y: 0.497, h: 0.004),
        box("middle", x: 0.01, y: 0.4935, h: 0.004)
    ]
    #expect(orderedText(boxes) == ["upper indented", "middle", "lower"])
}

@Test(.timeLimit(.minutes(2)))
func issue687FixSameRowSortsLeftToRight() {
    let boxes = [
        box("right", x: 0.5, y: 0.501, h: 0.02),
        box("next", x: 0.01, y: 0.45, h: 0.02),
        box("left", x: 0.02, y: 0.5, h: 0.02)
    ]
    #expect(orderedText(boxes) == ["left", "right", "next"])
}

@Test(.timeLimit(.minutes(2)))
func issue687FixOrderingUsesStableTieBreakers() {
    let boxes = [
        box("z", x: 0.2, y: 0.5, h: 0.02),
        box("a", x: 0.2, y: 0.5, h: 0.02),
        box("left", x: 0.1, y: 0.505, h: 0.015),
        box("lower at same x", x: 0.2, y: 0.495, h: 0.02)
    ]
    let expected = ["left", "a", "z", "lower at same x"]
    #expect(orderedText(boxes) == expected)
    #expect(orderedText(boxes.reversed()) == expected)
}

@Test(.timeLimit(.minutes(2)))
func issue687FixEqualTopDifferentXUsesXOrder() {
    let boxes = [box("right", x: 0.5, y: 0.5), box("left", x: 0.1, y: 0.5)]
    #expect(orderedText(boxes) == ["left", "right"])
}

@Test(.timeLimit(.minutes(2)))
func issue687FixSameXOnOneRowUsesVerticalPosition() {
    let boxes = [box("lower", x: 0.1, y: 0.495, h: 0.02), box("upper", x: 0.1, y: 0.5, h: 0.02)]
    #expect(orderedText(boxes) == ["upper", "lower"])
}
