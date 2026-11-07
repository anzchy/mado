import Foundation
import Testing

private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

private func plist(_ path: String) throws -> [String: Any] {
    let data = try Data(contentsOf: repository.appendingPathComponent(path))
    return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
}

private func isTrue(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
    return number.boolValue
}

private func isFalse(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
    return !number.boolValue
}

// ADR-015 (2026-10-30 addendum): sandbox, read-only user files, app-scope bookmarks, network.client,
// and Sparkle's installer mach-lookup exception — nothing else.
@Test func issue220EntitlementsAreExactlyTheFiveDecidedKeys() throws {
    let entitlements = try plist("App/Resources/Mado.entitlements")
    let mach = "com.apple.security.temporary-exception.mach-lookup.global-name"
    let flags = [
        "com.apple.security.app-sandbox",
        "com.apple.security.files.user-selected.read-only",
        "com.apple.security.files.bookmarks.app-scope",
        "com.apple.security.network.client",
    ]
    #expect(Set(entitlements.keys) == Set(flags + [mach]))
    for key in flags { #expect(isTrue(entitlements[key]), "\(key) must be Boolean true") }
    let names = try #require(entitlements[mach] as? [String])
    #expect(names.count == 2)
    #expect(Set(names) == ["$(PRODUCT_BUNDLE_IDENTIFIER)-spks", "$(PRODUCT_BUNDLE_IDENTIFIER)-spki"])
}

@Test func issue220InfoPlistConfiguresSparkleWithoutProfilingOrForcedChecks() throws {
    let info = try plist("App/Info.plist")
    #expect(info["SUFeedURL"] == nil, "Mado feed awaits #552; never use Mado’s frozen feed")
    let key = try #require(info["SUPublicEDKey"] as? String)
    #expect(Data(base64Encoded: key)?.count == 32)
    #expect(key == "XaqePs6p9CwP2w+sJAC+eAKcExNITNS9W54AtIZGpSs=")
    #expect(isFalse(info["SUEnableSystemProfiling"]), "SUEnableSystemProfiling must be Boolean false")
    #expect(isTrue(info["SUEnableInstallerLauncherService"]), "SUEnableInstallerLauncherService must be Boolean true")
    // Sparkle asks on the second launch only while SUEnableAutomaticChecks is unset.
    #expect(info["SUEnableAutomaticChecks"] == nil)
    #expect(info["SUEnableDownloaderService"] == nil)
}

@Test func issue220ProjectPinsSparkleExactly() throws {
    let project = try String(contentsOf: repository.appendingPathComponent("project.yml"), encoding: .utf8)
    let lines = project.components(separatedBy: "\n")
    let start = try #require(lines.firstIndex(of: "  Sparkle:"), "Sparkle package block")
    let block = lines[(start + 1)...].prefix { $0.hasPrefix("    ") }
    #expect(block.contains("    url: https://github.com/sparkle-project/Sparkle"))
    #expect(block.contains("    exactVersion: 2.10.0"))
    #expect(!block.contains { $0.contains("path:") || $0.contains("from:") || $0.contains("minorVersion:") || $0.contains("branch:") })
    func target(_ name: String) throws -> String {
        let begin = try #require(project.range(of: "\n  \(name):\n"), "target \(name)")
        let rest = project[begin.upperBound...]
        let end = rest.range(of: #"\n  [A-Za-z]+:\n"#, options: .regularExpression)?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }
    #expect(try target("MadoApp").contains("- package: Sparkle"))
    #expect(try target("MadoAppTests").contains("package: Sparkle"))
    #expect(try !target("MadoAppTests").contains("- Updates/SparkleUpdatePort.swift"))
    let notices = try String(contentsOf: repository.appendingPathComponent("THIRD_PARTY_NOTICES.md"), encoding: .utf8)
    #expect(notices.contains("Sparkle 2.10.0"))
}
