import Foundation
import Testing

@Test func TestTimeLimitPolicyMinuteSpellingsAndBoundary() {
    let oneMinuteSources = [
        ".timeLimit(.minutes(1))",
        ".timeLimit( .minutes( 1 ) )",
        ".timeLimit(.minutes(\n1))",
    ]
    for source in oneMinuteSources {
        let result = scanTimeLimits(in: source)
        #expect(result == [.minutes(1)], "\(source)")
        #expect(result.filter(\.violatesPolicy).count == 1)
    }
    for minutes in [0, 2, 15] {
        let result = scanTimeLimits(in: ".timeLimit(.minutes(\(minutes)))")
        #expect(result == [.minutes(minutes)])
        #expect(result.filter(\.violatesPolicy).count == (minutes == 0 ? 1 : 0))
    }
    #expect(scanTimeLimits(in: "").isEmpty)
}

@Test func TestTimeLimitPolicyUnknownFormsFailClosed() {
    for source in [
        ".timeLimit(limit)", ".timeLimit(.seconds(30))", ".timeLimit()",
        ".timeLimit(.minutes(count))", ".timeLimit(.minutes(1 + 1))",
        ".timeLimit(.minutes(999999999999999999999999999999))",
        ".timeLimit(.minutes(1)",
    ] {
        let result = scanTimeLimits(in: source)
        #expect(result == [.unrecognised], "\(source)")
        #expect(result.filter(\.violatesPolicy).count == 1)
    }
    let source = ".timeLimit(.minutes(2)) .timeLimit(limit) .timeLimit(.minutes(3))"
    #expect(scanTimeLimits(in: source) == [.minutes(2), .unrecognised, .minutes(3)])
}

@Test func TestTimeLimitPolicyIgnoresCommentsAndStringLiteralsThenResumes() {
    let ignoredSources = [
        "// .timeLimit(.minutes(1)) .timeLimit(limit)\n",
        "/* .timeLimit(.minutes(1)) /* .timeLimit(limit) */ still comment */",
        #"let s = "escaped \" .timeLimit(.minutes(1)) .timeLimit(limit)""#,
        ##"let s = #".timeLimit(.minutes(1)) " .timeLimit(limit)"#"##,
        "let s = \"\"\"\n.timeLimit(.minutes(1)) .timeLimit(limit)\n\"\"\"",
        "let s = #\"\"\"\n.timeLimit(.minutes(1)) .timeLimit(limit)\n\"\"\"#",
        ".timeLimitExtra(.minutes(1))",
    ]
    for ignored in ignoredSources {
        #expect(scanTimeLimits(in: ignored).isEmpty, "\(ignored)")
        #expect(scanTimeLimits(in: ignored + "\n.timeLimit(.minutes(2))") == [.minutes(2)])
        #expect(scanTimeLimits(in: ".timeLimit(.minutes(3))\n" + ignored + "\n.timeLimit(.minutes(2))")
            == [.minutes(3), .minutes(2)])
    }
}

@Test func TestTimeLimitPolicyWhitespacePreservesDeclaration() {
    let whitespace = ["", " ", "\t", "\n"]
    for a in whitespace {
        for b in whitespace {
            for c in whitespace {
                for d in whitespace {
                    for minutes in [1, 2] {
                        let source = ".\(a)timeLimit\(b)(\(c).\(a)minutes\(b)(\(d)\(minutes)\(c))\(d))"
                        let result = scanTimeLimits(in: source)
                        #expect(result == [.minutes(minutes)], "\(source)")
                        #expect(result.filter(\.violatesPolicy).count == (minutes == 1 ? 1 : 0))
                    }
                }
            }
        }
    }
}

/// #277: Swift Testing counts CI main-actor queue time against time limits (#331).
@Test func TestTimeLimitPolicyCIPackageLimitsAllowForMainActorQueueing() throws {
    let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let files = try #require(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil))
        .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    #expect(files.count > 50, "scanned \(tests.path)")
    var limits = 0
    for file in files {
        let source = try String(contentsOf: file, encoding: .utf8)
        for declaration in scanTimeLimits(in: source) {
            limits += 1
            #expect(!declaration.violatesPolicy,
                    "\(file.lastPathComponent): \(declaration) must be recognised literal minutes >= 2 for CI queueing")
        }
    }
    #expect(limits > 100, "found \(limits) time limits")
}

@Test func TestTimeLimitPolicyLexicalFailuresCannotHideLimits() {
    let sources = [
        #"let quote = #/"/#"# + "\n@Test(.timeLimit(.minutes(1))) func example() {}",
        #"let quote = /"/"# + "\n@Test(.timeLimit(.minutes(1))) func example() {}",
        "// comment\r\n@Test(.timeLimit(.minutes(1))) func example() {}",
        ".`timeLimit`(.minutes(1))",
        #"let unfinished = "never closed"#,
        "/* never closed",
        // A nonmember token must also be classified, never silently dropped.
        "let timeLimit = unknown",
    ]
    for source in sources {
        #expect(scanTimeLimits(in: source).contains(where: { $0.violatesPolicy }), "\(source)")
    }
}

/// #494 phase 1: reading the property is not a trait declaration.
@Test func TestTimeLimitPolicy494PropertyReadIsNotADeclaration() {
    let source = "@Test func sample() { _ = Test.current?.timeLimit }"
    #expect(scanTimeLimits(in: source).isEmpty, "a property read declares no time limit")
}

/// Keep invalid declarations visible while a future fix distinguishes reads from calls.
@Test func TestTimeLimitPolicy494InvalidDeclarationControlsRemainRejected() {
    for source in [
        ".timeLimit(limit)", ".timeLimit(.seconds(30))", ".timeLimit()",
        ".timeLimit(.minutes(count))", ".timeLimit(.minutes(1 + 1))",
        ".timeLimit(.minutes(999999999999999999999999999999))",
        ".timeLimit(.minutes(1)",
    ] {
        let declarations = scanTimeLimits(in: source)
        let violations = declarations.filter { $0.violatesPolicy }
        #expect(declarations == [.unrecognised], "\(source)")
        #expect(violations.count == 1, "\(source)")
    }
    for minutes in [0, 1] {
        let declarations = scanTimeLimits(in: ".timeLimit(.minutes(\(minutes)))")
        #expect(declarations == [.minutes(minutes)])
        let violations = declarations.filter { $0.violatesPolicy }
        #expect(violations.count == 1)
    }
}

/// Adding a property read must not hide an invalid declaration or create another one.
@Test func TestTimeLimitPolicy494PropertyReadPreservesInvalidDeclaration() {
    for minutes in [0, 1] {
        let declaration = "@Test(.timeLimit(.minutes(\(minutes)))) func invalid() {}"
        for source in ["_ = Test.current?.timeLimit\n" + declaration,
                       declaration + "\n_ = Test.current?.timeLimit"] {
            let declarations = scanTimeLimits(in: source)
            #expect(declarations == [.minutes(minutes)], "\(source)")
            let violations = declarations.filter { $0.violatesPolicy }
            #expect(violations.count == 1)
        }
    }
}
