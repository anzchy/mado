import Foundation
import Testing
@testable import MadoApplication

// #869 WI-5: the reply becomes rows and columns, or a failure (AC-5). No table, mismatched columns or a truncated
// reply is never a success. Synthetic replies only.

private let png = makePNG869(3, 2)

private func recognise(content: String?, finish: String? = "stop") async -> TableRecognitionResult {
    let transport = RecordingTransport869([.response(HTTPResponse(statusCode: 200,
                                                                  body: chatReply869(content: content, finish: finish)))])
    let result = await makeService869(transport: transport).recognise(png)
    #expect(await transport.callCount == 1)
    return result
}

private let goldenText = """
| 型号 | Vendor | 说明 | Notes |
|---|:---|---:|:-:|
|  MX-1  | Sensonor | 惯性 测量单元 | a \\| b |
| MX-2 | Bosch Sensortec | 第一段<br>第二段 |  |
| MX-3 | 村田 Murata | 加速度计 | 0.5 g |
| MX-4 | ST | 陀螺仪，双轴 | — |
| MX-5 | TDK InvenSense | Six-axis IMU | rev B |
| MX-6 | 博世 | 气压 / 温度 | 中文 English mix |
"""

private let goldenRows: [[String]] = [
    ["型号", "Vendor", "说明", "Notes"],
    ["MX-1", "Sensonor", "惯性 测量单元", "a | b"],
    ["MX-2", "Bosch Sensortec", "第一段\n第二段", ""],
    ["MX-3", "村田 Murata", "加速度计", "0.5 g"],
    ["MX-4", "ST", "陀螺仪，双轴", "—"],
    ["MX-5", "TDK InvenSense", "Six-axis IMU", "rev B"],
    ["MX-6", "博世", "气压 / 温度", "中文 English mix"],
]

@Test(.timeLimit(.minutes(2)))
func issue869WI5GoldenSevenByFourReply() async {
    #expect(await recognise(content: goldenText) == .table(rows: goldenRows))
}

private func withoutOuterPipes(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        var line = String(line).trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("|") { line.removeFirst() }
        if line.hasSuffix("|"), !line.hasSuffix("\\|") { line.removeLast() }
        return line
    }.joined(separator: "\n")
}

@Test(.timeLimit(.minutes(2)))
func issue869WI5WrappingDoesNotChangeTable() async {
    let bare = await recognise(content: goldenText)
    #expect(bare == .table(rows: goldenRows))
    let variants = [
        "```\n\(goldenText)\n```",
        "```markdown\n\(goldenText)\n```",
        "Here is the table:\n\n\(goldenText)\n\nHope this helps.",
        "```markdown\n\(goldenText)\n```\nNote: one cell was unclear.",
        withoutOuterPipes(goldenText),
        goldenText.replacingOccurrences(of: "\n", with: "\r\n"),
    ]
    for variant in variants {
        #expect(await recognise(content: variant) == bare, "\(variant)")
    }
}

@Test(.timeLimit(.minutes(2)), arguments: [
    (#"| a \| b | c |"#, ["a | b", "c"]),
    ("| x<br>y | z |", ["x\ny", "z"]),
    ("| x<BR>y | z |", ["x\ny", "z"]),
    ("| x<br/>y | z |", ["x\ny", "z"]),
    ("| x<br />y | z |", ["x\ny", "z"]),
    ("| x<Br />y | z |", ["x\ny", "z"]),
    ("|   a   |  b |", ["a", "b"]),
    ("| a |  |", ["a", ""]),
    ("a | b", ["a", "b"]),
    ("| a | b", ["a", "b"]),
])
func issue869WI5CellEdgeCases(row: String, expected: [String]) async {
    #expect(await recognise(content: "| h1 | h2 |\n|---|---|\n\(row)") == .table(rows: [["h1", "h2"], expected]), "\(row)")
}

@Test(.timeLimit(.minutes(2)))
func issue869WI5AlignedSeparatorAndSingleColumn() async {
    #expect(await recognise(content: "| h1 | h2 |\n|:--|--:|\n| a | b |") == .table(rows: [["h1", "h2"], ["a", "b"]]))
    #expect(await recognise(content: "| h |\n|---|\n| v |") == .table(rows: [["h"], ["v"]]))
}

@Test(.timeLimit(.minutes(2)))
func issue869WI5HeaderOnlyTableIsOneRow() async {
    #expect(await recognise(content: "| A | B |\n|---|---|") == .table(rows: [["A", "B"]]))
}

@Test(.timeLimit(.minutes(2)))
func issue869WI5SeparatorWidthMismatchIsIncomplete() async {
    #expect(await recognise(content: "| A | B | C |\n|---|---|\n| 1 | 2 | 3 |") == .failed(.incomplete))
}

@Test(.timeLimit(.minutes(2)))
func issue869WI5CRLFRepliesParse() async {
    #expect(await recognise(content: "| A | B |\r\n|---|---|\r\n| 1 | 2 |\r\n") == .table(rows: [["A", "B"], ["1", "2"]]))
}

@Test(.timeLimit(.minutes(2)))
func issue869WI5FirstOfTwoTablesIsReturned() async {
    let content = "| A | B |\n|---|---|\n| 1 | 2 |\n\nAnd another:\n\n| C |\n|---|\n| 3 |"
    #expect(await recognise(content: content) == .table(rows: [["A", "B"], ["1", "2"]]))
}

/// Writes rows as a Markdown table the way a model might, with random padding, outer pipes and wrapping.
private func markdown(_ rows: [[String]], _ rng: inout SplitMix869) -> String {
    let outer = rows[0].count == 1 || rng.next() % 2 == 0
    func line(_ cells: [String]) -> String {
        let padded = cells.map { cell -> String in
            let escaped = cell.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>")
            return String(repeating: " ", count: Int(rng.next() % 4)) + escaped + String(repeating: " ", count: Int(rng.next() % 4))
        }
        let joined = padded.joined(separator: "|")
        return outer ? "|" + joined + "|" : joined
    }
    var lines = [line(rows[0])]
    lines.append(line(rows[0].map { _ in "---" }))
    lines += rows.dropFirst().map { line($0) }
    let table = lines.joined(separator: "\n")
    switch rng.next() % 4 {
    case 0: return table
    case 1: return "```\n\(table)\n```"
    case 2: return "```markdown\n\(table)\n```"
    default: return "Here is the table:\n\n\(table)\n\nDone."
    }
}

@Test(.timeLimit(.minutes(2)))
func issue869WI5SerialisedTablesRoundTrip() async {
    let seed: UInt64 = 0x0869_0005
    var rng = SplitMix869(seed: seed)
    let alphabet = Array("abcXYZ019表格识别中文|")
    for iteration in 0..<200 {
        let rowCount = Int(rng.next() % 7) + 2, columnCount = Int(rng.next() % 6) + 1
        let rows: [[String]] = (0..<rowCount).map { _ in
            (0..<columnCount).map { _ in
                let length = Int(rng.next() % 7)
                guard length > 0 else { return "" }
                var cell = String((0..<length).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] })
                if length > 2, rng.next() % 3 == 0 {
                    let middle = cell.index(cell.startIndex, offsetBy: length / 2)
                    cell.insert(contentsOf: rng.next() % 2 == 0 ? " " : "\n", at: middle)
                }
                return cell
            }
        }
        let text = markdown(rows, &rng)
        #expect(await recognise(content: text) == .table(rows: rows), "seed \(seed) iteration \(iteration):\n\(text)")
    }
}

@Test(.timeLimit(.minutes(2)))
func issue869WI5ClassificationPrecedence() async {
    let contents: [(String, String?)] = [("valid", "| A | B |\n|---|---|\n| 1 | 2 |"), ("empty", ""), ("null", nil),
                                         ("prose", "Sorry, no table here."),
                                         ("ragged", "| A | B | C |\n|---|---|---|\n| 1 | 2 |")]
    // Only "stop" certifies a complete reply (fix round 1, gpt M3): a missing or null reason, or DeepSeek's
    // insufficient_system_resource, is incomplete; content_filter and any reason we do not know are other.
    for finish in ["stop", "length", "content_filter", nil, "insufficient_system_resource", "tool_calls", "STOP"]
        as [String?] {
        for (name, content) in contents {
            let expected: TableRecognitionResult =
                finish == nil || finish == "length" || finish == "insufficient_system_resource" ? .failed(.incomplete)
                : finish != "stop" ? .failed(.other)
                : name == "valid" ? .table(rows: [["A", "B"], ["1", "2"]])
                : name == "ragged" ? .failed(.incomplete)
                : .failed(.noTable)
            #expect(await recognise(content: content, finish: finish) == expected, "\(finish ?? "null") \(name)")
        }
    }
}

@Test(.timeLimit(.minutes(2)), arguments: [
    ("| A | B |\n|---|---|\n| 1 |", TableRecognitionFailure.incomplete),
    ("| A | B |\n|---|---|\n| 1 | 2 | 3 |", .incomplete),
    ("| A | B |\n| 1 | 2 |", .noTable),
    ("|---|---|", .noTable),
    ("```markdown\n```", .noTable),
    ("Use a | to separate columns.", .noTable),
    ("   \n  ", .noTable),
])
func issue869WI5RaggedAndMissingTableReplies(content: String, expected: TableRecognitionFailure) async {
    #expect(await recognise(content: content) == .failed(expected), "\(content)")
}

@Test(.timeLimit(.minutes(2)))
func issue869Fix1TableWithoutFinishReasonIsIncomplete() async {
    let message: [String: Any] = ["role": "assistant", "content": goodTable869]
    let body = try! JSONSerialization.data(withJSONObject: ["choices": [["index": 0, "message": message]]])
    let transport = RecordingTransport869([.response(HTTPResponse(statusCode: 200, body: body))])
    #expect(await makeService869(transport: transport).recognise(png) == .failed(.incomplete))
    #expect(await recognise(content: goodTable869, finish: nil) == .failed(.incomplete))
    #expect(await recognise(content: goodTable869, finish: "insufficient_system_resource") == .failed(.incomplete))
    #expect(await recognise(content: goodTable869, finish: "tool_calls") == .failed(.other))
    #expect(await recognise(content: goodTable869, finish: "stop") == .table(rows: [["A", "B"], ["1", "2"]]))
}
