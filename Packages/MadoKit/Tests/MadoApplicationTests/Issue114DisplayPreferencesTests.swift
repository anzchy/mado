import Foundation
import Testing
import MadoApplication

/// Seeded SplitMix64 (no property-testing library in the package); seed 0x114.
private struct Issue114Rng: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) * 0x1p-53 }
    mutating func uniform(_ low: Double, _ high: Double) -> Double { low + (high - low) * unit() }
}

private let issue114Steps: [Double] = Array(stride(from: 140.0, through: 280.0, by: 10.0))

private func issue114Clamp(_ value: Double) -> Double { min(280, max(140, value)) }

private func issue114GeneratedInputs(count: Int) -> [Double] {
    var rng = Issue114Rng(state: 0x114)
    var specials: [Double] = [.nan, .infinity, -.infinity, 0, -0.0, 1e-9, -1e-9,
                              .greatestFiniteMagnitude, -.greatestFiniteMagnitude]
    for j in 0..<14 { specials.append(145 + 10 * Double(j)) }
    return (0..<count).map { _ in
        let pick = rng.unit()
        if pick < 0.6 { return rng.uniform(-1000, 2000) }
        if pick < 0.9 { return rng.uniform(130, 290) }
        return specials[Int(rng.next() % UInt64(specials.count))]
    }
}

/// The issue344 non-default base with loop on, matching the literal legacy blob below.
private func issue114LegacyBase() -> DisplayPreferences {
    var value = DisplayPreferences(alwaysShowTools: true, filmstripExpanded: true, appearance: .dark,
                                   gridSidebarWidth: 284, gridSidebarVisible: false)
    value.folderSort = .size
    value.folderSortDirection = .descending
    value.loopThroughImages = true
    return value
}

private func issue114LegacyFields() -> [String: Any] { [
    "alwaysShowTools": true, "filmstripExpanded": true, "appearance": "dark", "gridSidebarWidth": 284,
    "gridSidebarVisible": false, "folderSort": "size", "folderSortDirection": "descending", "loopThroughImages": true,
] }

private func issue114Fields(_ value: DisplayPreferences) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@MainActor private final class Issue114Observer: DisplayPreferencesObserver {
    var payloads: [DisplayPreferences] = []
    func preferencesDidChange(_ preferences: DisplayPreferences) { payloads.append(preferences) }
}

@Test func issue114PrefsNormalizerBoundaries() {
    let cases: [(Double, Double)] = [
        (-.infinity, 220), (.nan, 220), (-50, 140), (-0.0, 140), (0, 140), (135, 140), (139.9, 140), (140, 140),
        (144.9, 140), (145, 150), (164.999, 160), (165, 170), (173, 170), (175, 180), (214.9999, 210), (215, 220),
        (275, 280), (280, 280), (280.1, 280), (285, 280), (9999, 280), (.greatestFiniteMagnitude, 280), (.infinity, 220),
    ]
    for (input, expected) in cases {
        #expect(DisplayPreferences.normalizedThumbnailSize(input) == expected, "input \(input)")
    }
}

@Test func issue114PrefsNormalizerFixedPointsAreTheFifteenSteps() {
    #expect(issue114Steps.count == 15)
    for step in issue114Steps { #expect(DisplayPreferences.normalizedThumbnailSize(step) == step) }
    let image = Set(issue114GeneratedInputs(count: 5_000).map(DisplayPreferences.normalizedThumbnailSize))
    #expect(image.isSubset(of: Set(issue114Steps)), "image outside steps: \(image.subtracting(issue114Steps).sorted())")
}

@Test func issue114PrefsNormalizerLawsOverSeededDomain() {
    let inputs = issue114GeneratedInputs(count: 5_000)
    var firstCounterexample: String?
    func fail(_ message: String) { if firstCounterexample == nil { firstCounterexample = message } }
    for input in inputs {
        let result = DisplayPreferences.normalizedThumbnailSize(input)
        if !(140...280).contains(result) { fail("range: n(\(input)) = \(result)") }
        if (result - 140).truncatingRemainder(dividingBy: 10) != 0 { fail("step: n(\(input)) = \(result)") }
        if DisplayPreferences.normalizedThumbnailSize(result) != result { fail("idempotence: n(\(input)) = \(result)") }
        guard input.isFinite else {
            if result != 220 { fail("non-finite: n(\(input)) = \(result)") }
            continue
        }
        let clamped = issue114Clamp(input)
        if abs(result - clamped) > 5 { fail("distance: n(\(input)) = \(result), clamp \(clamped)") }
        if (clamped - 140).truncatingRemainder(dividingBy: 10) == 5, result != clamped + 5 {
            fail("tie up: n(\(input)) = \(result)")
        }
    }
    let finite = inputs.filter(\.isFinite).sorted()
    for (lower, upper) in zip(finite, finite.dropFirst()) {
        let a = DisplayPreferences.normalizedThumbnailSize(lower), b = DisplayPreferences.normalizedThumbnailSize(upper)
        if a > b { fail("monotonic: n(\(lower)) = \(a) > n(\(upper)) = \(b)") }
    }
    #expect(firstCounterexample == nil, "first counterexample: \(firstCounterexample ?? "")")
}

@Test func issue114PrefsDefaults() {
    let value = DisplayPreferences()
    #expect(value.thumbnailSize == 220)
    #expect(value.showFileNames)
    #expect(value.thumbnailFit == .fill)
    #expect(!value.loopThroughImages)
    #expect(value.folderSort == .name && value.folderSortDirection == .ascending)
    #expect(value.gridSidebarWidth == 196 && value.gridSidebarVisible)
    #expect(value.appearance == .system && !value.alwaysShowTools && !value.filmstripExpanded)
}

@Test func issue114PrefsDefaultEncodesPreIssue114KeySet() throws {
    let keys = Set(try issue114Fields(DisplayPreferences()).keys)
    #expect(keys == ["alwaysShowTools", "filmstripExpanded", "appearance", "gridSidebarWidth", "gridSidebarVisible"])
}

@Test func issue114PrefsCodableRoundTripAndOmissionOverGeneratedCombos() throws {
    var count = 0
    for base in [DisplayPreferences(), issue114LegacyBase()] {
        let baseFields = try issue114Fields(base)
        for size in issue114Steps {
            for names in [true, false] {
                for fit in [ThumbnailFit.fill, .fit] {
                    var value = base
                    value.thumbnailSize = size
                    value.showFileNames = names
                    value.thumbnailFit = fit
                    let data = try JSONEncoder().encode(value)
                    #expect(try JSONDecoder().decode(DisplayPreferences.self, from: data) == value, "\(size) \(names) \(fit)")
                    var fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                    if size == 220 { #expect(fields["thumbnailSize"] == nil) } else {
                        #expect(fields["thumbnailSize"] as? Double == size)
                    }
                    if names { #expect(fields["showFileNames"] == nil) } else { #expect(fields["showFileNames"] as? Bool == false) }
                    if fit == .fill { #expect(fields["thumbnailFit"] == nil) } else { #expect(fields["thumbnailFit"] as? String == "fit") }
                    for key in ["thumbnailSize", "showFileNames", "thumbnailFit"] { fields[key] = nil }
                    #expect(NSDictionary(dictionary: fields) == NSDictionary(dictionary: baseFields))
                    count += 1
                }
            }
        }
    }
    #expect(count == 120)
}

@Test func issue114PrefsLegacyBlobDecodesToNewDefaults() throws {
    let literal = #"{"alwaysShowTools":true,"filmstripExpanded":true,"appearance":"dark","gridSidebarWidth":284,"gridSidebarVisible":false,"folderSort":"size","folderSortDirection":"descending","loopThroughImages":true}"#
    let versioned = #"{"schemaVersion":1,"alwaysShowTools":true,"filmstripExpanded":true,"appearance":"dark","gridSidebarWidth":284,"gridSidebarVisible":false,"folderSort":"size","folderSortDirection":"descending","loopThroughImages":true}"#
    for blob in [literal, versioned] {
        let decoded = try JSONDecoder().decode(DisplayPreferences.self, from: Data(blob.utf8))
        #expect(decoded == issue114LegacyBase())
        #expect(decoded.thumbnailSize == 220 && decoded.showFileNames && decoded.thumbnailFit == .fill)
    }
}

@Test func issue114PrefsBadStoredValuesFallBackPerField() throws {
    let null: Any = NSNull()
    let cases: [(String, Any, (inout DisplayPreferences) -> Void)] = [
        ("thumbnailSize", "big", { $0.thumbnailSize = 220 }),
        ("thumbnailSize", "NaN", { $0.thumbnailSize = 220 }),
        ("thumbnailSize", null, { $0.thumbnailSize = 220 }),
        ("thumbnailSize", true, { $0.thumbnailSize = 220 }),
        ("thumbnailSize", 9999, { $0.thumbnailSize = 280 }),
        ("thumbnailSize", -5, { $0.thumbnailSize = 140 }),
        ("thumbnailSize", 173, { $0.thumbnailSize = 170 }),
        ("showFileNames", "yes", { $0.showFileNames = true }),
        ("showFileNames", false, { $0.showFileNames = false }),
        ("thumbnailFit", "zoom", { $0.thumbnailFit = .fill }),
        ("thumbnailFit", "contain", { $0.thumbnailFit = .fill }),
        ("thumbnailFit", 7, { $0.thumbnailFit = .fill }),
        ("thumbnailFit", "fit", { $0.thumbnailFit = .fit }),
    ]
    for (key, stored, apply) in cases {
        var fields = issue114LegacyFields()
        fields[key] = stored
        let data = try JSONSerialization.data(withJSONObject: fields)
        var expected = issue114LegacyBase()
        apply(&expected)
        let decoded = try JSONDecoder().decode(DisplayPreferences.self, from: data)
        #expect(decoded == expected, "\(key) = \(stored)")
        #expect(decoded.alwaysShowTools, "\(key) = \(stored)")
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue114PrefsInMemoryStoreNormalizesAndNotifies() {
    let store = InMemoryDisplayPreferencesStore()
    let observer = Issue114Observer()
    store.observe(observer)
    for (input, expected) in [(173.0, 170.0), (.nan, 220), (9999, 280)] {
        store.value.thumbnailSize = input
        #expect(store.value.thumbnailSize == expected, "input \(input)")
        #expect(observer.payloads.last == store.value, "input \(input)")
    }
    var rng = Issue114Rng(state: 0x114)
    for _ in 0..<200 {
        let input = rng.uniform(-500, 1000)
        store.value.thumbnailSize = input
        #expect(store.value.thumbnailSize == DisplayPreferences.normalizedThumbnailSize(input), "input \(input)")
        #expect(observer.payloads.last == store.value, "input \(input)")
    }
}
