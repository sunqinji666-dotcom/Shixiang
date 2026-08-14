import Foundation

/// A deliberately anonymous support report. It contains enough product and library
/// context to diagnose a local installation without exposing source audio or filenames.
struct SupportDiagnosticsReport: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let generatedAt: Date
    let appVersion: String
    let build: String
    let operatingSystem: String
    let architecture: String
    let soundPackCount: Int
    let soundCount: Int
    let savedCollectionCount: Int
    let analyzedSoundCount: Int
    let hasIndexedLibrary: Bool
    let privacyNotice: String

    static func make(
        appVersion: String,
        build: String,
        soundPackCount: Int,
        soundCount: Int,
        savedCollectionCount: Int,
        analyzedSoundCount: Int,
        operatingSystem: String = ProcessInfo.processInfo.operatingSystemVersionString,
        architecture: String = currentArchitecture(),
        generatedAt: Date = Date()
    ) -> Self {
        Self(
            schemaVersion: currentSchemaVersion,
            generatedAt: generatedAt,
            appVersion: appVersion,
            build: build,
            operatingSystem: operatingSystem,
            architecture: architecture,
            soundPackCount: max(0, soundPackCount),
            soundCount: max(0, soundCount),
            savedCollectionCount: max(0, savedCollectionCount),
            analyzedSoundCount: max(0, analyzedSoundCount),
            hasIndexedLibrary: soundPackCount > 0 || soundCount > 0,
            privacyNotice: "不包含原始音频、文件名、目录路径、标签、账号或许可证内容。"
        )
    }

    var jsonData: Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }

    private static func currentArchitecture() -> String {
        #if arch(arm64)
        return "Apple silicon"
        #elseif arch(x86_64)
        return "Intel"
        #else
        return "Unknown"
        #endif
    }
}
