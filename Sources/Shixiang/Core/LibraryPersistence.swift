import Foundation
import SQLite3

/// Durable local storage for the library index and Shixiang-owned metadata.
///
/// SQLite is the source of truth. `library.json` from releases before 0.4 is imported once,
/// never deleted, and a fresh JSON recovery snapshot is maintained after structural saves.
struct LibraryPersistence: Sendable {
    let databaseURL: URL
    let legacyJSONURL: URL
    let backupURL: URL

    /// Kept for source compatibility with older health/test code.
    var fileURL: URL { databaseURL }

    init(baseDirectory: URL? = nil) {
        let directory: URL
        if let baseDirectory {
            directory = baseDirectory
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
            directory = applicationSupport.appendingPathComponent("Shixiang", isDirectory: true)
        }
        databaseURL = directory.appendingPathComponent("library.sqlite3", isDirectory: false)
        legacyJSONURL = directory.appendingPathComponent("library.json", isDirectory: false)
        backupURL = directory.appendingPathComponent("library.backup.json", isDirectory: false)
    }

    func load() throws -> [SoundPack] {
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            do {
                return try loadDatabase()
            } catch {
                if let snapshot = try? loadRecoverySnapshot(from: backupURL) {
                    do {
                        try archiveUnreadableDatabase()
                        try save(
                            snapshot.packs,
                            savedCollections: snapshot.savedCollections,
                            intelligenceByID: snapshot.intelligenceByID,
                            ignoredDuplicateFingerprints: snapshot.ignoredDuplicateFingerprints,
                            namingProfile: snapshot.namingProfile
                        )
                        return snapshot.packs
                    } catch {
                        throw LibraryPersistenceError.recoveryFailed(error.localizedDescription)
                    }
                }
                throw error
            }
        }

        if FileManager.default.fileExists(atPath: legacyJSONURL.path) {
            let packs = try loadJSON(from: legacyJSONURL)
            try save(packs)
            return packs
        }

        if FileManager.default.fileExists(atPath: backupURL.path) {
            let snapshot = try loadRecoverySnapshot(from: backupURL)
            try save(
                snapshot.packs,
                savedCollections: snapshot.savedCollections,
                intelligenceByID: snapshot.intelligenceByID,
                ignoredDuplicateFingerprints: snapshot.ignoredDuplicateFingerprints,
                namingProfile: snapshot.namingProfile
            )
            return snapshot.packs
        }
        return []
    }

    /// Replaces the index in one transaction. The live database is never left half-written.
    func save(_ packs: [SoundPack]) throws {
        // Preserve newer Shixiang-owned metadata for older callers that only know about the
        // original pack API. The complete snapshot overload below is what the current store
        // uses, but this compatibility path must never silently erase user collections or
        // intelligence gathered by a newer build.
        let savedCollections = (try? loadSavedCollections()) ?? []
        let intelligenceByID = (try? loadAudioIntelligence()) ?? [:]
        let ignoredDuplicateFingerprints = (try? loadIgnoredDuplicateFingerprints()) ?? []
        let namingProfile = (try? loadNamingProfile()) ?? .default
        try save(
            packs,
            savedCollections: savedCollections,
            intelligenceByID: intelligenceByID,
            ignoredDuplicateFingerprints: ignoredDuplicateFingerprints,
            namingProfile: namingProfile
        )
    }

    /// Replaces the complete local index and Shixiang-owned metadata in one transaction.
    func save(
        _ packs: [SoundPack],
        savedCollections: [SavedCollection],
        intelligenceByID: [UUID: AudioIntelligence],
        ignoredDuplicateFingerprints: Set<String> = [],
        namingProfile: JacksunNamingProfile? = nil
        ) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try createSchema(in: database)
        try execute(database, "BEGIN IMMEDIATE TRANSACTION")

        do {
            try execute(database, "DELETE FROM sounds")
            try execute(database, "DELETE FROM packs")
            try execute(database, "DELETE FROM sounds_fts")
            try execute(database, "DELETE FROM sound_ngrams")
            try execute(database, "DELETE FROM sound_ngrams_state")
            try execute(database, "DELETE FROM sound_semantic_concepts")
            try execute(database, "DELETE FROM sound_variant_families")
            try execute(database, "DELETE FROM semantic_index_state")
            try execute(database, "DELETE FROM saved_collections")
            try execute(database, "DELETE FROM sound_intelligence")
            try execute(database, "DELETE FROM ignored_duplicate_groups")
            try insert(packs: packs, into: database)
            try updateSemanticIndexState(in: database)
            // The structural insert already writes the CJK lookup grams beside each FTS row.
            // Mark that snapshot complete instead of scanning the whole FTS table a second time.
            try updateSearchNGramIndexState(
                soundCount: Int64(packs.reduce(0) { $0 + $1.items.count }),
                in: database
            )
            try insert(savedCollections: savedCollections, into: database)
            try insert(intelligenceByID: intelligenceByID, into: database)
            try insert(
                ignoredDuplicateFingerprints: ignoredDuplicateFingerprints,
                into: database
            )
            if let namingProfile {
                try insert(namingProfile: namingProfile, into: database)
            }
            // Structural saves replace the indexed sound rows. Remove intelligence records
            // whose sound no longer exists so a deleted or renamed source cannot leave stale
            // metadata growing forever in the local database.
            try execute(
                database,
                "DELETE FROM sound_intelligence WHERE sound_id NOT IN (SELECT id FROM sounds)"
            )
            try execute(database, "COMMIT")
        } catch {
            try? execute(database, "ROLLBACK")
            throw error
        }

        let recoveredNamingProfile = namingProfile ?? ((try? loadNamingProfile()) ?? .default)
        try saveRecoveryBackup(
            LibraryRecoverySnapshot(
                packs: packs,
                savedCollections: savedCollections,
                intelligenceByID: intelligenceByID,
                ignoredDuplicateFingerprints: ignoredDuplicateFingerprints,
                namingProfile: recoveredNamingProfile
            )
        )
    }

    func loadNamingProfile() throws -> JacksunNamingProfile {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try createSchema(in: database)
        var statement: OpaquePointer?
        try prepare(
            database,
            sql: "SELECT payload FROM naming_profile WHERE id = 1",
            statement: &statement
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let data = columnData(statement, 0),
              let profile = try? Self.compactDecoder.decode(JacksunNamingProfile.self, from: data) else {
            return .default
        }
        return profile
    }

    func saveNamingProfile(_ profile: JacksunNamingProfile) throws {
        let data = try Self.compactEncoder.encode(profile)
        try update(
            sql: """
                INSERT INTO naming_profile (id, payload) VALUES (1, ?)
                ON CONFLICT(id) DO UPDATE SET payload = excluded.payload
                """,
            bindings: [.blob(data)]
        )
    }

    func saveRecoveryBackup(_ packs: [SoundPack]) throws {
        try saveRecoveryBackup(LibraryRecoverySnapshot(packs: packs))
    }

    func saveRecoveryBackup(_ snapshot: LibraryRecoverySnapshot) throws {
        try FileManager.default.createDirectory(
            at: backupURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let recoveryData = try Self.encoder.encode(snapshot)
        try recoveryData.write(to: backupURL, options: .atomic)
    }

    /// Exports a user-selected copy of the local index. This intentionally contains no source
    /// audio bytes; it is safe to move between machines and can never modify the original files.
    func exportSnapshot(_ snapshot: LibraryRecoverySnapshot, to url: URL) throws {
        let data = try Self.encoder.encode(snapshot)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    /// Loads and validates a user-exported index without touching the live SQLite database.
    /// Validation happens before the caller is allowed to replace the current library.
    func importSnapshot(from url: URL) throws -> LibraryRecoverySnapshot {
        let data = try Data(contentsOf: url)
        let snapshot: LibraryRecoverySnapshot
        do {
            snapshot = try Self.decoder.decode(LibraryRecoverySnapshot.self, from: data)
        } catch {
            throw LibraryPersistenceError.invalidSnapshot("文件不是有效的拾响资料库备份：\(error.localizedDescription)")
        }

        var packIDs = Set<UUID>()
        var soundIDs = Set<UUID>()
        for pack in snapshot.packs {
            guard packIDs.insert(pack.id).inserted else {
                throw LibraryPersistenceError.invalidSnapshot("备份中存在重复的音效包 ID。")
            }
            guard !pack.name.contains(where: Self.containsControlCharacter),
                  !pack.rootPath.isEmpty,
                  pack.rootPath.count <= 16_384,
                  pack.importedAt.timeIntervalSince1970.isFinite,
                  pack.lastScannedAt.timeIntervalSince1970.isFinite else {
                throw LibraryPersistenceError.invalidSnapshot("备份中存在异常的音效包元数据。")
            }
            for item in pack.items {
                guard item.packageID == pack.id else {
                    throw LibraryPersistenceError.invalidSnapshot("声音“\(item.displayName)”没有指向所属音效包。")
                }
                guard soundIDs.insert(item.id).inserted else {
                    throw LibraryPersistenceError.invalidSnapshot("备份中存在重复的声音 ID。")
                }
                guard Self.isSafeRelativePath(item.relativePath),
                      item.fileName == (item.relativePath as NSString).lastPathComponent,
                      item.folderPath == LibraryScanner.folderPath(forRelativePath: item.relativePath),
                      !item.fileExtension.contains(where: Self.containsControlCharacter),
                      item.duration.isFinite,
                      item.duration >= 0,
                      item.duration <= 7 * 24 * 60 * 60,
                      item.sampleRate.map({ $0.isFinite && $0 > 0 && $0 <= 768_000 }) ?? true,
                      item.channelCount.map({ $0 > 0 && $0 <= 256 }) ?? true,
                      item.sourceFileSize.map({ $0 >= 0 }) ?? true,
                      item.sourceModificationDate.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
                      item.customName.map({ !$0.contains(where: Self.containsControlCharacter) && $0.count <= 512 }) ?? true,
                      item.tags.allSatisfy({ !$0.contains(where: Self.containsControlCharacter) && $0.count <= 128 }) else {
                    throw LibraryPersistenceError.invalidSnapshot("声音“\(item.displayName)”包含不安全路径或异常元数据。")
                }
            }
        }
        return snapshot
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.count <= 16_384,
              !value.contains("\\"),
              !value.contains("\0"),
              !value.hasPrefix("/"),
              !value.hasPrefix("~") else {
            return false
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return false
        }
        return true
    }

    private static func containsControlCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    func updateFavorite(soundID: UUID, isFavorite: Bool) throws {
        try update(
            sql: "UPDATE sounds SET favorite = ? WHERE id = ?",
            bindings: [.integer(isFavorite ? 1 : 0), .text(soundID.uuidString)]
        )
    }

    func updateFavorites(
        soundIDs: [UUID],
        isFavorite: Bool,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) throws {
        guard !soundIDs.isEmpty else { return }
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try createSchema(in: database)
        try execute(database, "BEGIN IMMEDIATE TRANSACTION")
        var statement: OpaquePointer?
        do {
            try prepare(
                database,
                sql: "UPDATE sounds SET favorite = ? WHERE id = ?",
                statement: &statement
            )
            defer { sqlite3_finalize(statement) }
            progress?(0, soundIDs.count)
            let progressStep = max(1, soundIDs.count / 100)
            for (index, soundID) in soundIDs.enumerated() {
                try Task.checkCancellation()
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(.integer(isFavorite ? 1 : 0), to: 1, in: statement)
                bind(.text(soundID.uuidString), to: 2, in: statement)
                try stepDone(statement, database: database)
                let completed = index + 1
                if completed == soundIDs.count || completed.isMultiple(of: progressStep) {
                    progress?(completed, soundIDs.count)
                }
            }
            try execute(database, "COMMIT")
        } catch {
            try? execute(database, "ROLLBACK")
            throw error
        }
    }

    /// Replaces one imported package and its derived search rows in a single transaction.
    /// Existing packages stay untouched, so importing a new pack never rewrites a complete
    /// creator-scale library simply to make its files searchable.
    func replacePack(
        _ pack: SoundPack,
        intelligenceByID: [UUID: AudioIntelligence] = [:]
    ) throws {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try createSchema(in: database)
        try execute(database, "BEGIN IMMEDIATE TRANSACTION")

        do {
            let packageID = SQLiteBinding.text(pack.id.uuidString)
            let packageSoundPredicate = "sound_id IN (SELECT id FROM sounds WHERE package_id = ?)"
            try executeUpdate(database, sql: "DELETE FROM sound_intelligence WHERE \(packageSoundPredicate)", bindings: [packageID])
            try executeUpdate(database, sql: "DELETE FROM sound_semantic_concepts WHERE \(packageSoundPredicate)", bindings: [packageID])
            try executeUpdate(database, sql: "DELETE FROM sound_variant_families WHERE \(packageSoundPredicate)", bindings: [packageID])
            try executeUpdate(database, sql: "DELETE FROM sound_ngrams WHERE \(packageSoundPredicate)", bindings: [packageID])
            try executeUpdate(database, sql: "DELETE FROM sounds_fts WHERE \(packageSoundPredicate)", bindings: [packageID])
            try executeUpdate(database, sql: "DELETE FROM sounds WHERE package_id = ?", bindings: [packageID])
            try executeUpdate(database, sql: "DELETE FROM packs WHERE id = ?", bindings: [packageID])

            try insert(packs: [pack], into: database)
            let packSoundIDs = Set(pack.items.map(\.id))
            try insert(
                intelligenceByID: intelligenceByID.filter { packSoundIDs.contains($0.key) },
                into: database
            )
            try updateSemanticIndexState(in: database)
            try updateSearchNGramIndexState(
                soundCount: try scalarInt64(in: database, sql: "SELECT COUNT(*) FROM sounds"),
                in: database
            )
            try execute(database, "COMMIT")
        } catch {
            try? execute(database, "ROLLBACK")
            throw error
        }
    }

    func updateMetadata(soundID: UUID, customName: String?, tags: [String]) throws {
        try updateMetadata([
            LibraryMetadataUpdate(soundID: soundID, customName: customName, tags: tags)
        ])
    }

    func updateMetadata(
        _ updates: [LibraryMetadataUpdate],
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) throws {
        guard !updates.isEmpty else { return }
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try createSchema(in: database)
        try execute(database, "BEGIN IMMEDIATE TRANSACTION")

        var metadataStatement: OpaquePointer?
        var ftsStatement: OpaquePointer?
        var contentStatement: OpaquePointer?
        var deleteNGramsStatement: OpaquePointer?
        var insertNGramsStatement: OpaquePointer?
        var semanticItemStatement: OpaquePointer?
        var deleteSemanticStatement: OpaquePointer?
        var deleteFamilyStatement: OpaquePointer?
        var insertSemanticStatement: OpaquePointer?
        var insertFamilyStatement: OpaquePointer?
        defer {
            sqlite3_finalize(metadataStatement)
            sqlite3_finalize(ftsStatement)
            sqlite3_finalize(contentStatement)
            sqlite3_finalize(deleteNGramsStatement)
            sqlite3_finalize(insertNGramsStatement)
            sqlite3_finalize(semanticItemStatement)
            sqlite3_finalize(deleteSemanticStatement)
            sqlite3_finalize(deleteFamilyStatement)
            sqlite3_finalize(insertSemanticStatement)
            sqlite3_finalize(insertFamilyStatement)
        }
        do {
            try prepare(
                database,
                sql: "UPDATE sounds SET custom_name = ?, tags_json = ? WHERE id = ?",
                statement: &metadataStatement
            )
            try prepare(
                database,
                sql: """
                    UPDATE sounds_fts SET content = (
                        SELECT coalesce(custom_name, '') || ' ' || file_name || ' ' || relative_path
                            || ' ' || folder_path || ' ' || file_extension || ' ' || tags_json
                        FROM sounds WHERE sounds.id = sounds_fts.sound_id
                    ) WHERE sound_id = ?
                """,
                statement: &ftsStatement
            )
            try prepare(
                database,
                sql: "SELECT content FROM sounds_fts WHERE sound_id = ?",
                statement: &contentStatement
            )
            try prepare(
                database,
                sql: "DELETE FROM sound_ngrams WHERE sound_id = ?",
                statement: &deleteNGramsStatement
            )
            try prepare(
                database,
                sql: "INSERT OR IGNORE INTO sound_ngrams (sound_id, gram) VALUES (?, ?)",
                statement: &insertNGramsStatement
            )
            try prepare(
                database,
                sql: """
                    SELECT id, package_id, relative_path, file_name, folder_path, file_extension,
                           duration, sample_rate, channel_count, source_file_size,
                           source_modified_at, source_content_signature, favorite, hidden,
                           custom_name, tags_json
                    FROM sounds WHERE id = ?
                    """,
                statement: &semanticItemStatement
            )
            try prepare(
                database,
                sql: "DELETE FROM sound_semantic_concepts WHERE sound_id = ?",
                statement: &deleteSemanticStatement
            )
            try prepare(
                database,
                sql: "DELETE FROM sound_variant_families WHERE sound_id = ?",
                statement: &deleteFamilyStatement
            )
            try prepare(
                database,
                sql: """
                    INSERT INTO sound_semantic_concepts (sound_id, concept, weight)
                    VALUES (?, ?, ?)
                    """,
                statement: &insertSemanticStatement
            )
            try prepare(
                database,
                sql: """
                    INSERT INTO sound_variant_families (sound_id, family_key, family_title)
                    VALUES (?, ?, ?)
                    """,
                statement: &insertFamilyStatement
            )
            progress?(0, updates.count)
            let progressStep = max(1, updates.count / 100)
            for (index, update) in updates.enumerated() {
                try Task.checkCancellation()
                let tagData = try Self.compactEncoder.encode(SoundItem.normalizedTags(update.tags))
                let tagJSON = String(decoding: tagData, as: UTF8.self)
                sqlite3_reset(metadataStatement)
                sqlite3_clear_bindings(metadataStatement)
                bind(update.customName.map(SQLiteBinding.text) ?? .null, to: 1, in: metadataStatement)
                bind(.text(tagJSON), to: 2, in: metadataStatement)
                bind(.text(update.soundID.uuidString), to: 3, in: metadataStatement)
                try stepDone(metadataStatement, database: database)

                sqlite3_reset(ftsStatement)
                sqlite3_clear_bindings(ftsStatement)
                bind(.text(update.soundID.uuidString), to: 1, in: ftsStatement)
                try stepDone(ftsStatement, database: database)

                sqlite3_reset(contentStatement)
                sqlite3_clear_bindings(contentStatement)
                bind(.text(update.soundID.uuidString), to: 1, in: contentStatement)
                let content = sqlite3_step(contentStatement) == SQLITE_ROW
                    ? columnText(contentStatement, 0)
                    : ""

                sqlite3_reset(deleteNGramsStatement)
                sqlite3_clear_bindings(deleteNGramsStatement)
                bind(.text(update.soundID.uuidString), to: 1, in: deleteNGramsStatement)
                try stepDone(deleteNGramsStatement, database: database)
                try insertSearchNGrams(
                    soundID: update.soundID,
                    content: content,
                    into: database,
                    statement: insertNGramsStatement
                )

                sqlite3_reset(semanticItemStatement)
                sqlite3_clear_bindings(semanticItemStatement)
                bind(.text(update.soundID.uuidString), to: 1, in: semanticItemStatement)
                let semanticItem = sqlite3_step(semanticItemStatement) == SQLITE_ROW
                    ? semanticSoundItem(from: semanticItemStatement)
                    : nil
                sqlite3_reset(semanticItemStatement)

                sqlite3_reset(deleteSemanticStatement)
                sqlite3_clear_bindings(deleteSemanticStatement)
                bind(.text(update.soundID.uuidString), to: 1, in: deleteSemanticStatement)
                try stepDone(deleteSemanticStatement, database: database)
                sqlite3_reset(deleteFamilyStatement)
                sqlite3_clear_bindings(deleteFamilyStatement)
                bind(.text(update.soundID.uuidString), to: 1, in: deleteFamilyStatement)
                try stepDone(deleteFamilyStatement, database: database)
                if let semanticItem {
                    try insertSemanticProfile(
                        for: semanticItem,
                        into: database,
                        conceptStatement: insertSemanticStatement,
                        familyStatement: insertFamilyStatement
                    )
                }
                let completed = index + 1
                if completed == updates.count || completed.isMultiple(of: progressStep) {
                    progress?(completed, updates.count)
                }
            }
            try execute(database, "COMMIT")
        } catch {
            try? execute(database, "ROLLBACK")
            throw error
        }
    }

    func updateHidden(soundIDs: [UUID], isHidden: Bool) throws {
        guard !soundIDs.isEmpty else { return }
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try createSchema(in: database)
        try execute(database, "BEGIN IMMEDIATE TRANSACTION")
        var statement: OpaquePointer?
        do {
            try prepare(
                database,
                sql: "UPDATE sounds SET hidden = ? WHERE id = ?",
                statement: &statement
            )
            defer { sqlite3_finalize(statement) }
            for soundID in soundIDs {
                try Task.checkCancellation()
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(.integer(isHidden ? 1 : 0), to: 1, in: statement)
                bind(.text(soundID.uuidString), to: 2, in: statement)
                try stepDone(statement, database: database)
            }
            try execute(database, "COMMIT")
        } catch {
            try? execute(database, "ROLLBACK")
            throw error
        }
    }

    func loadIgnoredDuplicateFingerprints() throws -> Set<String> {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try createSchema(in: database)
        var statement: OpaquePointer?
        try prepare(
            database,
            sql: "SELECT fingerprint FROM ignored_duplicate_groups",
            statement: &statement
        )
        defer { sqlite3_finalize(statement) }
        var fingerprints = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            fingerprints.insert(columnText(statement, 0))
        }
        try ensureReadCompleted(statement, database: database)
        return fingerprints
    }

    func setDuplicateGroupIgnored(fingerprint: String, isIgnored: Bool) throws {
        guard !fingerprint.isEmpty, fingerprint.count <= 512 else { return }
        if isIgnored {
            try update(
                sql: "INSERT OR REPLACE INTO ignored_duplicate_groups (fingerprint, ignored_at) VALUES (?, ?)",
                bindings: [.text(fingerprint), .double(Date().timeIntervalSince1970)]
            )
        } else {
            try update(
                sql: "DELETE FROM ignored_duplicate_groups WHERE fingerprint = ?",
                bindings: [.text(fingerprint)]
            )
        }
    }

    func searchSoundIDs(matching query: String) throws -> Set<UUID> {
        let tokens = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }

        let matchQuery = tokens.map { "\"\($0)\"*" }.joined(separator: " AND ")
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try createSchema(in: database)
        var statement: OpaquePointer?
        try prepare(
            database,
            sql: "SELECT sound_id FROM sounds_fts WHERE sounds_fts MATCH ?",
            statement: &statement
        )
        defer { sqlite3_finalize(statement) }
        bind(.text(matchQuery), to: 1, in: statement)

        var ids = Set<UUID>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = UUID(uuidString: columnText(statement, 0)) {
                ids.insert(id)
            }
        }
        try ensureReadCompleted(statement, database: database)

        // `unicode61` is excellent for Latin filenames but treats a contiguous Chinese
        // phrase as one token. A search for a character in the middle of "银色呼啸"
        // therefore misses the sound even though the user can plainly see it. Merge an
        // indexed character lookup for CJK queries; English searches stay on the fast FTS path.
        if tokens.contains(where: Self.containsCJK) {
            ids.formUnion(try searchSoundIDsByNGrams(tokens, in: database))
        }
        return ids
    }

    func searchSoundMatches(
        matching value: String,
        mode: LibrarySearchMode,
        progress: (@Sendable (SemanticIndexProgress) -> Void)? = nil
    ) throws -> LibrarySearchMatches {
        let literalIDs = try searchSoundIDs(matching: value)
        var relevance = Dictionary(uniqueKeysWithValues: literalIDs.map { ($0, 1_000.0) })
        guard mode == .hybrid else {
            return LibrarySearchMatches(
                ids: literalIDs,
                literalIDs: literalIDs,
                relevanceByID: relevance,
                semanticMatchCount: 0,
                conceptTitles: [],
                creatorIntent: .empty,
                intent: .empty
            )
        }

        let semanticQuery = SoundSemanticEngine.query(value)
        guard !semanticQuery.isEmpty else {
            return LibrarySearchMatches(
                ids: literalIDs,
                literalIDs: literalIDs,
                relevanceByID: relevance,
                semanticMatchCount: 0,
                conceptTitles: [],
                creatorIntent: semanticQuery.creatorIntent,
                intent: semanticQuery.intent
            )
        }

        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try createSchema(in: database)
        try rebuildSemanticIndexIfNeeded(in: database, progress: progress)

        let conceptIDs = Array(semanticQuery.concepts.keys)
        // Some creator phrases contain a scene anchor whose meaning must survive the
        // combination stage. A generic public-space sound (for example applause) should not
        // satisfy “咖啡馆约会” merely because both are loosely associated with people. Keep the
        // cafe anchor as a hard constraint; other concepts remain soft so sparse libraries can
        // still return useful fallbacks. q:cafe is stored in profiles whose visible metadata
        // actually says cafe/coffeehouse, while ambienceCrowd also includes applause, markets,
        // and public halls. Requiring the specific qualifier prevents those broad public-space
        // files from taking over “咖啡馆约会”.
        let detailConceptIDs = semanticQuery.concepts.keys.filter { $0.hasPrefix("detail:") }
        let requiredConceptIDs: [String]
        if semanticQuery.concepts["q:cafe"] != nil {
            requiredConceptIDs = ["q:cafe"]
        } else if detailConceptIDs.count == 1 {
            requiredConceptIDs = detailConceptIDs
        } else {
            requiredConceptIDs = detailConceptIDs.filter {
                $0 == "detail:\(SmartSubcollection.ambienceCrowd.rawValue)"
            }
        }
        let placeholders = Array(repeating: "?", count: conceptIDs.count).joined(separator: ",")
        var statement: OpaquePointer?
        try prepare(
            database,
            sql: """
                SELECT sound_id, concept, weight
                FROM sound_semantic_concepts
                WHERE concept IN (\(placeholders))
                """,
            statement: &statement
        )
        defer { sqlite3_finalize(statement) }
        for (index, concept) in conceptIDs.enumerated() {
            bind(.text(concept), to: Int32(index + 1), in: statement)
        }

        struct Accumulator {
            var score = 0.0
            var matched = Set<String>()
        }
        var candidates: [UUID: Accumulator] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: columnText(statement, 0)) else { continue }
            let concept = columnText(statement, 1)
            let itemWeight = sqlite3_column_double(statement, 2)
            let queryWeight = semanticQuery.concepts[concept] ?? 0
            candidates[id, default: Accumulator()].score += itemWeight * queryWeight
            candidates[id, default: Accumulator()].matched.insert(concept)
        }
        try ensureReadCompleted(statement, database: database)

        // Qualifiers such as “浪漫/轻柔” describe the creator's intent but are not present on
        // most legacy files' profiles. When a concrete scene anchor exists, let that anchor
        // admit candidates and use the remaining concepts only for ranking; otherwise retain
        // the normal multi-concept coverage gate.
        let requiredMatches = requiredConceptIDs.isEmpty
            ? max(1, Int(ceil(Double(conceptIDs.count) * 0.45)))
            : 1
        var semanticCount = 0
        var semanticRelevance: [UUID: Double] = [:]
        for (id, candidate) in candidates where candidate.matched.count >= requiredMatches
            && requiredConceptIDs.allSatisfy(candidate.matched.contains)
            && (detailConceptIDs.isEmpty || detailConceptIDs.contains(where: candidate.matched.contains)) {
            if !literalIDs.contains(id) { semanticCount += 1 }
            semanticRelevance[id] = candidate.score
            relevance[id] = max(relevance[id] ?? 0, 100 + candidate.score * 100)
        }
        return LibrarySearchMatches(
            ids: Set(relevance.keys),
            literalIDs: literalIDs,
            relevanceByID: relevance,
            semanticRelevanceByID: semanticRelevance,
            semanticMatchCount: semanticCount,
            conceptTitles: semanticQuery.conceptTitles,
            creatorIntent: semanticQuery.creatorIntent,
            intent: semanticQuery.intent
        )
    }

    func similarityCandidates(
        for soundID: UUID,
        progress: (@Sendable (SemanticIndexProgress) -> Void)? = nil
    ) throws -> [SoundSimilarityIndexCandidate] {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try createSchema(in: database)
        try rebuildSemanticIndexIfNeeded(in: database, progress: progress)

        var familyStatement: OpaquePointer?
        try prepare(
            database,
            sql: "SELECT family_key FROM sound_variant_families WHERE sound_id = ?",
            statement: &familyStatement
        )
        bind(.text(soundID.uuidString), to: 1, in: familyStatement)
        let familyKey = sqlite3_step(familyStatement) == SQLITE_ROW
            ? columnText(familyStatement, 0)
            : nil
        sqlite3_finalize(familyStatement)

        var familyIDs = Set<UUID>()
        if let familyKey {
            var membersStatement: OpaquePointer?
            try prepare(
                database,
                sql: "SELECT sound_id FROM sound_variant_families WHERE family_key = ?",
                statement: &membersStatement
            )
            bind(.text(familyKey), to: 1, in: membersStatement)
            while sqlite3_step(membersStatement) == SQLITE_ROW {
                if let id = UUID(uuidString: columnText(membersStatement, 0)), id != soundID {
                    familyIDs.insert(id)
                }
            }
            try ensureReadCompleted(membersStatement, database: database)
            sqlite3_finalize(membersStatement)
        }

        var statement: OpaquePointer?
        try prepare(
            database,
            sql: """
                SELECT related.sound_id, related.concept, source.weight * related.weight
                FROM sound_semantic_concepts AS source
                JOIN sound_semantic_concepts AS related
                  ON related.concept = source.concept
                WHERE source.sound_id = ? AND related.sound_id != ?
                """,
            statement: &statement
        )
        defer { sqlite3_finalize(statement) }
        bind(.text(soundID.uuidString), to: 1, in: statement)
        bind(.text(soundID.uuidString), to: 2, in: statement)

        struct Accumulator {
            var score = 0.0
            var concepts = Set<String>()
        }
        var values: [UUID: Accumulator] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            try Task.checkCancellation()
            guard let id = UUID(uuidString: columnText(statement, 0)) else { continue }
            values[id, default: Accumulator()].score += sqlite3_column_double(statement, 2)
            values[id, default: Accumulator()].concepts.insert(columnText(statement, 1))
        }
        try ensureReadCompleted(statement, database: database)
        for id in familyIDs where values[id] == nil {
            values[id] = Accumulator()
        }

        return values.map { id, value in
            SoundSimilarityIndexCandidate(
                soundID: id,
                semanticScore: value.score,
                sharedConceptIDs: value.concepts.sorted(),
                isSameFamily: familyIDs.contains(id)
            )
        }
        .sorted {
            if $0.isSameFamily != $1.isSameFamily { return $0.isSameFamily }
            return $0.semanticScore > $1.semanticScore
        }
        .prefix(400)
        .map { $0 }
    }

    func saveMetadataUndoBatch(_ batch: MetadataUndoBatch) throws {
        let payload = try Self.compactEncoder.encode(batch)
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try createSchema(in: database)
        try executeUpdate(
            database,
            sql: """
                INSERT OR REPLACE INTO metadata_undo_batches (id, created_at, payload)
                VALUES (?, ?, ?)
                """,
            bindings: [
                .text(batch.id.uuidString),
                .double(batch.createdAt.timeIntervalSince1970),
                .blob(payload)
            ]
        )
        try execute(database, """
            DELETE FROM metadata_undo_batches
            WHERE id NOT IN (
                SELECT id FROM metadata_undo_batches ORDER BY created_at DESC LIMIT 8
            )
            """)
    }

    func loadLatestMetadataUndoBatch() throws -> MetadataUndoBatch? {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try createSchema(in: database)
        var statement: OpaquePointer?
        try prepare(
            database,
            sql: "SELECT payload FROM metadata_undo_batches ORDER BY created_at DESC LIMIT 1",
            statement: &statement
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let payload = columnData(statement, 0) else {
            return nil
        }
        return try Self.compactDecoder.decode(MetadataUndoBatch.self, from: payload)
    }

    func deleteMetadataUndoBatch(id: UUID) throws {
        try update(
            sql: "DELETE FROM metadata_undo_batches WHERE id = ?",
            bindings: [.text(id.uuidString)]
        )
    }

    private func searchSoundIDsByNGrams(
        _ tokens: [String],
        in database: OpaquePointer
    ) throws -> Set<UUID> {
        var grams: [String] = []
        var seen = Set<String>()
        for token in tokens {
            for scalar in token.unicodeScalars where Self.isCJK(scalar) {
                let gram = String(scalar)
                if seen.insert(gram).inserted {
                    grams.append(gram)
                }
            }
        }
        guard !grams.isEmpty else { return [] }

        let placeholders = Array(repeating: "?", count: grams.count).joined(separator: ",")
        let sql = """
            SELECT sound_id
            FROM sound_ngrams
            WHERE gram IN (\(placeholders))
            GROUP BY sound_id
            HAVING COUNT(DISTINCT gram) = ?
            """
        var statement: OpaquePointer?
        try prepare(database, sql: sql, statement: &statement)
        defer { sqlite3_finalize(statement) }

        for (index, gram) in grams.enumerated() {
            bind(.text(gram), to: Int32(index + 1), in: statement)
        }
        bind(.integer(Int64(grams.count)), to: Int32(grams.count + 1), in: statement)

        var ids = Set<UUID>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = UUID(uuidString: columnText(statement, 0)) {
                ids.insert(id)
            }
        }
        try ensureReadCompleted(statement, database: database)
        return ids
    }

    private static func containsCJK(_ value: String) -> Bool {
        value.unicodeScalars.contains(where: isCJK)
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }

    private func insertSearchNGrams(
        soundID: UUID,
        content: String,
        into database: OpaquePointer,
        statement: OpaquePointer?
    ) throws {
        var seen = Set<String>()
        for scalar in content.unicodeScalars where Self.isCJK(scalar) {
            let gram = String(scalar)
            guard seen.insert(gram).inserted else { continue }
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            bind(.text(soundID.uuidString), to: 1, in: statement)
            bind(.text(gram), to: 2, in: statement)
            try stepDone(statement, database: database)
        }
    }

    func loadAudioIntelligence() throws -> [UUID: AudioIntelligence] {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try createSchema(in: database)
        var statement: OpaquePointer?
        try prepare(
            database,
            sql: """
                SELECT sound_id, bpm, bpm_confidence, loudness_lufs,
                       key_root, key_mode, key_confidence, analyzed_at,
                       acoustic_fingerprint
                FROM sound_intelligence
                """,
            statement: &statement
        )
        defer { sqlite3_finalize(statement) }

        var values: [UUID: AudioIntelligence] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let soundID = UUID(uuidString: columnText(statement, 0)) else { continue }
            let key: MusicalKey?
            if let root = MusicalKey.PitchClass(rawValue: Int(sqlite3_column_int(statement, 4))),
               let mode = MusicalKey.Mode(rawValue: columnText(statement, 5)) {
                key = MusicalKey(root: root, mode: mode)
            } else {
                key = nil
            }
            let acousticFingerprint = columnData(statement, 8).flatMap {
                try? Self.compactDecoder.decode(AcousticFingerprint.self, from: $0)
            }
            values[soundID] = AudioIntelligence(
                bpm: columnOptionalDouble(statement, 1),
                bpmConfidence: sqlite3_column_double(statement, 2),
                loudnessLUFS: columnOptionalDouble(statement, 3),
                musicalKey: key,
                keyConfidence: sqlite3_column_double(statement, 6),
                acousticFingerprint: acousticFingerprint,
                analyzedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
            )
        }
        try ensureReadCompleted(statement, database: database)
        return values
    }

    func saveAudioIntelligence(soundID: UUID, intelligence: AudioIntelligence) throws {
        try update(
            sql: """
                INSERT INTO sound_intelligence
                (sound_id, bpm, bpm_confidence, loudness_lufs, key_root,
                 key_mode, key_confidence, analyzed_at, acoustic_fingerprint)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(sound_id) DO UPDATE SET
                    bpm = excluded.bpm,
                    bpm_confidence = excluded.bpm_confidence,
                    loudness_lufs = excluded.loudness_lufs,
                    key_root = excluded.key_root,
                    key_mode = excluded.key_mode,
                    key_confidence = excluded.key_confidence,
                    analyzed_at = excluded.analyzed_at,
                    acoustic_fingerprint = excluded.acoustic_fingerprint
                """,
            bindings: [
                .text(soundID.uuidString),
                intelligence.bpm.map(SQLiteBinding.double) ?? .null,
                .double(intelligence.bpmConfidence),
                intelligence.loudnessLUFS.map(SQLiteBinding.double) ?? .null,
                intelligence.musicalKey.map { .integer(Int64($0.root.rawValue)) } ?? .null,
                intelligence.musicalKey.map { .text($0.mode.rawValue) } ?? .null,
                .double(intelligence.keyConfidence),
                .double(intelligence.analyzedAt.timeIntervalSince1970),
                intelligence.acousticFingerprint.flatMap {
                    try? Self.compactEncoder.encode($0)
                }.map(SQLiteBinding.blob) ?? .null
            ]
        )
    }

    func loadSavedCollections() throws -> [SavedCollection] {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try createSchema(in: database)

        var statement: OpaquePointer?
        try prepare(
            database,
            sql: """
                SELECT id, name, scope_json, query, file_extension,
                       minimum_duration, maximum_duration, favorites_only, created_at
                FROM saved_collections ORDER BY created_at, name COLLATE NOCASE
                """,
            statement: &statement
        )
        defer { sqlite3_finalize(statement) }

        var collections: [SavedCollection] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: columnText(statement, 0)) else { continue }
            let scopeData = columnText(statement, 2).data(using: .utf8) ?? Data()
            let scope = (try? Self.compactDecoder.decode(SavedCollectionScope.self, from: scopeData)) ?? .all
            collections.append(
                SavedCollection(
                    id: id,
                    name: columnText(statement, 1),
                    scope: scope,
                    query: columnText(statement, 3),
                    fileExtension: columnOptionalText(statement, 4),
                    minimumDuration: columnOptionalDouble(statement, 5),
                    maximumDuration: columnOptionalDouble(statement, 6),
                    favoritesOnly: sqlite3_column_int(statement, 7) != 0,
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))
                )
            )
        }
        try ensureReadCompleted(statement, database: database)
        return collections
    }

    func saveSavedCollection(_ collection: SavedCollection) throws {
        let scopeData = try Self.compactEncoder.encode(collection.scope)
        try update(
            sql: """
                INSERT INTO saved_collections
                (id, name, scope_json, query, file_extension, minimum_duration,
                 maximum_duration, favorites_only, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    scope_json = excluded.scope_json,
                    query = excluded.query,
                    file_extension = excluded.file_extension,
                    minimum_duration = excluded.minimum_duration,
                    maximum_duration = excluded.maximum_duration,
                    favorites_only = excluded.favorites_only,
                    created_at = excluded.created_at
                """,
            bindings: [
                .text(collection.id.uuidString),
                .text(collection.name),
                .text(String(decoding: scopeData, as: UTF8.self)),
                .text(collection.query),
                collection.fileExtension.map(SQLiteBinding.text) ?? .null,
                collection.minimumDuration.map(SQLiteBinding.double) ?? .null,
                collection.maximumDuration.map(SQLiteBinding.double) ?? .null,
                .integer(collection.favoritesOnly ? 1 : 0),
                .double(collection.createdAt.timeIntervalSince1970)
            ]
        )
    }

    func deleteSavedCollection(id: UUID) throws {
        try update(
            sql: "DELETE FROM saved_collections WHERE id = ?",
            bindings: [.text(id.uuidString)]
        )
    }

    var databaseSize: Int64 {
        (try? databaseURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    var hasRecoveryBackup: Bool {
        FileManager.default.fileExists(atPath: backupURL.path)
    }

    private func loadDatabase() throws -> [SoundPack] {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try createSchema(in: database)

        var packs: [SoundPack] = []
        var packIndex: [UUID: Int] = [:]
        var statement: OpaquePointer?
        let packSQL = """
            SELECT id, name, root_path, bookmark, imported_at, last_scanned_at
            FROM packs ORDER BY name COLLATE NOCASE
        """
        try prepare(database, sql: packSQL, statement: &statement)

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: columnText(statement, 0)) else { continue }
            let bookmark = columnData(statement, 3)
            let pack = SoundPack(
                id: id,
                name: columnText(statement, 1),
                rootPath: columnText(statement, 2),
                bookmarkData: bookmark,
                importedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                lastScannedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                items: []
            )
            packIndex[id] = packs.count
            packs.append(pack)
        }
        try ensureReadCompleted(statement, database: database)
        sqlite3_finalize(statement)
        statement = nil

        let soundSQL = """
            SELECT id, package_id, relative_path, file_name, folder_path, file_extension,
                   duration, sample_rate, channel_count, source_file_size, source_modified_at,
                   source_content_signature, favorite, hidden, custom_name, tags_json
            FROM sounds ORDER BY package_id, relative_path COLLATE NOCASE
            """
        try prepare(database, sql: soundSQL, statement: &statement)
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: columnText(statement, 0)),
                  let packageID = UUID(uuidString: columnText(statement, 1)),
                  let index = packIndex[packageID] else { continue }
            let tags: [String]
            if let data = columnText(statement, 15).data(using: .utf8),
               let decoded = try? Self.compactDecoder.decode([String].self, from: data) {
                tags = decoded
            } else {
                tags = []
            }
            packs[index].items.append(
                SoundItem(
                    id: id,
                    packageID: packageID,
                    relativePath: columnText(statement, 2),
                    fileName: columnText(statement, 3),
                    folderPath: columnText(statement, 4),
                    fileExtension: columnText(statement, 5),
                    duration: sqlite3_column_double(statement, 6),
                    sampleRate: columnOptionalDouble(statement, 7),
                    channelCount: columnOptionalInt(statement, 8),
                    sourceFileSize: columnOptionalInt64(statement, 9),
                    sourceModificationDate: columnOptionalDouble(statement, 10)
                        .map(Date.init(timeIntervalSince1970:)),
                    sourceContentSignature: columnOptionalUInt64(statement, 11),
                    isFavorite: sqlite3_column_int(statement, 12) != 0,
                    isHidden: sqlite3_column_int(statement, 13) != 0,
                    customName: columnOptionalText(statement, 14),
                    tags: tags
                )
            )
        }
        try ensureReadCompleted(statement, database: database)
        return packs
    }

    private func insert(packs: [SoundPack], into database: OpaquePointer) throws {
        var packStatement: OpaquePointer?
        var soundStatement: OpaquePointer?
        var ftsStatement: OpaquePointer?
        var ngramStatement: OpaquePointer?
        try prepare(
            database,
            sql: "INSERT INTO packs (id,name,root_path,bookmark,imported_at,last_scanned_at) VALUES (?,?,?,?,?,?)",
            statement: &packStatement
        )
        defer { sqlite3_finalize(packStatement) }
        try prepare(
            database,
            sql: """
                INSERT INTO sounds
                (id,package_id,relative_path,file_name,folder_path,file_extension,duration,
                 sample_rate,channel_count,source_file_size,source_modified_at,
                 source_content_signature,favorite,hidden,custom_name,tags_json)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """,
            statement: &soundStatement
        )
        defer { sqlite3_finalize(soundStatement) }
        try prepare(
            database,
            sql: "INSERT INTO sounds_fts (sound_id, content) VALUES (?, ?)",
            statement: &ftsStatement
        )
        defer { sqlite3_finalize(ftsStatement) }
        try prepare(
            database,
            sql: "INSERT OR IGNORE INTO sound_ngrams (sound_id, gram) VALUES (?, ?)",
            statement: &ngramStatement
        )
        defer { sqlite3_finalize(ngramStatement) }
        var semanticConceptRows: [SemanticConceptRow] = []
        var semanticFamilyRows: [SemanticFamilyRow] = []
        semanticConceptRows.reserveCapacity(Self.semanticBatchSize + 8)
        semanticFamilyRows.reserveCapacity(Self.semanticBatchSize)

        for pack in packs {
            sqlite3_reset(packStatement)
            sqlite3_clear_bindings(packStatement)
            bind(.text(pack.id.uuidString), to: 1, in: packStatement)
            bind(.text(pack.name), to: 2, in: packStatement)
            bind(.text(pack.rootPath), to: 3, in: packStatement)
            bind(pack.bookmarkData.map(SQLiteBinding.blob) ?? .null, to: 4, in: packStatement)
            bind(.double(pack.importedAt.timeIntervalSince1970), to: 5, in: packStatement)
            bind(.double(pack.lastScannedAt.timeIntervalSince1970), to: 6, in: packStatement)
            try stepDone(packStatement, database: database)

            for item in pack.items {
                sqlite3_reset(soundStatement)
                sqlite3_clear_bindings(soundStatement)
                let tagData = try Self.compactEncoder.encode(item.tags)
                let values: [SQLiteBinding] = [
                    .text(item.id.uuidString), .text(item.packageID.uuidString),
                    .text(item.relativePath), .text(item.fileName), .text(item.folderPath),
                    .text(item.fileExtension), .double(item.duration),
                    item.sampleRate.map(SQLiteBinding.double) ?? .null,
                    item.channelCount.map { .integer(Int64($0)) } ?? .null,
                    item.sourceFileSize.map { .integer($0) } ?? .null,
                    item.sourceModificationDate
                        .map { .double($0.timeIntervalSince1970) } ?? .null,
                    item.sourceContentSignature
                        .map { .integer(Int64(bitPattern: $0)) } ?? .null,
                    .integer(item.isFavorite ? 1 : 0),
                    .integer(item.isHidden ? 1 : 0),
                    item.customName.map(SQLiteBinding.text) ?? .null,
                    .text(String(decoding: tagData, as: UTF8.self))
                ]
                for (offset, value) in values.enumerated() {
                    bind(value, to: Int32(offset + 1), in: soundStatement)
                }
                try stepDone(soundStatement, database: database)

                sqlite3_reset(ftsStatement)
                sqlite3_clear_bindings(ftsStatement)
                bind(.text(item.id.uuidString), to: 1, in: ftsStatement)
                bind(.text(item.searchableText), to: 2, in: ftsStatement)
                try stepDone(ftsStatement, database: database)
                try insertSearchNGrams(
                    soundID: item.id,
                    content: item.searchableText,
                    into: database,
                    statement: ngramStatement
                )
                appendSemanticRows(
                    for: item,
                    concepts: &semanticConceptRows,
                    families: &semanticFamilyRows
                )
                if semanticConceptRows.count >= Self.semanticBatchSize
                    || semanticFamilyRows.count >= Self.semanticBatchSize {
                    try insertSemanticRows(
                        concepts: semanticConceptRows,
                        families: semanticFamilyRows,
                        into: database
                    )
                    semanticConceptRows.removeAll(keepingCapacity: true)
                    semanticFamilyRows.removeAll(keepingCapacity: true)
                }
            }
        }
        try insertSemanticRows(
            concepts: semanticConceptRows,
            families: semanticFamilyRows,
            into: database
        )
    }

    private func insert(
        savedCollections: [SavedCollection],
        into database: OpaquePointer
    ) throws {
        guard !savedCollections.isEmpty else { return }
        var statement: OpaquePointer?
        try prepare(
            database,
            sql: """
                INSERT INTO saved_collections
                (id, name, scope_json, query, file_extension, minimum_duration,
                 maximum_duration, favorites_only, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            statement: &statement
        )
        defer { sqlite3_finalize(statement) }

        for collection in savedCollections {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            let scopeData = try Self.compactEncoder.encode(collection.scope)
            let bindings: [SQLiteBinding] = [
                .text(collection.id.uuidString),
                .text(collection.name),
                .text(String(decoding: scopeData, as: UTF8.self)),
                .text(collection.query),
                collection.fileExtension.map(SQLiteBinding.text) ?? .null,
                collection.minimumDuration.map(SQLiteBinding.double) ?? .null,
                collection.maximumDuration.map(SQLiteBinding.double) ?? .null,
                .integer(collection.favoritesOnly ? 1 : 0),
                .double(collection.createdAt.timeIntervalSince1970)
            ]
            for (offset, value) in bindings.enumerated() {
                bind(value, to: Int32(offset + 1), in: statement)
            }
            try stepDone(statement, database: database)
        }
    }

    private func insert(
        ignoredDuplicateFingerprints: Set<String>,
        into database: OpaquePointer
    ) throws {
        guard !ignoredDuplicateFingerprints.isEmpty else { return }
        var statement: OpaquePointer?
        try prepare(
            database,
            sql: "INSERT INTO ignored_duplicate_groups (fingerprint, ignored_at) VALUES (?, ?)",
            statement: &statement
        )
        defer { sqlite3_finalize(statement) }
        let now = Date().timeIntervalSince1970
        for fingerprint in ignoredDuplicateFingerprints where !fingerprint.isEmpty && fingerprint.count <= 512 {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            bind(.text(fingerprint), to: 1, in: statement)
            bind(.double(now), to: 2, in: statement)
            try stepDone(statement, database: database)
        }
    }

    private func insert(
        intelligenceByID: [UUID: AudioIntelligence],
        into database: OpaquePointer
    ) throws {
        guard !intelligenceByID.isEmpty else { return }
        var statement: OpaquePointer?
        try prepare(
            database,
            sql: """
                INSERT INTO sound_intelligence
                (sound_id, bpm, bpm_confidence, loudness_lufs, key_root,
                 key_mode, key_confidence, analyzed_at, acoustic_fingerprint)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            statement: &statement
        )
        defer { sqlite3_finalize(statement) }

        for (soundID, intelligence) in intelligenceByID {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            let bindings: [SQLiteBinding] = [
                .text(soundID.uuidString),
                intelligence.bpm.map(SQLiteBinding.double) ?? .null,
                .double(intelligence.bpmConfidence),
                intelligence.loudnessLUFS.map(SQLiteBinding.double) ?? .null,
                intelligence.musicalKey.map { .integer(Int64($0.root.rawValue)) } ?? .null,
                intelligence.musicalKey.map { .text($0.mode.rawValue) } ?? .null,
                .double(intelligence.keyConfidence),
                .double(intelligence.analyzedAt.timeIntervalSince1970),
                intelligence.acousticFingerprint.flatMap {
                    try? Self.compactEncoder.encode($0)
                }.map(SQLiteBinding.blob) ?? .null
            ]
            for (offset, value) in bindings.enumerated() {
                bind(value, to: Int32(offset + 1), in: statement)
            }
            try stepDone(statement, database: database)
        }
    }

    private func insert(
        namingProfile: JacksunNamingProfile,
        into database: OpaquePointer
    ) throws {
        let data = try Self.compactEncoder.encode(namingProfile)
        try executeUpdate(
            database,
            sql: """
                INSERT INTO naming_profile (id, payload) VALUES (1, ?)
                ON CONFLICT(id) DO UPDATE SET payload = excluded.payload
                """,
            bindings: [.blob(data)]
        )
    }

    private func insertSemanticProfile(
        for item: SoundItem,
        into database: OpaquePointer,
        conceptStatement: OpaquePointer?,
        familyStatement: OpaquePointer?
    ) throws {
        let profile = SoundSemanticEngine.profile(for: item)
        for (concept, weight) in profile.concepts {
            sqlite3_reset(conceptStatement)
            sqlite3_clear_bindings(conceptStatement)
            bind(.text(item.id.uuidString), to: 1, in: conceptStatement)
            bind(.text(concept), to: 2, in: conceptStatement)
            bind(.double(weight), to: 3, in: conceptStatement)
            try stepDone(conceptStatement, database: database)
        }
        if let familyKey = profile.familyKey, let familyTitle = profile.familyTitle {
            sqlite3_reset(familyStatement)
            sqlite3_clear_bindings(familyStatement)
            bind(.text(item.id.uuidString), to: 1, in: familyStatement)
            bind(.text(familyKey), to: 2, in: familyStatement)
            bind(.text(familyTitle), to: 3, in: familyStatement)
            try stepDone(familyStatement, database: database)
        }
    }

    private static let semanticBatchSize = 200

    private struct SemanticConceptRow {
        let soundID: String
        let concept: String
        let weight: Double
    }

    private struct SemanticFamilyRow {
        let soundID: String
        let familyKey: String
        let familyTitle: String
    }

    private func appendSemanticRows(
        for item: SoundItem,
        concepts: inout [SemanticConceptRow],
        families: inout [SemanticFamilyRow]
    ) {
        let profile = SoundSemanticEngine.profile(for: item)
        concepts.append(contentsOf: profile.concepts.map {
            SemanticConceptRow(
                soundID: item.id.uuidString,
                concept: $0.key,
                weight: $0.value
            )
        })
        if let familyKey = profile.familyKey, let familyTitle = profile.familyTitle {
            families.append(
                SemanticFamilyRow(
                    soundID: item.id.uuidString,
                    familyKey: familyKey,
                    familyTitle: familyTitle
                )
            )
        }
    }

    /// SQLite statement setup and stepping dominates a cold 36k-item index rebuild. Grouping
    /// generated rows into sub-999-parameter inserts keeps the same atomic transaction while
    /// reducing more than 150k individual `sqlite3_step` calls to a few hundred batches.
    private func insertSemanticRows(
        concepts: [SemanticConceptRow],
        families: [SemanticFamilyRow],
        into database: OpaquePointer
    ) throws {
        if !concepts.isEmpty {
            var statement: OpaquePointer?
            let values = Array(repeating: "(?, ?, ?)", count: concepts.count)
                .joined(separator: ",")
            try prepare(
                database,
                sql: "INSERT INTO sound_semantic_concepts (sound_id, concept, weight) VALUES \(values)",
                statement: &statement
            )
            defer { sqlite3_finalize(statement) }
            for (index, row) in concepts.enumerated() {
                let offset = Int32(index * 3)
                bind(.text(row.soundID), to: offset + 1, in: statement)
                bind(.text(row.concept), to: offset + 2, in: statement)
                bind(.double(row.weight), to: offset + 3, in: statement)
            }
            try stepDone(statement, database: database)
        }

        if !families.isEmpty {
            var statement: OpaquePointer?
            let values = Array(repeating: "(?, ?, ?)", count: families.count)
                .joined(separator: ",")
            try prepare(
                database,
                sql: "INSERT INTO sound_variant_families (sound_id, family_key, family_title) VALUES \(values)",
                statement: &statement
            )
            defer { sqlite3_finalize(statement) }
            for (index, row) in families.enumerated() {
                let offset = Int32(index * 3)
                bind(.text(row.soundID), to: offset + 1, in: statement)
                bind(.text(row.familyKey), to: offset + 2, in: statement)
                bind(.text(row.familyTitle), to: offset + 3, in: statement)
            }
            try stepDone(statement, database: database)
        }
    }

    private func updateSemanticIndexState(in database: OpaquePointer) throws {
        let soundCount = try scalarInt64(in: database, sql: "SELECT COUNT(*) FROM sounds")
        try executeUpdate(
            database,
            sql: """
                INSERT INTO semantic_index_state (id, version, sound_count) VALUES (1, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    version = excluded.version,
                    sound_count = excluded.sound_count
                """,
            bindings: [
                .integer(Int64(SoundSemanticEngine.indexVersion)),
                .integer(soundCount)
            ]
        )
    }

    private func rebuildSemanticIndexIfNeeded(
        in database: OpaquePointer,
        progress: (@Sendable (SemanticIndexProgress) -> Void)?
    ) throws {
        let soundCount = try scalarInt64(in: database, sql: "SELECT COUNT(*) FROM sounds")
        let indexedCount = try scalarInt64(
            in: database,
            sql: "SELECT sound_count FROM semantic_index_state WHERE id = 1",
            defaultValue: -1
        )
        let version = try scalarInt64(
            in: database,
            sql: "SELECT version FROM semantic_index_state WHERE id = 1",
            defaultValue: -1
        )
        guard indexedCount != soundCount
                || version != Int64(SoundSemanticEngine.indexVersion) else {
            return
        }

        try execute(database, "BEGIN IMMEDIATE TRANSACTION")
        var selectStatement: OpaquePointer?
        defer { sqlite3_finalize(selectStatement) }
        do {
            try execute(database, "DELETE FROM sound_semantic_concepts")
            try execute(database, "DELETE FROM sound_variant_families")
            try prepare(
                database,
                sql: """
                    SELECT id, package_id, relative_path, file_name, folder_path, file_extension,
                           duration, sample_rate, channel_count, source_file_size,
                           source_modified_at, source_content_signature, favorite, hidden,
                           custom_name, tags_json
                    FROM sounds
                    """,
                statement: &selectStatement
            )
            let total = Int(soundCount)
            let progressStep = max(1, total / 100)
            progress?(SemanticIndexProgress(completed: 0, total: total))
            var completed = 0
            var semanticConceptRows: [SemanticConceptRow] = []
            var semanticFamilyRows: [SemanticFamilyRow] = []
            semanticConceptRows.reserveCapacity(Self.semanticBatchSize + 8)
            semanticFamilyRows.reserveCapacity(Self.semanticBatchSize)
            while sqlite3_step(selectStatement) == SQLITE_ROW {
                try Task.checkCancellation()
                if let item = semanticSoundItem(from: selectStatement) {
                    appendSemanticRows(
                        for: item,
                        concepts: &semanticConceptRows,
                        families: &semanticFamilyRows
                    )
                    if semanticConceptRows.count >= Self.semanticBatchSize
                        || semanticFamilyRows.count >= Self.semanticBatchSize {
                        try insertSemanticRows(
                            concepts: semanticConceptRows,
                            families: semanticFamilyRows,
                            into: database
                        )
                        semanticConceptRows.removeAll(keepingCapacity: true)
                        semanticFamilyRows.removeAll(keepingCapacity: true)
                    }
                }
                completed += 1
                if completed == total || completed.isMultiple(of: progressStep) {
                    progress?(SemanticIndexProgress(completed: completed, total: total))
                }
            }
            try ensureReadCompleted(selectStatement, database: database)
            try insertSemanticRows(
                concepts: semanticConceptRows,
                families: semanticFamilyRows,
                into: database
            )
            try updateSemanticIndexState(in: database)
            try execute(database, "COMMIT")
        } catch {
            try? execute(database, "ROLLBACK")
            throw error
        }
    }

    private func semanticSoundItem(from statement: OpaquePointer?) -> SoundItem? {
        guard let id = UUID(uuidString: columnText(statement, 0)),
              let packageID = UUID(uuidString: columnText(statement, 1)) else {
            return nil
        }
        let tags: [String]
        if let data = columnText(statement, 15).data(using: .utf8),
           let decoded = try? Self.compactDecoder.decode([String].self, from: data) {
            tags = decoded
        } else {
            tags = []
        }
        return SoundItem(
            id: id,
            packageID: packageID,
            relativePath: columnText(statement, 2),
            fileName: columnText(statement, 3),
            folderPath: columnText(statement, 4),
            fileExtension: columnText(statement, 5),
            duration: sqlite3_column_double(statement, 6),
            sampleRate: columnOptionalDouble(statement, 7),
            channelCount: columnOptionalInt(statement, 8),
            sourceFileSize: columnOptionalInt64(statement, 9),
            sourceModificationDate: columnOptionalDouble(statement, 10)
                .map(Date.init(timeIntervalSince1970:)),
            sourceContentSignature: columnOptionalUInt64(statement, 11),
            isFavorite: sqlite3_column_int(statement, 12) != 0,
            isHidden: sqlite3_column_int(statement, 13) != 0,
            customName: columnOptionalText(statement, 14),
            tags: tags
        )
    }

    private func update(sql: String, bindings: [SQLiteBinding]) throws {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try createSchema(in: database)
        try executeUpdate(database, sql: sql, bindings: bindings)
    }

    private func executeUpdate(
        _ database: OpaquePointer,
        sql: String,
        bindings: [SQLiteBinding]
    ) throws {
        var statement: OpaquePointer?
        try prepare(database, sql: sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        for (offset, value) in bindings.enumerated() {
            bind(value, to: Int32(offset + 1), in: statement)
        }
        try stepDone(statement, database: database)
    }

    private func openDatabase() throws -> OpaquePointer {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            if let database { sqlite3_close(database) }
            throw LibraryPersistenceError.sqlite(message)
        }
        sqlite3_busy_timeout(database, 5_000)
        try execute(database, "PRAGMA journal_mode=WAL")
        try execute(database, "PRAGMA synchronous=NORMAL")
        try execute(database, "PRAGMA foreign_keys=ON")
        return database
    }

    private func createSchema(in database: OpaquePointer) throws {
        try execute(database, """
            CREATE TABLE IF NOT EXISTS packs (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                root_path TEXT NOT NULL,
                bookmark BLOB,
                imported_at REAL NOT NULL,
                last_scanned_at REAL NOT NULL
            )
            """)
        try execute(database, """
            CREATE TABLE IF NOT EXISTS sounds (
                id TEXT PRIMARY KEY NOT NULL,
                package_id TEXT NOT NULL REFERENCES packs(id) ON DELETE CASCADE,
                relative_path TEXT NOT NULL,
                file_name TEXT NOT NULL,
                folder_path TEXT NOT NULL,
                file_extension TEXT NOT NULL,
                duration REAL NOT NULL DEFAULT 0,
                sample_rate REAL,
                channel_count INTEGER,
                source_file_size INTEGER,
                source_modified_at REAL,
                source_content_signature INTEGER,
                favorite INTEGER NOT NULL DEFAULT 0,
                hidden INTEGER NOT NULL DEFAULT 0,
                custom_name TEXT,
                tags_json TEXT NOT NULL DEFAULT '[]',
                UNIQUE(package_id, relative_path)
            )
            """)
        try ensureColumn(
            in: database,
            table: "sounds",
            name: "source_file_size",
            definition: "INTEGER"
        )
        try ensureColumn(
            in: database,
            table: "sounds",
            name: "source_modified_at",
            definition: "REAL"
        )
        try ensureColumn(
            in: database,
            table: "sounds",
            name: "source_content_signature",
            definition: "INTEGER"
        )
        try ensureColumn(
            in: database,
            table: "sounds",
            name: "hidden",
            definition: "INTEGER NOT NULL DEFAULT 0"
        )
        try execute(database, "CREATE INDEX IF NOT EXISTS sounds_package ON sounds(package_id)")
        try execute(database, "CREATE INDEX IF NOT EXISTS sounds_favorite ON sounds(favorite)")
        try execute(database, "CREATE INDEX IF NOT EXISTS sounds_hidden ON sounds(hidden)")
        try execute(database, "CREATE INDEX IF NOT EXISTS sounds_extension ON sounds(file_extension)")
        try execute(database, """
            CREATE VIRTUAL TABLE IF NOT EXISTS sounds_fts USING fts5(
                sound_id UNINDEXED,
                content,
                tokenize = 'unicode61 remove_diacritics 2'
            )
            """)
        try execute(database, """
            CREATE TABLE IF NOT EXISTS sound_ngrams (
                sound_id TEXT NOT NULL REFERENCES sounds(id) ON DELETE CASCADE,
                gram TEXT NOT NULL,
                PRIMARY KEY(sound_id, gram)
            )
            """)
        try execute(database, "CREATE INDEX IF NOT EXISTS sound_ngrams_gram ON sound_ngrams(gram)")
        try execute(database, """
            CREATE TABLE IF NOT EXISTS sound_ngrams_state (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                sound_count INTEGER NOT NULL DEFAULT 0
            )
            """)
        try rebuildSearchIndexIfNeeded(in: database)
        try rebuildSearchNGramIndexIfNeeded(in: database)
        try execute(database, """
            CREATE TABLE IF NOT EXISTS sound_semantic_concepts (
                sound_id TEXT NOT NULL REFERENCES sounds(id) ON DELETE CASCADE,
                concept TEXT NOT NULL,
                weight REAL NOT NULL,
                PRIMARY KEY(sound_id, concept)
            )
            """)
        try execute(
            database,
            "CREATE INDEX IF NOT EXISTS sound_semantic_concept ON sound_semantic_concepts(concept)"
        )
        try execute(database, """
            CREATE TABLE IF NOT EXISTS sound_variant_families (
                sound_id TEXT PRIMARY KEY NOT NULL REFERENCES sounds(id) ON DELETE CASCADE,
                family_key TEXT NOT NULL,
                family_title TEXT NOT NULL
            )
            """)
        try execute(
            database,
            "CREATE INDEX IF NOT EXISTS sound_variant_family_key ON sound_variant_families(family_key)"
        )
        try execute(database, """
            CREATE TABLE IF NOT EXISTS semantic_index_state (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                version INTEGER NOT NULL,
                sound_count INTEGER NOT NULL
            )
            """)
        try execute(database, """
            CREATE TABLE IF NOT EXISTS metadata_undo_batches (
                id TEXT PRIMARY KEY NOT NULL,
                created_at REAL NOT NULL,
                payload BLOB NOT NULL
            )
            """)
        try execute(
            database,
            "CREATE INDEX IF NOT EXISTS metadata_undo_created ON metadata_undo_batches(created_at DESC)"
        )
        try execute(database, """
            CREATE TABLE IF NOT EXISTS saved_collections (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                scope_json TEXT NOT NULL DEFAULT '{}',
                query TEXT NOT NULL DEFAULT '',
                file_extension TEXT,
                minimum_duration REAL,
                maximum_duration REAL,
                favorites_only INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL
            )
            """)
        try execute(database, "CREATE INDEX IF NOT EXISTS saved_collections_created ON saved_collections(created_at)")
        try execute(database, """
            CREATE TABLE IF NOT EXISTS ignored_duplicate_groups (
                fingerprint TEXT PRIMARY KEY NOT NULL,
                ignored_at REAL NOT NULL
            )
            """)
        try execute(database, """
            CREATE TABLE IF NOT EXISTS sound_intelligence (
                sound_id TEXT PRIMARY KEY NOT NULL,
                bpm REAL,
                bpm_confidence REAL NOT NULL DEFAULT 0,
                loudness_lufs REAL,
                key_root INTEGER,
                key_mode TEXT,
                key_confidence REAL NOT NULL DEFAULT 0,
                acoustic_fingerprint BLOB,
                analyzed_at REAL NOT NULL
            )
            """)
        try ensureColumn(
            in: database,
            table: "sound_intelligence",
            name: "acoustic_fingerprint",
            definition: "BLOB"
        )
        try execute(database, """
            CREATE TABLE IF NOT EXISTS naming_profile (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                payload BLOB NOT NULL
            )
            """)
    }

    private func rebuildSearchIndexIfNeeded(in database: OpaquePointer) throws {
        var statement: OpaquePointer?
        try prepare(database, sql: "SELECT COUNT(*) FROM sounds_fts", statement: &statement)
        let ftsCount: Int64
        if sqlite3_step(statement) == SQLITE_ROW {
            ftsCount = sqlite3_column_int64(statement, 0)
        } else {
            ftsCount = 0
        }
        sqlite3_finalize(statement)
        statement = nil
        guard ftsCount == 0 else { return }

        try execute(database, """
            INSERT INTO sounds_fts (sound_id, content)
            SELECT id,
                   coalesce(custom_name, '') || ' ' || file_name || ' ' || relative_path
                       || ' ' || folder_path || ' ' || file_extension || ' ' || tags_json
            FROM sounds
            """)
    }

    private func rebuildSearchNGramIndexIfNeeded(in database: OpaquePointer) throws {
        let soundCount = try scalarInt64(
            in: database,
            sql: "SELECT COUNT(*) FROM sounds"
        )
        let indexedSoundCount = try scalarInt64(
            in: database,
            sql: "SELECT sound_count FROM sound_ngrams_state WHERE id = 1",
            defaultValue: -1
        )
        guard indexedSoundCount != soundCount else { return }

        try execute(database, "DELETE FROM sound_ngrams")
        var selectStatement: OpaquePointer?
        var insertStatement: OpaquePointer?
        try prepare(
            database,
            sql: "SELECT sound_id, content FROM sounds_fts",
            statement: &selectStatement
        )
        defer { sqlite3_finalize(selectStatement) }
        try prepare(
            database,
            sql: "INSERT OR IGNORE INTO sound_ngrams (sound_id, gram) VALUES (?, ?)",
            statement: &insertStatement
        )
        defer { sqlite3_finalize(insertStatement) }

        while sqlite3_step(selectStatement) == SQLITE_ROW {
            guard let soundID = UUID(uuidString: columnText(selectStatement, 0)) else { continue }
            try insertSearchNGrams(
                soundID: soundID,
                content: columnText(selectStatement, 1),
                into: database,
                statement: insertStatement
            )
        }
        try ensureReadCompleted(selectStatement, database: database)
        try updateSearchNGramIndexState(soundCount: soundCount, in: database)
    }

    private func updateSearchNGramIndexState(soundCount: Int64, in database: OpaquePointer) throws {
        try executeUpdate(
            database,
            sql: """
                INSERT INTO sound_ngrams_state (id, sound_count) VALUES (1, ?)
                ON CONFLICT(id) DO UPDATE SET sound_count = excluded.sound_count
                """,
            bindings: [.integer(soundCount)]
        )
    }

    private func scalarInt64(
        in database: OpaquePointer,
        sql: String,
        defaultValue: Int64 = 0
    ) throws -> Int64 {
        var statement: OpaquePointer?
        try prepare(database, sql: sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return defaultValue }
        return sqlite3_column_int64(statement, 0)
    }

    private func loadRecoverySnapshot(from url: URL) throws -> LibraryRecoverySnapshot {
        let data = try Data(contentsOf: url)
        if let snapshot = try? Self.decoder.decode(LibraryRecoverySnapshot.self, from: data) {
            return snapshot
        }
        // Build 10–13 wrote a plain [SoundPack] recovery array. Keep that format readable so
        // upgrading never strands an existing local library or its original JSON backup.
        let packs = try Self.decoder.decode([SoundPack].self, from: data)
        return LibraryRecoverySnapshot(packs: packs)
    }

    private func loadJSON(from url: URL) throws -> [SoundPack] {
        try Self.decoder.decode([SoundPack].self, from: Data(contentsOf: url))
    }

    private func archiveUnreadableDatabase() throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let recoveryDirectory = databaseURL.deletingLastPathComponent()
            .appendingPathComponent("Recovery", isDirectory: true)
            .appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        try FileManager.default.createDirectory(
            at: recoveryDirectory,
            withIntermediateDirectories: true
        )
        for url in [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm")
        ] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.moveItem(
                at: url,
                to: recoveryDirectory.appendingPathComponent(url.lastPathComponent)
            )
        }
    }

    private func execute(_ database: OpaquePointer, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw LibraryPersistenceError.sqlite(message)
        }
    }

    private func ensureColumn(
        in database: OpaquePointer,
        table: String,
        name: String,
        definition: String
    ) throws {
        var statement: OpaquePointer?
        try prepare(
            database,
            sql: "SELECT 1 FROM pragma_table_info(?) WHERE name = ? LIMIT 1",
            statement: &statement
        )
        defer { sqlite3_finalize(statement) }
        bind(.text(table), to: 1, in: statement)
        bind(.text(name), to: 2, in: statement)
        let stepResult = sqlite3_step(statement)
        guard stepResult == SQLITE_ROW || stepResult == SQLITE_DONE else {
            throw LibraryPersistenceError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        let exists = stepResult == SQLITE_ROW
        guard !exists else { return }
        try execute(database, "ALTER TABLE \(table) ADD COLUMN \(name) \(definition)")
    }

    private func prepare(_ database: OpaquePointer, sql: String, statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw LibraryPersistenceError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func stepDone(_ statement: OpaquePointer?, database: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw LibraryPersistenceError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func ensureReadCompleted(_ statement: OpaquePointer?, database: OpaquePointer) throws {
        let result = sqlite3_errcode(database)
        guard result == SQLITE_OK || result == SQLITE_DONE else {
            throw LibraryPersistenceError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func bind(_ value: SQLiteBinding, to index: Int32, in statement: OpaquePointer?) {
        switch value {
        case .null:
            sqlite3_bind_null(statement, index)
        case let .text(value):
            sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
        case let .integer(value):
            sqlite3_bind_int64(statement, index, value)
        case let .double(value):
            sqlite3_bind_double(statement, index, value)
        case let .blob(value):
            _ = value.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
            }
        }
    }

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    private func columnOptionalText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return columnText(statement, index)
    }

    private func columnOptionalDouble(_ statement: OpaquePointer?, _ index: Int32) -> Double? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_double(statement, index)
    }

    private func columnOptionalInt(_ statement: OpaquePointer?, _ index: Int32) -> Int? {
        sqlite3_column_type(statement, index) == SQLITE_NULL
            ? nil
            : Int(sqlite3_column_int64(statement, index))
    }

    private func columnOptionalInt64(_ statement: OpaquePointer?, _ index: Int32) -> Int64? {
        sqlite3_column_type(statement, index) == SQLITE_NULL
            ? nil
            : sqlite3_column_int64(statement, index)
    }

    private func columnOptionalUInt64(_ statement: OpaquePointer?, _ index: Int32) -> UInt64? {
        sqlite3_column_type(statement, index) == SQLITE_NULL
            ? nil
            : UInt64(bitPattern: sqlite3_column_int64(statement, index))
    }

    private func columnData(_ statement: OpaquePointer?, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static let compactEncoder = JSONEncoder()
    private static let compactDecoder = JSONDecoder()
}

private enum SQLiteBinding {
    case null
    case text(String)
    case integer(Int64)
    case double(Double)
    case blob(Data)
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum LibraryPersistenceError: LocalizedError {
    case sqlite(String)
    case recoveryFailed(String)
    case invalidSnapshot(String)

    var errorDescription: String? {
        switch self {
        case let .sqlite(message): return "本地资料库错误：\(message)"
        case let .recoveryFailed(message): return "资料库恢复失败：\(message)"
        case let .invalidSnapshot(message): return "资料库备份无效：\(message)"
        }
    }
}
