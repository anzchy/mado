import AppKit
import Testing
import MadoApplication
import MadoCore
import MadoInfrastructure

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

@Suite(.serialized, .timeLimit(.minutes(3))) struct Issue688DeviceSelectionGapTests {
    @MainActor @Test func issue688DeviceGapClampsToDepartedLineInBothDirections() async throws {
        let (selection, chinese, side) = try await fixtureSelection()
        let first = selection.geometry.viewRect(chinese.box)
        let second = selection.geometry.viewRect(side.box)
        #expect(first.maxX < second.minX, "mixed.png has a horizontal gap between the two top-row lines")
        let gap = second.minX - first.maxX
        let chineseEnd = CGPoint(x: first.maxX + min(12, gap * 0.6), y: first.midY)
        let sideStart = CGPoint(x: second.minX - min(12, gap * 0.6), y: second.midY)
        #expect(selection.begin(at: CGPoint(x: first.minX + 1, y: first.midY)))
        selection.drag(to: chineseEnd)
        #expect(selection.selectedText == chinese.text, "overshooting Chinese must not select SIDE")
        #expect(selection.begin(at: CGPoint(x: second.maxX - 1, y: second.midY)))
        selection.drag(to: sideStart)
        #expect(selection.selectedText == side.text, "dragging SIDE into the gap must not prepend a newline")
    }

    @MainActor @Test func issue688DeviceOuterOvershootsClampToOwnLine() async throws {
        let (selection, chinese, side) = try await fixtureSelection()
        let first = selection.geometry.viewRect(chinese.box)
        let second = selection.geometry.viewRect(side.box)
        #expect(selection.begin(at: CGPoint(x: first.maxX - 1, y: first.midY)))
        selection.drag(to: CGPoint(x: first.minX - 12, y: first.midY))
        #expect(selection.selectedText == chinese.text)
        #expect(selection.begin(at: CGPoint(x: second.minX + 1, y: second.midY)))
        selection.drag(to: CGPoint(x: second.maxX + 12, y: second.midY))
        #expect(selection.selectedText == side.text)
    }

    @MainActor @Test func issue688DeviceRotatedGapClampsToDepartedLine() async throws {
        let (selection, chinese, side) = try await fixtureSelection()
        selection.geometry.quarterTurns = 1
        let first = selection.geometry.viewRect(chinese.box)
        let second = selection.geometry.viewRect(side.box)
        let start = CGPoint(x: first.midX, y: first.minY + 1)
        let gap = CGPoint(x: first.midX, y: first.maxY + min(12, (second.minY - first.maxY) * 0.25))
        #expect(selection.begin(at: start))
        selection.drag(to: gap)
        #expect(selection.selectedText == chinese.text)
        #expect(first.maxY < second.minY)
    }

    @MainActor private func fixtureSelection() async throws -> (ImageTextSelection, TextRecognitionLine, TextRecognitionLine) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("TestAssets/TextRecognition/mixed.png"))
        let lines = try await OnDeviceTextRecognitionProvider().recogniseLines(data)
        let chinese = try #require(lines.first { $0.text == "中文测试" })
        let side = try #require(lines.first { $0.text == "SIDE" })
        let selection = ImageTextSelection()
        selection.geometry = ImageTextGeometry(transform: CanvasTransform(backingScale: 1),
                                               imageSize: CGSize(width: 1200, height: 800))
        selection.lines = lines
        return (selection, chinese, side)
    }
}

extension Issue688DeviceSelectionGapTests {
    @MainActor @Test func issue688DeviceGapWithNeighborLineBaselineKeepsDeparture() async throws {
        let (selection, chinese, side) = try await fixtureSelection()
        let first = selection.geometry.viewRect(chinese.box)
        let second = selection.geometry.viewRect(side.box)
        let gap = second.minX - first.maxX
        #expect(gap > 0)
        #expect(selection.begin(at: CGPoint(x: first.minX + 1, y: first.midY)))
        selection.drag(to: CGPoint(x: first.maxX + min(12, gap * 0.25), y: second.midY))
        #expect(selection.selectedText == chinese.text)
        #expect(selection.begin(at: CGPoint(x: second.maxX - 1, y: second.midY)))
        selection.drag(to: CGPoint(x: second.minX - min(12, gap * 0.25), y: first.midY))
        #expect(selection.selectedText == side.text)
    }
}
