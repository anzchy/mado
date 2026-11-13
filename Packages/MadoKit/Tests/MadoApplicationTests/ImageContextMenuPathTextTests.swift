import Foundation
import Testing
import MadoCore

@Test func imageContextMenuPathTextUsesStoredPOSIXPathsOnePerLine() {
    let urls = [URL(fileURLWithPath: "/tmp/first image.png"), URL(fileURLWithPath: "/tmp/第二张.png")]
    #expect(ImageFileActionPaths.plainText(urls) == "/tmp/first image.png\n/tmp/第二张.png")
}
