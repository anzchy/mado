import CoreGraphics
import Testing
import MadoApplication

// #688 688-RS-WI-4: frozen real Vision output for the two device fixtures, so the row
// builder's 0.5 overlap threshold is checked against real boxes on every package run.
//
// Recorded 2026-11-16 on macOS 26.4 (25E246), VNRecognizeTextRequest revision 3,
// recognitionLevel .accurate, recognitionLanguages ["zh-Hans", "en-US"],
// usesLanguageCorrection true — the settings of OnDeviceTextRecognitionProvider at cf71cc0e,
// in its reading order. Recording command (scratch script mirroring the provider, not in the
// repository; two runs gave identical output):
//   swift record.swift TestAssets/TextRecognition/mixed.png TestAssets/TextRecognition/mixed-orientation-6.jpg
// Boxes are Vision's normalized boundingBox (origin bottom-left). The live path stays covered by
// the App-lane issue688Device* tests, which run the real provider.
enum Issue688VisionFixture {
    struct Line { let text: String; let box: CGRect }

    /// mixed.png, 1000×340, EXIF orientation 1.
    static let mixed: [Line] = [
        Line(text: "中文测试", box: CGRect(x: 0.08159768597447914, y: 0.6247449534596193,
                                        width: 0.2868046264648437, height: 0.22698068057789522)),
        Line(text: "SIDE", box: CGRect(x: 0.7099999995818183, y: 0.6529411756951872,
                                       width: 0.15999999999999992, height: 0.1705882352941176)),
        Line(text: "Hello Mado", box: CGRect(x: 0.08199999845833338, y: 0.32941176438725495,
                                             width: 0.37, height: 0.1705882352941176))
    ]

    /// mixed-orientation-6.jpg, 340×1000, EXIF orientation 6 (Vision is given `.right`).
    static let orientation6: [Line] = [
        Line(text: "Hello Mado", box: CGRect(x: 0.5399999982545455, y: 0.4882351929532007,
                                             width: 0.384, height: 0.18235314313103168)),
        Line(text: "SIDE", box: CGRect(x: 0.1300000004388889, y: 0.17058819070944387,
                                       width: 0.158, height: 0.16470597211052396)),
        Line(text: "中文测试", box: CGRect(x: 0.627917924023455, y: 0.1460957024653975,
                                        width: 0.29416415405273444, height: 0.21957330142750453))
    ]

    /// View rects with the device tests' convention: a 1000×340 image, y flipped, no zoom.
    static func layout(_ lines: [Line]) -> RS.Layout {
        RS.Layout(rects: lines.map { line in
            CGRect(x: line.box.minX * 1000, y: (1 - line.box.maxY) * 340,
                   width: line.box.width * 1000, height: line.box.height * 340)
        }, texts: lines.map(\.text))
    }

    static func ratio(_ a: CGRect, _ b: CGRect) -> CGFloat {
        (min(a.maxY, b.maxY) - max(a.minY, b.minY)) / min(a.height, b.height)
    }
}

@Suite(.timeLimit(.minutes(2))) struct Issue688TextRowResolverVisionFixtureTests {
    @Test func issue688RSRealVisionRowsRecovered() {
        // Expected rows read off the images: 中文测试 and SIDE side by side, Hello Mado alone.
        for (name, lines, expected) in [("mixed.png", Issue688VisionFixture.mixed, [[0, 1], [2]]),
                                        ("mixed-orientation-6.jpg", Issue688VisionFixture.orientation6, [[0], [1, 2]])] {
            let layout = Issue688VisionFixture.layout(lines)
            let r = layout.rects
            let ratios = r.indices.flatMap { i in r.indices.filter { $0 > i }.map { j in
                "\(lines[i].text)–\(lines[j].text) \(Issue688VisionFixture.ratio(r[i], r[j]))"
            } }
            #expect(RS.normalized(layout.resolver.rows) == expected, "\(name) overlap ratios: \(ratios)")
        }
    }

    @Test func issue688RSRealVisionEndpoints() {
        let mixed = Issue688VisionFixture.layout(Issue688VisionFixture.mixed).resolver
        #expect(mixed.lineIndex(at: CGPoint(x: 380, y: 89), anchorLine: 0) == 0)
        #expect(mixed.lineIndex(at: CGPoint(x: 380, y: 60), anchorLine: 0) == 0)
        #expect(mixed.lineIndex(at: CGPoint(x: 698, y: 89), anchorLine: 1) == 1)
        #expect(mixed.lineIndex(at: CGPoint(x: 602, y: 199), anchorLine: 2) == 2)
        #expect(mixed.lineIndex(at: CGPoint(x: 500, y: 90), anchorLine: 2) == 1)
        let rotated = Issue688VisionFixture.layout(Issue688VisionFixture.orientation6).resolver
        #expect(rotated.lineIndex(at: CGPoint(x: 300, y: 253), anchorLine: 1) == 1)
        #expect(rotated.lineIndex(at: CGPoint(x: 615.9, y: 254), anchorLine: 2) == 2)
        #expect(rotated.lineIndex(at: CGPoint(x: 500, y: 250), anchorLine: 0) == 1)
        #expect(rotated.lineIndex(at: CGPoint(x: 936, y: 143), anchorLine: 0) == 0)
    }
}
