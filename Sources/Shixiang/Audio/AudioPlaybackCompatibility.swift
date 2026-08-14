import Foundation

/// Some legacy libraries contain valid WAVE data with an `.mp3` suffix. Core Audio uses the
/// suffix as an input hint and rejects those files, while Finder can sniff the RIFF header. Keep
/// the source untouched and give Core Audio a short-lived, correctly suffixed symbolic alias.
enum AudioPlaybackCompatibility {
    static func resolvedURL(for sourceURL: URL) -> URL {
        guard sourceURL.pathExtension.lowercased() != "wav",
              isWaveData(at: sourceURL) else {
            return sourceURL
        }

        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("Shixiang/PlaybackAliases", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let aliasURL = directory
            .appendingPathComponent("wave-\(stablePathHash(sourceURL.path)).wav")
        let manager = FileManager.default
        if !manager.fileExists(atPath: aliasURL.path) {
            try? manager.createSymbolicLink(
                atPath: aliasURL.path,
                withDestinationPath: sourceURL.path
            )
        }
        return manager.fileExists(atPath: aliasURL.path) ? aliasURL : sourceURL
    }

    private static func isWaveData(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 12), header.count == 12 else { return false }
        return header.prefix(4) == Data("RIFF".utf8)
            && header.suffix(4) == Data("WAVE".utf8)
    }

    private static func stablePathHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
