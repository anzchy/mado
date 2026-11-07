import Foundation
import Testing
import MadoApplication

@Test @MainActor func issue140RootCoveredOpenClaimsExactlyOneScanPerGeneration() {
    let admission = RootScanAdmission()
    let first = UUID(), second = UUID()
    #expect(admission.claim(first))
    #expect(!admission.claim(first))
    #expect(admission.claim(second))
    #expect(!admission.claim(second))
}
