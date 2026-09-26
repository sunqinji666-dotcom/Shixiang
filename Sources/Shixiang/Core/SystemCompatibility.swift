import Foundation

struct ShixiangSystemCompatibility {
    static let minimumAppVersion = OperatingSystemVersion(
        majorVersion: 14,
        minorVersion: 0,
        patchVersion: 0
    )
    static let minimumLocalAIVersion = OperatingSystemVersion(
        majorVersion: 14,
        minorVersion: 0,
        patchVersion: 0
    )

    let operatingSystemVersion: OperatingSystemVersion

    static var current: Self {
        Self(operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersion)
    }

    var supportsApp: Bool {
        Self.isAtLeast(operatingSystemVersion, Self.minimumAppVersion)
    }

    var supportsLocalAI: Bool {
        Self.isAtLeast(operatingSystemVersion, Self.minimumLocalAIVersion)
    }

    static let localAIUnavailableMessage =
        "本地 AI 自然语言搜索需要 Apple Silicon Mac 与 macOS 14.0 或更高版本。"

    private static func isAtLeast(
        _ version: OperatingSystemVersion,
        _ requirement: OperatingSystemVersion
    ) -> Bool {
        if version.majorVersion != requirement.majorVersion {
            return version.majorVersion > requirement.majorVersion
        }
        if version.minorVersion != requirement.minorVersion {
            return version.minorVersion > requirement.minorVersion
        }
        return version.patchVersion >= requirement.patchVersion
    }
}
