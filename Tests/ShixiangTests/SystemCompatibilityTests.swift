import Foundation
import Testing
@testable import Shixiang

struct SystemCompatibilityTests {
    @Test func appAndBundledLocalAIRunFromMacOS14() {
        let macOS13 = ShixiangSystemCompatibility(
            operatingSystemVersion: .init(majorVersion: 13, minorVersion: 6, patchVersion: 9)
        )
        #expect(!macOS13.supportsApp)
        #expect(!macOS13.supportsLocalAI)

        let macOS14 = ShixiangSystemCompatibility(
            operatingSystemVersion: .init(majorVersion: 14, minorVersion: 0, patchVersion: 0)
        )
        #expect(macOS14.supportsApp)
        #expect(macOS14.supportsLocalAI)

        let macOS15 = ShixiangSystemCompatibility(
            operatingSystemVersion: .init(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        )
        #expect(macOS15.supportsApp)
        #expect(macOS15.supportsLocalAI)
    }
}
