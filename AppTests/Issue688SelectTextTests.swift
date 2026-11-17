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
    @MainActor @Test func issue688DeviceGapDirectionGuard() async throws {
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

    @MainActor @Test func issue688DeviceOuterOvershootGuard() async throws {
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

    @MainActor @Test func issue688DeviceHelloMadoOvershootStaysOnLowerRow() async throws {
        let (selection, _, _) = try await fixtureSelection()
        let hello = try #require(selection.lines.first { $0.text == "Hello Mado" })
        let rect = selection.geometry.viewRect(hello.box)
        #expect(selection.begin(at: CGPoint(x: rect.minX + 1, y: rect.midY)))
        selection.drag(to: CGPoint(x: rect.maxX + 150, y: rect.midY))
        #expect(selection.selectedText == hello.text)
    }

    @MainActor @Test func issue688DeviceReverseDragIntoUpperGapStartsAtSIDE() async throws {
        let (selection, _, side) = try await fixtureSelection()
        let hello = try #require(selection.lines.first { $0.text == "Hello Mado" })
        let helloRect = selection.geometry.viewRect(hello.box)
        let sideIndex = try #require(selection.lines.firstIndex { $0.text == side.text })
        #expect(selection.begin(at: CGPoint(x: helloRect.minX + 1, y: helloRect.midY)))
        selection.drag(to: CGPoint(x: 500, y: 90))
        #expect(selection.extent?.line == sideIndex)
        #expect(selection.extent?.offset == 0)
        #expect(selection.selectedText?.hasPrefix("SIDE\n") == true)
    }

    @MainActor @Test func issue688DeviceAndOrientedImageGapKeepDraggedLine() async throws {
        for asset in ["mixed.png", "mixed-orientation-6.jpg"] {
            let (selection, chinese, side) = try await fixtureSelection(asset: asset)
            let pair = [chinese, side].sorted { selection.geometry.viewRect($0.box).minX < selection.geometry.viewRect($1.box).minX }
            let first = selection.geometry.viewRect(pair[0].box)
            let second = selection.geometry.viewRect(pair[1].box)
            let gap = second.minX - first.maxX
            #expect(gap > 24)
            #expect(selection.begin(at: CGPoint(x: first.minX + 1, y: first.midY)))
            selection.drag(to: CGPoint(x: first.maxX + 12, y: second.midY))
            #expect(selection.selectedText == pair[0].text)
            #expect(selection.begin(at: CGPoint(x: second.maxX - 1, y: second.midY)))
            selection.drag(to: CGPoint(x: second.minX - 12, y: first.midY))
            #expect(selection.selectedText == pair[1].text)
        }
    }

    @MainActor private func fixtureSelection(asset: String = "mixed.png") async throws -> (ImageTextSelection, TextRecognitionLine, TextRecognitionLine) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("TestAssets/TextRecognition/\(asset)"))
        let lines = try await OnDeviceTextRecognitionProvider().recogniseLines(data)
        let chinese = try #require(lines.first { $0.text == "中文测试" })
        let side = try #require(lines.first { $0.text == "SIDE" })
        let selection = ImageTextSelection()
        selection.geometry = ImageTextGeometry(transform: CanvasTransform(backingScale: 1),
                                               imageSize: CGSize(width: 1000, height: 340))
        selection.lines = lines
        return (selection, chinese, side)
    }
}

@Suite(.timeLimit(.minutes(2))) struct Issue688RowSelectionTests {
    @MainActor private func makeSelection(_ entries: [(String, CGRect)]) -> ImageTextSelection {
        let selection = ImageTextSelection()
        selection.geometry = ImageTextGeometry(transform: CanvasTransform(backingScale: 1),
                                               imageSize: CGSize(width: 600, height: 160))
        selection.lines = entries.map { text, rect in
            TextRecognitionLine(text: text,
                                box: CGRect(x: rect.minX / 600, y: 1 - rect.maxY / 160,
                                            width: rect.width / 600, height: rect.height / 160))
        }
        return selection
    }

    @MainActor @Test func issue688ShortLineOvershootStaysOnItsVerticalRow() {
        let selection = makeSelection([("Hi there", CGRect(x: 0, y: 0, width: 80, height: 16)),
                                       ("Hello world long", CGRect(x: 0, y: 20, width: 300, height: 16))])
        #expect(selection.begin(at: CGPoint(x: 1, y: 8)))
        selection.drag(to: CGPoint(x: 95, y: 8))
        #expect(selection.selectedText == "Hi there")
    }

    @MainActor @Test func issue688NextRowMarginsSelectThatRow() {
        let selection = makeSelection([("A", CGRect(x: 0, y: 0, width: 100, height: 20)),
                                       ("B", CGRect(x: 130, y: 30, width: 100, height: 20))])
        #expect(selection.begin(at: CGPoint(x: 1, y: 10)))
        selection.drag(to: CGPoint(x: 105, y: 40))
        #expect(selection.selectedText == "A\n")
        selection.drag(to: CGPoint(x: 245, y: 40))
        #expect(selection.selectedText == "A\nB")
    }

    @MainActor @Test func issue688ThreeLinesOnOneRowClampToLineBeforeGap() {
        let selection = makeSelection([("A", CGRect(x: 0, y: 0, width: 100, height: 20)),
                                       ("B", CGRect(x: 200, y: 0, width: 100, height: 20)),
                                       ("C", CGRect(x: 400, y: 0, width: 100, height: 20))])
        #expect(selection.begin(at: CGPoint(x: 1, y: 10)))
        selection.drag(to: CGPoint(x: 380, y: 10))
        #expect(selection.selectedText == "A\nB")
    }

    @MainActor @Test func issue688PriceLayoutKeepsUpperLineAtBothOvershoots() {
        let selection = makeSelection([("16", CGRect(x: 0, y: 0, width: 120, height: 48)),
                                       ("November", CGRect(x: 140, y: 4, width: 120, height: 16)),
                                       ("Monday", CGRect(x: 150, y: 28, width: 150, height: 16))])
        #expect(selection.begin(at: CGPoint(x: 141, y: 12)))
        for x in [330.0, 280.0] {
            selection.drag(to: CGPoint(x: x, y: 12))
            #expect(selection.extent?.line == 1)
            #expect(selection.selectedText == "November")
        }
    }

    @MainActor @Test func issue688TallLineDoesNotPullLowerOvershootToUpper() {
        let selection = makeSelection([("big", CGRect(x: 0, y: 0, width: 200, height: 120)),
                                       ("a", CGRect(x: 300, y: 0, width: 200, height: 20)),
                                       ("b", CGRect(x: 300, y: 40, width: 200, height: 20))])
        #expect(selection.begin(at: CGPoint(x: 301, y: 55)))
        selection.drag(to: CGPoint(x: 600, y: 55))
        #expect(selection.extent?.line == 2)
        #expect(selection.selectedText == "b")
    }

    @MainActor @Test func issue688TallBridgeDoesNotChainSeparateRows() {
        let selection = makeSelection([("A", CGRect(x: 0, y: 0, width: 100, height: 20)),
                                       ("tall", CGRect(x: 200, y: 0, width: 100, height: 60)),
                                       ("C", CGRect(x: 10, y: 40, width: 100, height: 20))])
        #expect(selection.begin(at: CGPoint(x: 1, y: 10)))
        selection.drag(to: CGPoint(x: 120, y: 10))
        #expect(selection.extent?.line == 0)
        #expect(selection.selectedText == "A")
    }

    @MainActor @Test func issue688RowEndUsesLargestMaxX() {
        let selection = makeSelection([("wide", CGRect(x: 0, y: 0, width: 300, height: 20)),
                                       ("short", CGRect(x: 200, y: 0, width: 50, height: 20))])
        #expect(selection.begin(at: CGPoint(x: 1, y: 10)))
        selection.drag(to: CGPoint(x: 350, y: 10))
        #expect(selection.extent?.line == 0)
        #expect(selection.selectedText == "wide")
    }

    @MainActor @Test func issue688ForwardDragIntoNextRowGapStopsBeforeGap() {
        let selection = makeSelection([("A", CGRect(x: 500, y: 0, width: 100, height: 20)),
                                       ("B", CGRect(x: 0, y: 30, width: 100, height: 20)),
                                       ("C", CGRect(x: 200, y: 30, width: 100, height: 20))])
        #expect(selection.begin(at: CGPoint(x: 501, y: 10)))
        selection.drag(to: CGPoint(x: 110, y: 40))
        #expect(selection.extent?.line == 1)
        #expect(selection.extent?.offset == 1)
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

// #688 688-RS-WI-3: the TextRowResolver wire-up through the real ImageTextSelection, and the
// resolver cache following `lines` and every part of `geometry` on one reused object.
@Suite(.timeLimit(.minutes(2))) struct Issue688RSWireUpTests {
    static let size = CGSize(width: 600, height: 160)
    static let ce1: [(String, CGRect)] = [("16", CGRect(x: 0, y: 0, width: 120, height: 48)),
                                          ("November", CGRect(x: 140, y: 4, width: 120, height: 16)),
                                          ("Monday", CGRect(x: 150, y: 28, width: 150, height: 16))]
    static let ce2: [(String, CGRect)] = [("big", CGRect(x: 0, y: 0, width: 200, height: 120)),
                                          ("a", CGRect(x: 300, y: 0, width: 200, height: 20)),
                                          ("b", CGRect(x: 300, y: 40, width: 200, height: 20))]
    static let ce3: [(String, CGRect)] = [("wide", CGRect(x: 0, y: 0, width: 300, height: 20)),
                                          ("short", CGRect(x: 200, y: 0, width: 50, height: 20)),
                                          ("C", CGRect(x: 400, y: 0, width: 100, height: 20))]

    static func lines(_ entries: [(String, CGRect)]) -> [TextRecognitionLine] {
        entries.map { text, rect in
            TextRecognitionLine(text: text, box: CGRect(x: rect.minX / size.width, y: 1 - rect.maxY / size.height,
                                                        width: rect.width / size.width, height: rect.height / size.height))
        }
    }
    /// The view point of a point given in the unrotated, unzoomed 600×160 frame.
    static func view(_ point: CGPoint, _ geometry: ImageTextGeometry) -> CGPoint {
        geometry.viewPoint(CGPoint(x: point.x / size.width, y: 1 - point.y / size.height))
    }
    @MainActor static func drag(_ selection: ImageTextSelection, _ from: CGPoint, _ to: CGPoint) -> String? {
        guard selection.begin(at: view(from, selection.geometry)) else { return "begin failed" }
        selection.drag(to: view(to, selection.geometry))
        return selection.selectedText
    }
    @MainActor static func fresh(_ lines: [TextRecognitionLine], _ geometry: ImageTextGeometry,
                                 _ from: CGPoint, _ to: CGPoint) -> String? {
        let selection = ImageTextSelection()
        selection.geometry = geometry
        selection.lines = lines
        return drag(selection, from, to)
    }

    @MainActor @Test func issue688RSWireUpCountersExamplesThroughSelection() {
        for (entries, from, to, line, text) in [(Self.ce1, CGPoint(x: 141, y: 12), CGPoint(x: 330, y: 21), 1, "November"),
                                                (Self.ce2, CGPoint(x: 301, y: 50), CGPoint(x: 600, y: 62), 2, "b"),
                                                (Self.ce3, CGPoint(x: 1, y: 10), CGPoint(x: 350, y: 10), 0, "wide")] {
            let selection = ImageTextSelection()
            selection.geometry = ImageTextGeometry(transform: CanvasTransform(backingScale: 1), imageSize: Self.size)
            selection.lines = Self.lines(entries)
            #expect(Self.drag(selection, from, to) == text)
            #expect(selection.extent?.line == line)
        }
    }

    @MainActor @Test func issue688RSWireUpCacheFollowsLinesAndGeometry() {
        let selection = ImageTextSelection()
        selection.geometry = ImageTextGeometry(transform: CanvasTransform(backingScale: 1), imageSize: Self.size)
        selection.lines = Self.lines(Self.ce1)
        let from = CGPoint(x: 141, y: 12), to = CGPoint(x: 330, y: 21)
        #expect(Self.drag(selection, from, to) == "November")
        selection.geometry.transform = CanvasTransform(backingScale: 1, origin: CGPoint(x: 0, y: 100))
        #expect(Self.drag(selection, from, to) == "November")
        #expect(Self.drag(selection, from, to) == Self.fresh(selection.lines, selection.geometry, from, to))
        selection.geometry.quarterTurns = 1
        #expect(Self.drag(selection, from, to) == "November")
        #expect(Self.drag(selection, from, to) == Self.fresh(selection.lines, selection.geometry, from, to))
        selection.geometry.flipHorizontal = true
        #expect(Self.drag(selection, from, to) == "November")
        #expect(Self.drag(selection, from, to) == Self.fresh(selection.lines, selection.geometry, from, to))
        selection.lines = Self.lines(Self.ce3)
        let wideFrom = CGPoint(x: 1, y: 10), wideTo = CGPoint(x: 350, y: 10)
        #expect(Self.drag(selection, wideFrom, wideTo) == "wide")
        #expect(Self.drag(selection, wideFrom, wideTo) == Self.fresh(selection.lines, selection.geometry, wideFrom, wideTo))
    }
}
