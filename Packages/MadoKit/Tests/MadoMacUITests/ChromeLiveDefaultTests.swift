import Testing
@testable import MadoMacUI

@Test @MainActor func chromeComponentsDefaultToLive() {
    var icons = 0
    var scales = 0
    let icon = IconCommandButton(symbol: .next, state: [], theme: .light) { icons += 1 }
    let scale = ScaleIndicator(actualPixels: false) { scales += 1 }
    icon.activate()
    scale.activate()
    #expect(icons == 1)
    #expect(scales == 1)
}
