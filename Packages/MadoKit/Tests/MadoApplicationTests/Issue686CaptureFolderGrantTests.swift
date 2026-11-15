import Foundation
import Testing
import MadoApplication

// #686 P7-10 CAP-02, grilling decision 3.4: ←/→ on a Capture whose Capture Folder is not an Access Root offers the
// folder grant worded for Captures; a decline is remembered for the Mado session only.

private let home686 = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

private final class Record686: @unchecked Sendable {
    var record: CaptureFolderRecord?
    init(_ record: CaptureFolderRecord?) { self.record = record }
}

@MainActor private func gate(_ box: Record686) -> CaptureFolderGrantGate {
    CaptureFolderGrantGate(record: { box.record }, home: home686)
}

@Test(.timeLimit(.minutes(2))) func issue686DisplayPathExpandsBackToTheFolder() {
    #expect(CaptureFolderAccess.url(forDisplay: "~", home: home686).path == "/Users/someone")
    #expect(CaptureFolderAccess.url(forDisplay: "~/Pictures/Shots", home: home686).path == "/Users/someone/Pictures/Shots")
    #expect(CaptureFolderAccess.url(forDisplay: "/Volumes/Work/Shots", home: home686).path == "/Volumes/Work/Shots")
    for folder in ["/Users/someone/Pictures/Shots", "/Users/someone", "/Volumes/Work/Shots"] {
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        #expect(CaptureFolderAccess.url(forDisplay: CaptureFolderAccess.display(url, home: home686), home: home686).path
                == folder)
    }
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue686CaptureFolderGetsCaptureWording() async {
    let box = Record686(CaptureFolderRecord(bookmark: Data([1]), display: "~/Pictures/Shots", fellBack: false))
    let gate = gate(box)
    #expect(await gate.paging(in: URL(fileURLWithPath: "/Users/someone/Pictures/Shots", isDirectory: true))
            == .prompt(.capture))
    #expect(await gate.paging(in: URL(fileURLWithPath: "/Users/someone/Pictures/Shots/")) == .prompt(.capture))
    #expect(await gate.paging(in: URL(fileURLWithPath: "/Users/someone/Pictures/Shots/../Shots")) == .prompt(.capture))
    #expect(await gate.paging(in: URL(fileURLWithPath: "/Users/someone/Pictures")) == .prompt(.generic))
    #expect(await gate.paging(in: URL(fileURLWithPath: "/Users/someone/Pictures/Shots/Old")) == .prompt(.generic))
    #expect(await gate.paging(in: URL(fileURLWithPath: "/Users/someone/Downloads")) == .prompt(.generic))
}

/// Never chosen: Captures go to ~/Downloads (the record's default); a broken bookmark falls back there too.
@MainActor @Test(.timeLimit(.minutes(2))) func issue686DownloadsIsTheCaptureFolderByDefaultAndOnFallback() async {
    let downloads = URL(fileURLWithPath: "/Users/someone/Downloads", isDirectory: true)
    let chosen = URL(fileURLWithPath: "/Users/someone/Pictures/Shots", isDirectory: true)
    let box = Record686(.downloads)
    let gate = gate(box)
    #expect(await gate.paging(in: downloads) == .prompt(.capture))
    box.record = CaptureFolderRecord(bookmark: Data([1]), display: "~/Pictures/Shots", fellBack: true)
    #expect(await gate.paging(in: downloads) == .prompt(.capture))
    #expect(await gate.paging(in: chosen) == .prompt(.generic))
    box.record = nil  // App Group unavailable
    #expect(await gate.paging(in: downloads) == .prompt(.generic))
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue686DeclinedCaptureFolderIsNotAskedAgainThisSession() async {
    let shots = URL(fileURLWithPath: "/Users/someone/Pictures/Shots", isDirectory: true)
    let other = URL(fileURLWithPath: "/Users/someone/Pictures", isDirectory: true)
    let box = Record686(CaptureFolderRecord(bookmark: Data([1]), display: "~/Pictures/Shots", fellBack: false))
    let gate = gate(box)
    gate.declined(other, wording: .generic)
    #expect(await gate.paging(in: other) == .prompt(.generic), "an ordinary folder keeps asking")
    gate.declined(URL(fileURLWithPath: "/Users/someone/Pictures/Shots/"), wording: .capture)
    #expect(await gate.paging(in: shots) == .stay)
    #expect(await gate.paging(in: shots) == .stay)
    // The user later points the Capture Folder elsewhere: the declined folder is still not asked again,
    // and the new Capture Folder is asked once.
    box.record = CaptureFolderRecord(bookmark: Data([2]), display: "~/Desktop", fellBack: false)
    #expect(await gate.paging(in: shots) == .stay)
    #expect(await gate.paging(in: URL(fileURLWithPath: "/Users/someone/Desktop")) == .prompt(.capture))
    // A new session (a new gate) asks again.
    box.record = CaptureFolderRecord(bookmark: Data([1]), display: "~/Pictures/Shots", fellBack: false)
    #expect(await CaptureFolderGrantGate(record: { box.record }, home: home686).paging(in: shots) == .prompt(.capture))
}
