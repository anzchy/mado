import Foundation
import Testing
import MadoCore
import MadoApplication

@Test func commandZoomAnchor() {
    let centre = CGPoint(x: 480, y: 320)
    let pointer = CGPoint(x: 800, y: 120)
    for entry in CommandEntry.allCases {
        #expect(CommandZoomAnchor.resolve(entry: entry, pointer: pointer, pointerOverPanel: true,
                                          centre: centre) == centre)
        #expect(CommandZoomAnchor.resolve(entry: entry, pointer: nil, pointerOverPanel: false,
                                          centre: centre) == centre)
    }
    #expect(CommandZoomAnchor.resolve(entry: .button, pointer: pointer, pointerOverPanel: false,
                                      centre: centre) == centre)
    for entry: CommandEntry in [.menu, .key] {
        #expect(CommandZoomAnchor.resolve(entry: entry, pointer: pointer, pointerOverPanel: false,
                                          centre: centre) == pointer)
    }
}
