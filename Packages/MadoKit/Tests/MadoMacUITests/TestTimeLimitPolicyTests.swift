import Foundation
import Testing

@Test func TestTimeLimitPolicy673InjectedClockFamilyCanUseOneMinute() {
    let source = """
    @Suite(.timeLimit(.minutes(1))) struct PrefetchResumptionTests {
        @Test func controlled() async {
            let time = SteppedPressureTime()
            let pipeline = ImageIOPipeline(pressureClock: { time.now }, pressureSleep: { try await time.sleep($0) })
            _ = await pipeline.prefetchResumes()
        }
    }
    """
    #expect(packageTimeLimitViolations(in: source, fileName: "MadoInfrastructureTests/PrefetchResumptionTests.swift").isEmpty)
    #expect(packageTimeLimitViolations(in: source, fileName: "MadoApplicationTests/PrefetchResumptionTests.swift") == [.minutes(1)])
    #expect(packageTimeLimitViolations(in: source, fileName: "OtherTests.swift") == [.minutes(1)])
    let extra = source + "\n@Test(.timeLimit(.minutes(1))) func unrelated() {}"
    #expect(packageTimeLimitViolations(in: extra, fileName: "PrefetchResumptionTests.swift") == [.minutes(1), .minutes(1)])
    let wrongSuite = source.replacingOccurrences(of: "struct PrefetchResumptionTests", with: "struct OtherTests")
    #expect(packageTimeLimitViolations(in: wrongSuite, fileName: "PrefetchResumptionTests.swift") == [.minutes(1)])
    let seconds = source + "\n@Test(.timeLimit(.seconds(30))) func unrelated() {}"
    #expect(packageTimeLimitViolations(in: seconds, fileName: "PrefetchResumptionTests.swift").contains(.unrecognised))
}

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
        limits += scanTimeLimits(in: source).count
        let relativePath = file.pathComponents.dropFirst(tests.pathComponents.count).joined(separator: "/")
        let violations = packageTimeLimitViolations(in: source, fileName: relativePath)
        #expect(violations.isEmpty,
                "\(relativePath): \(violations) must be recognised literal minutes >= 2 for CI queueing, except #673's named one-minute suite")
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

/// #672 (#650 item 4): an async or AppKit test without a limit can hang the whole lane.
@Test func TestTimeLimitPolicy672AsyncAndAppKitTestsNeedALimit() {
    let async = """
    @Test func plain() {}
    @Test func waits() async {}
    @Test("named", arguments: [1, 2]) func throwsAsync(value: Int) async throws {}
    @Test(.timeLimit(.minutes(2))) func limited() async {}
    @MainActor @Test func mainActor() {}
    @Test @MainActor func mainActorAfter() {}
    """
    #expect(testsMissingTimeLimit(in: async) == ["waits", "throwsAsync", "mainActor", "mainActorAfter"])
    let appKit = """
    import AppKit
    @Test func drawsView() {}
    @Test(.timeLimit(.minutes(3))) func limited() {}
    """
    #expect(testsMissingTimeLimit(in: appKit) == ["drawsView"])
    for module in ["SwiftUI", "MadoMacUI"] {
        #expect(testsMissingTimeLimit(in: "@testable import \(module)\n@Test func ui() {}") == ["ui"], "\(module)")
    }
    let suites = """
    @Suite(.serialized, .timeLimit(.minutes(2))) struct Limited {
        @Test func inherits() async {}
        struct Nested { @Test func nestedInherits() async {} }
    }
    @MainActor struct Unlimited {
        @Test func needsOne() {}
        func helper() async {}
    }
    @Suite struct Plain {
        @Test func syncIsFine() {}
        @Test func asyncNeedsOne() async {}
    }
    extension Plain { @Test func extended() async {} }
    @Test func afterSuites() async {}
    """
    #expect(testsMissingTimeLimit(in: suites) == ["needsOne", "asyncNeedsOne", "extended", "afterSuites"])
    let trivia = """
    // @Test func commented() async {}
    let text = "@Test func quoted() async {}"
    @Test(arguments: [{ () async in 1 }]) func closureArgument() {}
    @Test func defaultClosure(value: () async -> Void = {}) {}
    @Test func body() { Task { await work() } }
    """
    #expect(testsMissingTimeLimit(in: trivia).isEmpty)
}

/// #672: every async or AppKit test in the package and App test sources carries a limit.
@Test func TestTimeLimitPolicy672EveryAsyncOrAppKitTestHasALimit() throws {
    let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let appTests = tests.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("AppTests")
    var scanned = 0
    var missing: [String] = []
    for directory in [tests, appTests] {
        let files = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 20, "scanned \(directory.path)")
        for file in files {
            scanned += 1
            for name in testsMissingTimeLimit(in: try String(contentsOf: file, encoding: .utf8)) {
                missing.append("\(file.lastPathComponent):\(name)")
            }
        }
    }
    #expect(scanned > 300)
    let deferred = Set(missing).intersection(timeLimitDeferredFor144)
    #expect(deferred.count == timeLimitDeferredFor144.count, "stale #144 deferral: \(timeLimitDeferredFor144.subtracting(deferred).sorted())")
    let untimed = Set(missing).intersection(deliberatelyUntimedTests)
    #expect(untimed.count == deliberatelyUntimedTests.count, "stale untimed exemption: \(deliberatelyUntimedTests.subtracting(untimed).sorted())")
    missing.removeAll { deferred.contains($0) || untimed.contains($0) }
    #expect(missing.isEmpty, "\(missing.count) async/AppKit tests lack a time limit: \(missing.prefix(40))")
}

/// These tests prove a condition-wait helper's wall-clock bound or its timeout failure, and that bound applies
/// only to untimed tests (#400). A limit on them turns the never-true wait into a main-actor spin until
/// cancellation: in the package run it starves every other main-actor test, and in the App run (#672 hosted run
/// 43391375017) `issue606WaitFailuresIncludeAppKitState` spun until its own 3-minute limit. They must stay untimed.
private let deliberatelyUntimedTests: Set<String> = [
    "ConditionWaitTests.swift:i400UntimedWaitKeepsItsBounds",
    "ConditionWaitTests.swift:i400UntimedRunLoopKeepsItsBounds",
    "Issue606ConditionWaitStateTests.swift:issue606WaitFailuresIncludeAppKitState",
]

/// #672 left these alone because the #144 branch edits ShortcutCatalogTests.swift and ShortcutListViewTests.swift.
/// Add `.timeLimit(.minutes(2))` to them and delete this list once #144 has landed.
private let timeLimitDeferredFor144: Set<String> = Set([
    "issue219ShortcutCatalogMatchesLiveSourcesAndKeycaps",
    "issue219ShortcutCatalogUsesSimplifiedChinese",
    "issue219ShortcutCatalogFollowsImplementedFlagAndMenuAvailability",
    "issue219ShortcutCatalogKeepsAllRowsWithChineseMenuTitles",
    "issue219ShortcutCatalogKeepsRowsWhenMenuActionsAreRetitled",
    "issue284ShortcutCatalogNamesTheSurvivingHalfOfAPairedRow",
    "issue284ShortcutCatalogUsesTheFirstKeyedItemWhenAnActionRepeats",
    "issue284ShortcutCatalogResolvesMenuItemsToListedSources",
    "zoomKeycapsAllResolve",
].map { "ShortcutCatalogTests.swift:\($0)" } + [
    "issue219ShortcutCardsFollowPinnedFrames",
    "issue219ShortcutTypographyRowsAndKeycapsFollowPinnedDesign",
    "issue219ShortcutLongestLabelsFitChineseAndEnglish",
    "issue219ShortcutRenderedKeycapsPaintCompleteGlyphs",
    "issue219ShortcutRenderedCardHeadersPaintCompleteSubtitles",
    "issue219ShortcutVisibleCopyIsBilingualWithChineseMenuTitles",
    "issue284ShortcutRowWithoutKeycapsGivesTheNameTheFullRow",
    "issue284ShortcutTextWithoutFontOrColorPaintsInTheSystemLabelStyle",
].map { "ShortcutListViewTests.swift:\($0)" })
