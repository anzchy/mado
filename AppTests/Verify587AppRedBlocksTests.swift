import Testing

/// Throwaway: proves on the new base that a real App assertion failure fails Walking skeleton (#587). Never merge.
@Test func verify587AppAssertionFailureBlocksWalkingSkeleton() {
    #expect(Bool(false), "intentional failure for the #587 post-merge check")
}
