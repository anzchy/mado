import Foundation
import CryptoKit
import Testing
@testable import MadoMacUI

let designRepo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func registry() throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: designRepo.appendingPathComponent("design/picsee-ui-system/native/TOKEN_REGISTRY.json"))) as! [String: Any]
}
func mismatches(root: URL, hashes: [String: String]) throws -> [String] {
    try hashes.keys.sorted().filter { path in
        let data = try Data(contentsOf: root.appendingPathComponent(path))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() != hashes[path]
    }
}
@Test func designRegistryPinsSources() throws {
    let json = try registry()
    let hashes = json["sourcesSha256"] as! [String: String]
    #expect(DesignRegistry.schema == json["schema"] as! String)
    #expect(DesignRegistry.sourcesSHA256 == hashes)
    #expect(try mismatches(root: designRepo, hashes: hashes).isEmpty)
    #expect(try mismatches(root: designRepo, hashes: DesignRegistry.sourcesSHA256).isEmpty)
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    for path in hashes.keys {
        let dest = temp.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: designRepo.appendingPathComponent(path), to: dest)
    }
    for path in hashes.keys.sorted() {
        let file = temp.appendingPathComponent(path)
        let original = try Data(contentsOf: file)
        var changed = original
        changed[0] ^= 1
        try changed.write(to: file)
        #expect(try mismatches(root: temp, hashes: hashes) == [path], "Changed byte must name \(path)")
        try original.write(to: file)
    }
}
@Test func designRoleNamesAreUniqueInRegistrySource() throws {
    let source = try String(contentsOf: designRepo.appendingPathComponent("design/picsee-ui-system/native/TOKEN_REGISTRY.json"), encoding: .utf8)
    let json = try registry()["colors"] as! [String: Any]
    for role in DesignColor.allCases {
        #expect(source.components(separatedBy: "\"\(role.rawValue)\": {").count == 2, "Duplicate or missing role \(role)")
    }
    #expect(json.count == DesignColor.allCases.count)
}
