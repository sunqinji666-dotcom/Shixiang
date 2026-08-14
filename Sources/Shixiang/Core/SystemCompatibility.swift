import Foundation

struct ShixiangSystemCompatibility {
    static let minimumAppVersion = OperatingSystemVersion(
        majorVersion: 14,
        minorVersion: 0,
        patchVersion: 0
    )
    static let minimumLocalAIVersion = OperatingSystemVersion(
        majorVersion: 26,
        minorVersion: 2,
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
        "本地 AI 自然语言搜索需要 macOS 26.2 或更高版本。当前系统仍可使用资料库、普通搜索、试听、整理、声音工作台和拖入剪辑软件。"

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
