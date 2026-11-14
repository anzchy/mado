import Testing
import MadoCore

@Test func issue693MinimumMosaicStrengthIsTheMeasuredSafeValue() {
    // docs/validation/P7-693-mosaic-minimum.md: 8 is the smallest cell size Vision reads nothing from in every
    // sample; the minimum doubles it.
    #expect(RedactionStyle.minimumMosaicStrength == 16)
}

@Test(arguments: [(-4, 16), (0, 16), (1, 16), (15, 16), (16, 16), (17, 17), (40, 40)])
func issue693MosaicStrengthBelowTheMinimumIsClamped(requested: Int, enforced: Int) {
    #expect(RedactionStyle.mosaic(strength: requested).enforced == .mosaic(strength: enforced))
}

@Test func issue693SolidIsEnforcedAsItIs() {
    #expect(RedactionStyle.solid.enforced == .solid)
}
