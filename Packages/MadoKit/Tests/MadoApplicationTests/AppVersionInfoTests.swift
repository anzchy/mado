import Foundation
import Testing
import MadoApplication

private let versionKey = "CFBundleShortVersionString"
private let buildKey = "CFBundleVersion"

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Test func appVersionInfoReadsVersionAndBuildStrings() {
    let info = AppVersionInfo(infoDictionary: [versionKey: "1.4.2", buildKey: "318"])
    #expect(info.version == "1.4.2")
    #expect(info.build == "318")
}

enum BadInfoValue: CaseIterable, Sendable {
    case absent, int, number, bool, array, empty
    var value: Any? {
        switch self {
        case .absent: nil
        case .int: 2
        case .number: NSNumber(value: 2)
        case .bool: true
        case .array: ["1.0"]
        case .empty: ""
        }
    }
}

@Test(arguments: BadInfoValue.allCases, [true, false])
func appVersionInfoTreatsMissingNonStringOrEmptyAsUnknown(bad: BadInfoValue, inVersion: Bool) {
    var dictionary: [String: Any] = [versionKey: "7", buildKey: "7"]
    dictionary[inVersion ? versionKey : buildKey] = bad.value
    let info = AppVersionInfo(infoDictionary: dictionary)
    if inVersion {
        #expect(info.version == nil, "\(bad) as version")
        #expect(info.build == "7", "\(bad) as version must not blank build")
    } else {
        #expect(info.build == nil, "\(bad) as build")
        #expect(info.version == "7", "\(bad) as build must not blank version")
    }
}

@Test func appVersionInfoProjectsAnyNonEmptyStringsIndependently() {
    var generator = SplitMix64(state: 0x220)
    let pool = ["版本 β", "1.0\u{0301}", "🖼️ 2", " ", "%@", "%d", "0.0.1", "build\n2", "a"]
    func sample() -> String? {
        switch Int.random(in: 0..<4, using: &generator) {
        case 0: return nil
        case 1: return ""
        case 2: return pool.randomElement(using: &generator)!
        default:
            let length = Int.random(in: 1...64, using: &generator)
            return String((0..<length).map { _ in Character(UnicodeScalar(UInt8.random(in: 32...126, using: &generator))) })
        }
    }
    func oracle(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
    for iteration in 0..<200 {
        let version = sample()
        let build = sample()
        var dictionary: [String: Any] = [:]
        if let version { dictionary[versionKey] = version }
        if let build { dictionary[buildKey] = build }
        let info = AppVersionInfo(infoDictionary: dictionary)
        #expect(info.version == oracle(version), "seed 0x220 iteration \(iteration)")
        #expect(info.build == oracle(build), "seed 0x220 iteration \(iteration)")
        dictionary[versionKey] = 5
        #expect(AppVersionInfo(infoDictionary: dictionary).build == oracle(build), "seed 0x220 iteration \(iteration)")
    }
}

@Test func appUpdatePortSourceIsFoundationOnly() throws {
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let folder = package.appendingPathComponent("Sources/MadoApplication/Updates")
    let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "swift" }
    let sources = try files.map { try String(contentsOf: $0, encoding: .utf8) }
    #expect(sources.contains { $0.contains("protocol AppUpdatePort") })
    for (file, source) in zip(files, sources) {
        for line in source.split(separator: "\n") {
            #expect(line.range(of: #"^import (AppKit|Sparkle|SwiftUI)"#, options: .regularExpression) == nil,
                    "\(file.lastPathComponent): \(line)")
        }
    }
    let manifest = try String(contentsOf: package.appendingPathComponent("Package.swift"), encoding: .utf8)
    #expect(!manifest.contains("Sparkle"))
}
