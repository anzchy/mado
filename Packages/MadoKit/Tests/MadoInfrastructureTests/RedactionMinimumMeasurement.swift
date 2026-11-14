import Foundation
import Testing

/// The decision 5.3 measurement, run on request only:
/// `MADO_693_MEASURE=<out.tsv> swift test --package-path Packages/MadoKit --filter issue693MeasureMosaicMinimum`.
/// For every sample it records what Vision reads from the plain line (the control) and, for each cell size from 2
/// to `MADO_693_MAX_CELL` (default 40), the recognised strings and the original characters among them. Results
/// go to docs/validation/P7-693-mosaic-minimum.md. An empty field is written as `-`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MADO_693_MEASURE"] != nil))
func issue693MeasureMosaicMinimum() throws {
    let environment = ProcessInfo.processInfo.environment
    let output = URL(fileURLWithPath: environment["MADO_693_MEASURE"]!)
    let maxCell = Int(environment["MADO_693_MAX_CELL"] ?? "") ?? 40
    var rows = ["sample\tpixels\tcell\tmatched\tcount\trecognised"]
    for sample in RedactionTextSample.all {
        let size = "\(sample.image.width)x\(sample.image.height) line \(Int(sample.lineRect.height))px"
        let control = try RedactionVision.recognise(sample.image)
        let controlMatched = RedactionVision.matched(control, original: sample.text)
        rows.append("\(sample)\t\(size)\t0\t\(controlMatched.count)/\(RedactionVision.characters(sample.text).count)"
                    + "\t\(control.count)\t\(control.joined(separator: " | "))")
        for cell in 2...maxCell {
            let read = try RedactionVision.recognise(try sample.mosaic(cell: cell))
            let matched = RedactionVision.matched(read, original: sample.text)
            rows.append("\(sample)\t\(size)\t\(cell)\t\(field(String(matched.sorted())))\t\(read.count)"
                        + "\t\(field(read.joined(separator: " | ")))")
        }
    }
    try (rows.joined(separator: "\n") + "\n").write(to: output, atomically: true, encoding: .utf8)
}

private func field(_ text: String) -> String { text.isEmpty ? "-" : text }
