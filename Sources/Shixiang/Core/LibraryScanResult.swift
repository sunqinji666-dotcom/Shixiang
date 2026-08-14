import Foundation

/// Why a previously indexed source now appears at a different relative path.
/// The record only describes the index change; it never moves or renames the source file.
enum SourceMigrationKind: String, Codable, Hashable, Sendable {
    case rename
    case move
    case renameAndMove

    var title: String {
        switch self {
        case .rename: return "改名"
        case .move: return "移动"
        case .renameAndMove: return "改名并移动"
        }
    }
}

/// A source-file identity that was retained while its relative path changed during a scan.
struct SourceMigrationRecord: Codable, Hashable, Identifiable, Sendable {
    let soundID: UUID
    let packageID: UUID
    let fromRelativePath: String
    let toRelativePath: String
    let detectedAt: Date

    var id: UUID { soundID }

    var kind: SourceMigrationKind {
        let oldName = (fromRelativePath as NSString).lastPathComponent
        let newName = (toRelativePath as NSString).lastPathComponent
        let oldFolder = LibraryScanner.folderPath(forRelativePath: fromRelativePath)
        let newFolder = LibraryScanner.folderPath(forRelativePath: toRelativePath)
        let nameChanged = oldName != newName
        let folderChanged = oldFolder != newFolder

        switch (nameChanged, folderChanged) {
        case (true, true): return .renameAndMove
        case (true, false): return .rename
        case (false, true): return .move
        case (false, false): return .rename
        }
    }
}

/// A compact account of one incremental scan. These values describe index work only; the
/// scanner never changes the source folder. Keeping the counters on the result lets the UI
/// explain why a refresh was fast without retaining another copy of the library.
struct LibraryScanStatistics: Hashable, Sendable {
    let discoveredCount: Int
    let reusedCount: Int
    let analyzedCount: Int
    let addedCount: Int
    let removedCount: Int
    let updatedCount: Int

    var changedCount: Int { addedCount + removedCount + updatedCount }

    var summary: String {
        if changedCount == 0 {
            return "索引已是最新 · 复用 \(reusedCount.formatted(.number)) 条"
        }
        return "新增 \(addedCount.formatted(.number)) · 更新 \(updatedCount.formatted(.number)) · 移除 \(removedCount.formatted(.number))"
    }
}

/// The successful result of one package scan. Keeping this separate from `[SoundItem]` preserves
/// the scanner's original API while making source migrations available to the UI and telemetry.
struct LibraryScanResult: Hashable, Sendable {
    let packageID: UUID
    let items: [SoundItem]
    let migrations: [SourceMigrationRecord]
    let statistics: LibraryScanStatistics
    let completedAt: Date

    var migrationCount: Int { migrations.count }

    var hasMigrations: Bool { !migrations.isEmpty }

    /// A path migration can retain the same sound ID, so counters alone are not enough to
    /// decide whether the durable index must change.
    var requiresIndexUpdate: Bool { statistics.changedCount > 0 || hasMigrations }

    var report: LibraryScanReport {
        LibraryScanReport(
            packageID: packageID,
            migrations: migrations,
            statistics: statistics,
            completedAt: completedAt
        )
    }
}

/// The UI only needs counters and path migrations after a scan completes. Keeping this compact
/// report instead of the full `LibraryScanResult` prevents a second 36k-item array from staying
/// alive solely to render the completion banner.
struct LibraryScanReport: Hashable, Sendable {
    let packageID: UUID
    let migrations: [SourceMigrationRecord]
    let statistics: LibraryScanStatistics
    let completedAt: Date

    var migrationCount: Int { migrations.count }

    var hasMigrations: Bool { !migrations.isEmpty }
}
