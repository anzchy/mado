import Foundation
import Testing
@testable import MadoApplication

// #874 fix round 2 WI-3: each rule of the metadata walk on hand-built byte sequences, beside the real-image tests in
// Issue874Fix2MetadataTests. Only the structure is walked, so these need not decode.

/// FF, the marker, the two length bytes (payload + 2), the payload.
private func segment874H(_ marker: UInt8, _ payload: [UInt8]) -> [UInt8] {
    let length = payload.count + 2
    return [0xFF, marker, UInt8(length >> 8), UInt8(length & 0xFF)] + payload
}

private let soi874H: [UInt8] = [0xFF, 0xD8]
private let eoi874H: [UInt8] = [0xFF, 0xD9]
/// An SOS header and entropy data holding a stuffed 0xFF00 and a restart marker, which belong to the scan.
private let scan874H: [UInt8] = segment874H(0xDA, [1, 1, 0, 0, 63, 0]) + [0x12, 0xFF, 0x00, 0x34, 0xFF, 0xD3, 0x56]
private let jfif874H = Array("JFIF".utf8) + [0, 1, 1, 0, 0, 1, 0, 1, 0, 0]

private func stripped874H(_ bytes: [UInt8]) -> [UInt8]? { TableImageMetadata.stripped(Data(bytes)).map { [UInt8]($0) } }

@Test func issue874Fix2TheJPEGWalkKeepsImageAndColourSegmentsAndDropsTheRest() {
    let kept = segment874H(0xE0, jfif874H) + segment874H(0xE2, Array("ICC_PROFILE".utf8) + [0, 1, 1])
        + segment874H(0xEE, Array("Adobe".utf8) + [0, 100]) + segment874H(0xDB, [0, 1, 2]) + segment874H(0xC0, [8, 0, 1])
    let dropped = segment874H(0xE1, Array("Exif".utf8) + [0, 0, 9]) + segment874H(0xE2, Array("MPF".utf8) + [0])
        + segment874H(0xED, Array("Photoshop 3.0".utf8)) + segment874H(0xFE, Array("comment".utf8))
        + segment874H(0xE0, Array("JFXX".utf8) + [0, 0x10]) + segment874H(0xE0, jfif874H.dropLast(2) + [2, 1, 9, 9, 9, 9, 9, 9])
    // A standalone restart marker between segments, and fill bytes before a marker, are kept as markers.
    let file = soi874H + dropped + kept + [0xFF, 0xD0] + [0xFF, 0xFF] + scan874H + eoi874H + Array("trailer".utf8)
    #expect(stripped874H(file) == soi874H + kept + [0xFF, 0xD0] + scan874H + eoi874H)
}

@Test func issue874Fix2TheJPEGWalkGivesUpOnAStructureItDoesNotKnow() {
    let unknown = soi874H + segment874H(0xF0, [1]) + scan874H + eoi874H
    let shortLength = soi874H + [0xFF, 0xDB, 0x00, 0x01] + scan874H + eoi874H
    let overrunLength = soi874H + [0xFF, 0xDB, 0x40, 0x00, 0x01]
    let notAMarker = soi874H + [0x00, 0xDB] + eoi874H
    let onlyFill = soi874H + [0xFF, 0xFF]
    let noLength = soi874H + [0xFF, 0xDB, 0x00]
    let secondStart = soi874H + [0xFF, 0xD8] + eoi874H
    let scanWithoutEnd = soi874H + scan874H
    let noEnd = soi874H + segment874H(0xDB, [0, 1])
    for (name, bytes) in [("unknown marker", unknown), ("length below 2", shortLength), ("length past the end", overrunLength),
                          ("no marker", notAMarker), ("only fill bytes", onlyFill), ("no length", noLength),
                          ("second SOI", secondStart), ("scan without end", scanWithoutEnd), ("no EOI", noEnd)] {
        #expect(stripped874H(bytes) == nil, "\(name)")
    }
}

/// Length, type, data, and four CRC bytes (not checked by the walk).
private func chunk874H(_ type: String, _ data: [UInt8] = []) -> [UInt8] {
    let length = data.count
    return [UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)]
        + Array(type.utf8) + data + [0, 0, 0, 0]
}

private let pngSignature874H: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

@Test func issue874Fix2ThePNGWalkKeepsImageAndColourChunksAndDropsTheRest() {
    let header = chunk874H("IHDR", [0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0])
    let kept = chunk874H("iCCP", [1, 0, 0]) + chunk874H("pHYs", [0, 0, 0, 1, 0, 0, 0, 1, 1]) + chunk874H("IDAT", [1, 2])
    let dropped = chunk874H("tEXt", Array("Comment\0secret".utf8)) + chunk874H("iTXt", [1]) + chunk874H("eXIf", [1])
        + chunk874H("tIME", [7, 234, 11, 27, 0, 0, 0]) + chunk874H("iDOT", [0])
    let file = pngSignature874H + header + dropped + kept + chunk874H("IEND") + Array("trailer".utf8)
    #expect(stripped874H(file) == pngSignature874H + header + kept + chunk874H("IEND"))
}

@Test func issue874Fix2ThePNGWalkGivesUpOnAnUnknownCriticalChunkOrABrokenLength() {
    let header = chunk874H("IHDR", [0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0])
    #expect(stripped874H(pngSignature874H + header + chunk874H("ZZZZ", [1]) + chunk874H("IEND")) == nil)
    #expect(stripped874H(pngSignature874H + header + [0, 0, 1, 0] + Array("IDAT".utf8) + [1, 2, 3, 4]) == nil)
    #expect(stripped874H(Array("GIF89a".utf8) + [1, 0, 1, 0, 0, 0, 0]) == nil, "not a JPEG or PNG")
}
