import Testing
import MadoInfrastructure

@Test func sourceBudgetRejectsOverflowAndAllowsStressSizes() throws {
    let budget = 512 * 1024 * 1024
    #expect(try DecodeBudget.sourceCost(width: 8000, height: 6000, budget: budget) == 192_000_000)
    #expect(try DecodeBudget.sourceCost(width: 10000, height: 10000, budget: budget) == 400_000_000)
    #expect(throws: ImageDecodeError.budgetExceeded) { try DecodeBudget.sourceCost(width: Int.max, height: 2, budget: budget) }
    #expect(throws: ImageDecodeError.budgetExceeded) { try DecodeBudget.sourceCost(width: 100, height: 100, budget: 39999) }
    #expect(throws: ImageDecodeError.budgetExceeded) { try DecodeBudget.sourceCost(width: 0, height: 1, budget: budget) }
    #expect(!DecodeBudget.isHeavy(width: 4000, height: 3000))
    #expect(DecodeBudget.isHeavy(width: 4001, height: 3000))
}
