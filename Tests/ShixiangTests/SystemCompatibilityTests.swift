import Foundation
import Testing
@testable import Shixiang

struct SystemCompatibilityTests {
    @Test func appRunsFromMacOS14WhileLocalAIRequiresMacOS262() {
        let macOS14 = ShixiangSystemCompatibility(
            operatingSystemVersion: .init(majorVersion: 14, minorVersion: 0, patchVersion: 0)
        )
        #expect(macOS14.supportsApp)
        #expect(!macOS14.supportsLocalAI)

        let macOS26_1 = ShixiangSystemCompatibility(
            operatingSystemVersion: .init(majorVersion: 26, minorVersion: 1, patchVersion: 9)
        )
        #expect(macOS26_1.supportsApp)
        #expect(!macOS26_1.supportsLocalAI)

        let macOS26_2 = ShixiangSystemCompatibility(
            operatingSystemVersion: .init(majorVersion: 26, minorVersion: 2, patchVersion: 0)
        )
        #expect(macOS26_2.supportsApp)
        #expect(macOS26_2.supportsLocalAI)
    }
}
