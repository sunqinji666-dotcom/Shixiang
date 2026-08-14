import Testing
@testable import Shixiang

@Suite("Sponsor coin lifecycle")
struct SponsorCoinLifecycleTests {
    @Test("the persistent preference uses a stable installation-scoped key")
    func persistentPreferenceKeyIsStable() {
        #expect(SponsorCoinLifecycle.preferenceKey == "shixiang.sponsorCoin.clickCount.v1")
    }

    @Test("six clicks shrink the coin monotonically until it disappears")
    func sixClicksShrinkUntilHidden() {
        let scales = (0...SponsorCoinLifecycle.maximumClicks).map {
            SponsorCoinLifecycle.scale(after: $0)
        }

        #expect(scales.first == 1)
        #expect(scales.last == 0)
        #expect(zip(scales, scales.dropFirst()).allSatisfy { $0 > $1 })
    }

    @Test("out-of-range click counts clamp safely")
    func clickCountsClampSafely() {
        #expect(SponsorCoinLifecycle.scale(after: -1) == 1)
        #expect(SponsorCoinLifecycle.scale(after: 99) == 0)
    }
}
