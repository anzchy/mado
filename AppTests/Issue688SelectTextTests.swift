import AppKit
import Testing
import MadoApplication
import MadoCore

@Suite(.timeLimit(.minutes(2))) struct Issue688SelectTextGeometryTests {
@MainActor @Test func issue688ReadingOrderAndPartialCharacterRanges() {
    let selection = ImageTextSelection()
    selection.geometry = ImageTextGeometry(transform: CanvasTransform(backingScale: 1),
                                           imageSize: CGSize(width: 100, height: 100))
    selection.lines = [
        TextRecognitionLine(text: "Hello", box: CGRect(x: 0.1, y: 0.7, width: 0.5, height: 0.1)),
        TextRecognitionLine(text: "World", box: CGRect(x: 0.1, y: 0.4, width: 0.5, height: 0.1))
    ]
    #expect(selection.begin(at: CGPoint(x: 20, y: 25)))
    selection.drag(to: CGPoint(x: 40, y: 55))
    #expect(selection.selectedText == "ello\nWor")
    #expect(selection.selectionRects.count == 2)
    selection.clear()
    #expect(selection.selectedText == nil)
    #expect(!selection.begin(at: CGPoint(x: 90, y: 90)))
}

@MainActor @Test func issue688ImageTextBoxesFollowCanvasTransformForRotationsFlipsZoomAndPan() {
    let base = CanvasTransform(backingScale: 1, zoom: 2, origin: CGPoint(x: 10, y: 20))
    let point = CGPoint(x: 0.2, y: 0.3)
    let expected: [CGPoint] = [CGPoint(x: 50, y: 90), CGPoint(x: 40, y: 60),
                               CGPoint(x: 170, y: 50), CGPoint(x: 80, y: 180)]
    for turns in 0...3 {
        let geometry = ImageTextGeometry(transform: base, imageSize: CGSize(width: 100, height: 50),
                                         quarterTurns: turns)
        #expect(geometry.viewPoint(point) == expected[turns])
    }
    let horizontal = ImageTextGeometry(transform: base, imageSize: CGSize(width: 100, height: 50),
                                       flipHorizontal: true)
    let vertical = ImageTextGeometry(transform: base, imageSize: CGSize(width: 100, height: 50),
                                     flipVertical: true)
    #expect(horizontal.viewPoint(point) == CGPoint(x: 170, y: 90))
    #expect(vertical.viewPoint(point) == CGPoint(x: 50, y: 50))
    let rect = CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.2)
    #expect(ImageTextGeometry(transform: base, imageSize: CGSize(width: 100, height: 50)).viewRect(rect)
        == CGRect(x: 30, y: 80, width: 80, height: 20))
}
}
