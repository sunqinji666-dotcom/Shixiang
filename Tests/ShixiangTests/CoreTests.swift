import Foundation
import CryptoKit
import SQLite3
import Testing
@testable import Shixiang

struct CoreTests {
    @Test func localAISearchPlanDeduplicatesKeywordsAndDropsGenericNoise() {
        let plan = LocalAISearchPlan(keywords: [
            "科技上升", "科技上升", "  克制  ", "sound", "effects", "audio", ""
        ])

        #expect(plan.keywords == ["科技上升", "克制"])
        #expect(plan.expandedQuery(originalQuery: "三秒以内") == "三秒以内 科技上升 克制")
    }

    @Test func localAILeavesVeryShortQueriesToTheLocalSemanticIndex() async throws {
        let plan = try await LocalAISearchPlanner.plan(for: "风")
        #expect(plan.keywords == ["wind", "breeze", "gust"])
        #expect(plan.expandedQuery(originalQuery: "风") == "风 wind breeze gust")

        let traditional = try await LocalAISearchPlanner.plan(for: "古风")
        #expect(traditional.keywords.contains("古筝"))
        #expect(traditional.keywords.contains("古琴"))
    }

    @Test func signedLicenseVerifiesAndTamperingFails() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let issuedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let claims = ShixiangLicenseClaims(
            schemaVersion: ShixiangLicenseClaims.currentSchemaVersion,
            productIdentifier: ShixiangLicenseVerifier.productIdentifier,
            licenseID: "test-license",
            edition: .creator,
            issuedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(86_400)
        )
        let token = try makeLicenseToken(claims: claims, privateKey: privateKey)
        let verifier = ShixiangLicenseVerifier(
            publicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString()
        )

        #expect(verifier.verify(token: token, now: issuedAt).status == .active)
        #expect(verifier.verify(token: token + "x", now: issuedAt).status == .invalidSignature)
    }

    @Test func signedLicenseRejectsWrongProductAndExpiredClaims() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let wrongProduct = ShixiangLicenseClaims(
            schemaVersion: ShixiangLicenseClaims.currentSchemaVersion,
            productIdentifier: "com.example.other",
            licenseID: "wrong-product",
            edition: .studio,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(86_400)
        )
        let expired = ShixiangLicenseClaims(
            schemaVersion: ShixiangLicenseClaims.currentSchemaVersion,
            productIdentifier: ShixiangLicenseVerifier.productIdentifier,
            licenseID: "expired",
            edition: .creator,
            issuedAt: now.addingTimeInterval(-86_400),
            expiresAt: now.addingTimeInterval(-1)
        )
        let verifier = ShixiangLicenseVerifier(
            publicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString()
        )

        #expect(verifier.verify(token: try makeLicenseToken(claims: wrongProduct, privateKey: privateKey), now: now).status == .wrongProduct)
        #expect(verifier.verify(token: try makeLicenseToken(claims: expired, privateKey: privateKey), now: now).status == .expired)
    }

    @Test @MainActor func unconfiguredLicenseKeepsLocalBuildUnlocked() {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shixiang-license-\(UUID().uuidString).token")
        let store = ShixiangLicenseStore(
            verifier: ShixiangLicenseVerifier(publicKeyBase64: nil),
            storageURL: storageURL
        )

        #expect(store.status == .localEdition)
        #expect(!FileManager.default.fileExists(atPath: storageURL.path))
    }

    @Test @MainActor func invalidatingSemanticOperationClearsStaleSearchPresentation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shixiang-semantic-invalidation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let persistence = LibraryPersistence(baseDirectory: directory)
        try persistence.save([])
        let store = LibraryStore(persistence: persistence)

        let oldToken = store.invalidateSemanticOperation()
        let oldSearch = Task {
            await store.indexedSoundMatches(
                matching: "雨夜",
                mode: .hybrid,
                operationToken: oldToken
            )
        }
        store.invalidateSemanticOperation()
        _ = await oldSearch.value

        #expect(store.semanticIndexProgress == nil)
        #expect(store.lastSemanticSearchMatchCount == 0)
        #expect(store.lastSemanticConceptTitles.isEmpty)
    }

    @Test func updateManifestReportsNewBuildAndRejectsInsecureURLs() throws {
        let manifest = ShixiangUpdateManifest(
            schemaVersion: ShixiangUpdateManifest.currentSchemaVersion,
            productIdentifier: ShixiangUpdateChecker.productIdentifier,
            version: "0.5.1",
            build: 99,
            downloadURL: "https://downloads.example.com/shixiang.dmg",
            sha256: String(repeating: "a", count: 64),
            minimumSystemVersion: "14.0",
            releaseNotes: "性能改进"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        #expect(ShixiangUpdateChecker.evaluate(manifestData: data, currentBuild: 50).status == .available)

        let insecure = ShixiangUpdateManifest(
            schemaVersion: manifest.schemaVersion,
            productIdentifier: manifest.productIdentifier,
            version: manifest.version,
            build: manifest.build,
            downloadURL: "http://downloads.example.com/shixiang.dmg",
            sha256: manifest.sha256,
            minimumSystemVersion: manifest.minimumSystemVersion,
            releaseNotes: manifest.releaseNotes
        )
        #expect(ShixiangUpdateChecker.evaluate(manifestData: try encoder.encode(insecure), currentBuild: 50).status == .invalidManifest)
    }

    private func makeLicenseToken(
        claims: ShixiangLicenseClaims,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(claims)
        let signature = try privateKey.signature(for: payload)
        return "shixiang-v1.\(payload.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")).\(signature.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""))"
    }

    @Test func supportDiagnosticsReportIsAnonymousAndStableJSON() throws {
        let generatedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let report = SupportDiagnosticsReport.make(
            appVersion: "0.5.0",
            build: "48",
            soundPackCount: 2,
            soundCount: 123,
            savedCollectionCount: 4,
            analyzedSoundCount: 17,
            operatingSystem: "macOS 14.6",
            architecture: "Apple silicon",
            generatedAt: generatedAt
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SupportDiagnosticsReport.self, from: report.jsonData)
        #expect(decoded == report)
        #expect(decoded.hasIndexedLibrary)
        let jsonText = String(decoding: decoded.jsonData, as: UTF8.self)
        #expect(jsonText.contains("privacyNotice"))
        #expect(!jsonText.contains("/Users/"))
        #expect(decoded.privacyNotice.contains("不包含原始音频"))
    }

    @Test func relativePathRejectsSiblingsWithCommonPrefix() {
        let root = URL(fileURLWithPath: "/tmp/SoundPack", isDirectory: true)
        let inside = URL(fileURLWithPath: "/tmp/SoundPack/Foley/door.wav")
        let sibling = URL(fileURLWithPath: "/tmp/SoundPack Extra/door.wav")

        #expect(LibraryScanner.relativePath(for: inside, under: root) == "Foley/door.wav")
        #expect(LibraryScanner.relativePath(for: sibling, under: root) == nil)
        #expect(LibraryScanner.folderPath(forRelativePath: "Foley/door.wav") == "Foley")
        #expect(LibraryScanner.folderPath(forRelativePath: "door.wav") == "")
    }

    @Test func supportedAudioExtensionsAreCaseInsensitive() {
        #expect(LibraryScanner.isSupportedAudioFile(URL(fileURLWithPath: "/tmp/a.WAV")))
        #expect(LibraryScanner.isSupportedAudioFile(URL(fileURLWithPath: "/tmp/a.flac")))
        #expect(!LibraryScanner.isSupportedAudioFile(URL(fileURLWithPath: "/tmp/notes.txt")))
    }

    @Test func scannerEnumerationFailureExplainsTheAffectedFolder() {
        let root = URL(fileURLWithPath: "/tmp/权限受限音效包", isDirectory: true)
        let error = LibraryScannerError.enumerationFailed(root, "没有访问权限")
        #expect(error.localizedDescription.contains("权限受限音效包"))
        #expect(error.localizedDescription.contains("没有访问权限"))
    }

    @Test func scannerReportsBoundedProgressForLargeImports() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["one.wav", "two.wav", "three.wav"] {
            try Data([0x01, 0x02, 0x03]).write(to: root.appendingPathComponent(name))
        }

        let recorder = ProgressRecorder()
        let scanner = LibraryScanner()
        let result = try await scanner.scanResult(
            rootURL: root,
            packageID: UUID(),
            progress: { completed, total in
                recorder.append(completed: completed, total: total)
            }
        )

        let capturedUpdates = recorder.snapshot()

        #expect(result.items.count == 3)
        #expect(capturedUpdates.first?.0 == 0)
        #expect(capturedUpdates.last?.0 == 3)
        #expect(capturedUpdates.allSatisfy { $0.1 == 3 })
        #expect(capturedUpdates.count <= 5)

        let reuseRecorder = ProgressRecorder()
        let reused = try await scanner.scanResult(
            rootURL: root,
            packageID: result.packageID,
            existingItems: result.items,
            progress: { completed, total in
                reuseRecorder.append(completed: completed, total: total)
            }
        )
        #expect(reused.items == result.items)
        #expect(reused.statistics.reusedCount == 3)
        #expect(reused.statistics.analyzedCount == 0)
        #expect(reuseRecorder.snapshot().map(\.0) == [0, 3])

        let rebuilt = try await scanner.scanResult(
            rootURL: root,
            packageID: result.packageID,
            existingItems: result.items,
            forceAudioMetadataRefresh: true
        )
        #expect(rebuilt.items.map(\.id) == result.items.map(\.id))
        #expect(rebuilt.statistics.reusedCount == 0)
        #expect(rebuilt.statistics.analyzedCount == 3)
    }

    @Test func folderTreePreservesHierarchyAndCountsDescendants() {
        let packID = UUID()
        let items = [
            makeItem(packID: packID, path: "Foley/Doors/open.wav"),
            makeItem(packID: packID, path: "Foley/Doors/close.wav"),
            makeItem(packID: packID, path: "Foley/Steps/walk.wav"),
            makeItem(packID: packID, path: "Music/theme.mp3")
        ]

        let nodes = FolderNode.make(from: items)
        #expect(nodes.map(\.name) == ["Foley", "Music"])
        #expect(nodes[0].itemCount == 3)
        #expect(nodes[0].children.map(\.name) == ["Doors", "Steps"])
        #expect(nodes[0].children[0].itemCount == 2)
    }

    @Test func scannerPreservesMetadataWhenAUniqueSourceIsRenamed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let oldURL = root.appendingPathComponent("old-name.wav")
        let bytes = Data(repeating: 0x4A, count: 256)
        try bytes.write(to: oldURL)
        let modificationDate = Date(timeIntervalSince1970: 1_750_000_400)
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDate],
            ofItemAtPath: oldURL.path
        )

        let scanner = LibraryScanner()
        let packID = UUID()
        let initial = try await scanner.scan(rootURL: root, packageID: packID)
        #expect(initial.count == 1)

        var decorated = try #require(initial.first)
        decorated.isFavorite = true
        decorated.customName = "门外旧声"
        decorated.tags = ["拟音", "门"]

        let newFolder = root.appendingPathComponent("新目录", isDirectory: true)
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        let newURL = newFolder.appendingPathComponent("new-name.wav")
        try FileManager.default.moveItem(at: oldURL, to: newURL)
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDate],
            ofItemAtPath: newURL.path
        )

        let rescanned = try await scanner.scan(
            rootURL: root,
            packageID: packID,
            existingItems: [decorated]
        )
        let moved = try #require(rescanned.first)
        #expect(moved.relativePath == "新目录/new-name.wav")
        #expect(moved.id == decorated.id)
        #expect(moved.isFavorite)
        #expect(moved.customName == "门外旧声")
        #expect(moved.tags == ["拟音", "门"])
    }

    @Test func detailedScanReportsAPathMigrationWithoutChangingTheSource() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let oldURL = root.appendingPathComponent("old-name.wav")
        try Data(repeating: 0x4A, count: 256).write(to: oldURL)
        let modificationDate = Date(timeIntervalSince1970: 1_750_000_400)
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDate],
            ofItemAtPath: oldURL.path
        )

        let scanner = LibraryScanner()
        let packID = UUID()
        let initial = try await scanner.scanResult(rootURL: root, packageID: packID)
        let previous = try #require(initial.items.first)

        let folder = root.appendingPathComponent("新目录", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let newURL = folder.appendingPathComponent("new-name.wav")
        try FileManager.default.moveItem(at: oldURL, to: newURL)
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDate],
            ofItemAtPath: newURL.path
        )

        let result = try await scanner.scanResult(
            rootURL: root,
            packageID: packID,
            existingItems: [previous]
        )
        let migration = try #require(result.migrations.first)
        #expect(result.migrations.count == 1)
        #expect(migration.soundID == previous.id)
        #expect(migration.packageID == packID)
        #expect(migration.fromRelativePath == "old-name.wav")
        #expect(migration.toRelativePath == "新目录/new-name.wav")
        #expect(migration.kind == .renameAndMove)
        #expect(result.items.first?.id == previous.id)
        #expect(result.items.first?.relativePath == "新目录/new-name.wav")
    }

    @Test func explicitRecoverySnapshotExportContainsOnlyIndexData() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixedDate = Date(timeIntervalSince1970: 1_750_000_000)
        let pack = SoundPack(
            name: "电影诗意",
            rootPath: "/Volumes/Sounds/电影诗意",
            importedAt: fixedDate,
            lastScannedAt: fixedDate,
            items: [
                SoundItem(
                    packageID: UUID(),
                    relativePath: "转场/风.wav",
                    fileName: "风.wav",
                    folderPath: "转场",
                    fileExtension: "wav",
                    duration: 1.2,
                    sampleRate: 48_000,
                    channelCount: 2
                )
            ]
        )
        let snapshot = LibraryRecoverySnapshot(
            packs: [pack],
            savedCollections: [SavedCollection(name: "我的风声", createdAt: fixedDate)]
        )
        let output = directory.appendingPathComponent("backup.json")
        try LibraryPersistence(baseDirectory: directory).exportSnapshot(snapshot, to: output)

        let data = try Data(contentsOf: output)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let roundTrip = try decoder.decode(LibraryRecoverySnapshot.self, from: data)
        #expect(roundTrip == snapshot)
        #expect(String(decoding: data, as: UTF8.self).contains("\\/Volumes\\/Sounds\\/电影诗意"))
        #expect(!String(decoding: data, as: UTF8.self).contains("RIFF"))
    }

    @Test func recoverySnapshotImportValidatesAndRoundTripsExportedData() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixedDate = Date(timeIntervalSince1970: 1_750_000_000)
        let packID = UUID()
        let snapshot = LibraryRecoverySnapshot(
            packs: [
                SoundPack(
                    id: packID,
                    name: "现场录音",
                    rootPath: "/Volumes/现场录音",
                    importedAt: fixedDate,
                    lastScannedAt: fixedDate,
                    items: [
                        SoundItem(
                            packageID: packID,
                            relativePath: "雨/屋檐.wav",
                            fileName: "屋檐.wav",
                            folderPath: "雨",
                            fileExtension: "wav"
                        )
                    ]
                )
            ],
            savedCollections: [SavedCollection(name: "屋檐雨声", createdAt: fixedDate)]
        )
        let persistence = LibraryPersistence(baseDirectory: directory)
        let output = directory.appendingPathComponent("round-trip.json")
        try persistence.exportSnapshot(snapshot, to: output)
        #expect(try persistence.importSnapshot(from: output) == snapshot)

        let malformed = directory.appendingPathComponent("malformed.json")
        try Data("not a shixiang backup".utf8).write(to: malformed)
        #expect(throws: LibraryPersistenceError.self) {
            try persistence.importSnapshot(from: malformed)
        }
    }

    @Test func persistenceRejectsUnsafeRelativePathsAndImpossibleMetadata() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shixiang-invalid-snapshot-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let packID = UUID()
        let item = SoundItem(
            packageID: packID,
            relativePath: "../outside.wav",
            fileName: "outside.wav",
            folderPath: "..",
            fileExtension: "wav",
            duration: 1
        )
        let snapshot = LibraryRecoverySnapshot(
            packs: [SoundPack(id: packID, name: "不可信", rootPath: "/tmp/pack", items: [item])]
        )
        let persistence = LibraryPersistence(baseDirectory: directory)
        let output = directory.appendingPathComponent("unsafe.json")
        try persistence.exportSnapshot(snapshot, to: output)

        #expect(throws: LibraryPersistenceError.self) {
            try persistence.importSnapshot(from: output)
        }
    }

    @Test func scannerPrioritizesAnExistingPathOverADuplicateFingerprint() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let originalURL = root.appendingPathComponent("original.wav")
        let duplicateURL = root.appendingPathComponent("duplicate.wav")
        let bytes = Data(repeating: 0x2B, count: 512)
        try bytes.write(to: originalURL)
        let modificationDate = Date(timeIntervalSince1970: 1_750_000_600)
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDate],
            ofItemAtPath: originalURL.path
        )

        let scanner = LibraryScanner()
        let packID = UUID()
        var initial = try await scanner.scan(rootURL: root, packageID: packID)
        var decorated = try #require(initial.first)
        decorated.isFavorite = true
        decorated.customName = "原始冲击"
        decorated.tags = ["冲击"]

        try bytes.write(to: duplicateURL)
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDate],
            ofItemAtPath: duplicateURL.path
        )

        initial = try await scanner.scan(
            rootURL: root,
            packageID: packID,
            existingItems: [decorated]
        )
        let original = try #require(initial.first { $0.relativePath == "original.wav" })
        let duplicate = try #require(initial.first { $0.relativePath == "duplicate.wav" })
        #expect(original.id == decorated.id)
        #expect(original.customName == "原始冲击")
        #expect(original.isFavorite)
        #expect(duplicate.id != decorated.id)
        #expect(duplicate.customName == nil)
    }

    @Test func scannerDoesNotGuessWhenTwoRenamedCandidatesShareAFingerprint() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let oldURL = root.appendingPathComponent("old.wav")
        let bytes = Data(repeating: 0x6C, count: 640)
        try bytes.write(to: oldURL)
        let modificationDate = Date(timeIntervalSince1970: 1_750_000_700)
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDate],
            ofItemAtPath: oldURL.path
        )

        let scanner = LibraryScanner()
        let packID = UUID()
        let initial = try await scanner.scan(rootURL: root, packageID: packID)
        let decorated = try #require(initial.first)

        let firstURL = root.appendingPathComponent("first.wav")
        let secondURL = root.appendingPathComponent("second.wav")
        try FileManager.default.moveItem(at: oldURL, to: firstURL)
        try bytes.write(to: secondURL)
        for url in [firstURL, secondURL] {
            try FileManager.default.setAttributes(
                [.modificationDate: modificationDate],
                ofItemAtPath: url.path
            )
        }

        let rescanned = try await scanner.scan(
            rootURL: root,
            packageID: packID,
            existingItems: [decorated]
        )
        #expect(rescanned.count == 2)
        #expect(rescanned.allSatisfy { $0.id != decorated.id })
    }

    @Test func scannerPreservesTheUnclaimedTwinWhenOnlyOneDuplicateMoves() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstURL = root.appendingPathComponent("first.wav")
        let secondURL = root.appendingPathComponent("second.wav")
        let sourceBytes = Data(repeating: 0x5D, count: 768)
        let modificationDate = Date(timeIntervalSince1970: 1_750_000_800)
        for url in [firstURL, secondURL] {
            try sourceBytes.write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: modificationDate],
                ofItemAtPath: url.path
            )
        }

        let scanner = LibraryScanner()
        let packID = UUID()
        var initial = try await scanner.scan(rootURL: root, packageID: packID)
        let firstIndex = try #require(initial.firstIndex { $0.relativePath == "first.wav" })
        let secondIndex = try #require(initial.firstIndex { $0.relativePath == "second.wav" })
        initial[firstIndex].customName = "留在原位"
        initial[secondIndex].customName = "移动的副本"
        let firstID = initial[firstIndex].id
        let secondID = initial[secondIndex].id

        let movedURL = root.appendingPathComponent("moved.wav")
        try FileManager.default.moveItem(at: secondURL, to: movedURL)
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDate],
            ofItemAtPath: movedURL.path
        )

        let result = try await scanner.scanResult(
            rootURL: root,
            packageID: packID,
            existingItems: initial
        )
        let stationary = try #require(result.items.first { $0.relativePath == "first.wav" })
        let moved = try #require(result.items.first { $0.relativePath == "moved.wav" })

        #expect(stationary.id == firstID)
        #expect(stationary.customName == "留在原位")
        #expect(moved.id == secondID)
        #expect(moved.customName == "移动的副本")
        #expect(result.migrations.count == 1)
        #expect(result.migrations.first?.soundID == secondID)
        #expect((try? Data(contentsOf: firstURL)) == sourceBytes)
        #expect((try? Data(contentsOf: movedURL)) == sourceBytes)
    }

    @Test func persistenceRoundTripPreservesOriginalPathsAndFavorite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let persistence = LibraryPersistence(baseDirectory: directory)
        let packID = UUID()
        var favorite = SoundItem(
            packageID: packID,
            relativePath: "环境声/雨夜.aiff",
            fileName: "雨夜.aiff",
            folderPath: "环境声",
            fileExtension: "aiff",
            sourceFileSize: 4_096,
            sourceModificationDate: Date(timeIntervalSince1970: 1_750_000_500),
            sourceContentSignature: 0x1234
        )
        favorite.isFavorite = true
        let expected = SoundPack(
            id: packID,
            name: "电影音效包",
            rootPath: "/Volumes/素材/电影音效包",
            items: [favorite]
        )

        try persistence.save([expected])
        let loaded = try persistence.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == expected.id)
        #expect(loaded.first?.rootPath == expected.rootPath)
        #expect(loaded.first?.items.first?.relativePath == "环境声/雨夜.aiff")
        #expect(loaded.first?.items.first?.isFavorite == true)
        #expect(loaded.first?.items.first?.sourceFileSize == 4_096)
        #expect(loaded.first?.items.first?.sourceModificationDate == Date(timeIntervalSince1970: 1_750_000_500))
        #expect(loaded.first?.items.first?.sourceContentSignature == 0x1234)
        #expect(FileManager.default.fileExists(atPath: persistence.databaseURL.path))
        #expect(FileManager.default.fileExists(atPath: persistence.backupURL.path))
    }

    @Test func sqliteMetadataUpdatesAreTargetedAndSurviveReload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = LibraryPersistence(baseDirectory: directory)
        let packID = UUID()
        var item = makeItem(packID: packID, path: "转场/whoosh.wav")
        item.isFavorite = false
        try persistence.save([
            SoundPack(id: packID, name: "剪辑音效", rootPath: directory.path, items: [item])
        ])

        try persistence.updateFavorite(soundID: item.id, isFavorite: true)
        try persistence.updateMetadata(
            soundID: item.id,
            customName: "银色呼啸转场",
            tags: ["转场", "电影", "转场"]
        )

        let loaded = try persistence.load().first?.items.first
        #expect(loaded?.isFavorite == true)
        #expect(loaded?.customName == "银色呼啸转场")
        #expect(loaded?.tags == ["转场", "电影"])
        #expect(loaded?.fileName == "whoosh.wav")
    }

    @Test func replacingOnePackRefreshesOnlyItsSearchRowsAndKeepsOtherPacksSearchable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = LibraryPersistence(baseDirectory: directory)
        let firstPackID = UUID()
        let secondPackID = UUID()
        let oldFirst = makeItem(packID: firstPackID, path: "转场/银色呼啸.wav")
        let second = makeItem(packID: secondPackID, path: "环境/雨夜远处汽车.wav")
        try persistence.save([
            SoundPack(id: firstPackID, name: "转场包", rootPath: directory.path, items: [oldFirst]),
            SoundPack(id: secondPackID, name: "环境包", rootPath: directory.path, items: [second])
        ])

        let replacement = makeItem(packID: firstPackID, path: "转场/紫色回吸.wav")
        try persistence.replacePack(
            SoundPack(id: firstPackID, name: "转场包", rootPath: directory.path, items: [replacement])
        )

        #expect(try persistence.searchSoundIDs(matching: "银色").contains(oldFirst.id) == false)
        #expect(try persistence.searchSoundIDs(matching: "紫色").contains(replacement.id))
        #expect(try persistence.searchSoundIDs(matching: "雨夜").contains(second.id))
        let loaded = try persistence.load()
        #expect(loaded.first(where: { $0.id == firstPackID })?.items.map(\.id) == [replacement.id])
        #expect(loaded.first(where: { $0.id == secondPackID })?.items.map(\.id) == [second.id])
    }

    @Test func savedCollectionsRoundTripInSQLite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = LibraryPersistence(baseDirectory: directory)
        try persistence.save([])

        let collection = SavedCollection(
            name: "我的短呼啸",
            scope: .smartDetail(.transitionWhoosh),
            query: "银色",
            fileExtension: "wav",
            minimumDuration: 0,
            maximumDuration: 5,
            favoritesOnly: true
        )
        try persistence.saveSavedCollection(collection)
        let loaded = try persistence.loadSavedCollections()
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == collection.id)
        #expect(loaded.first?.name == collection.name)
        #expect(loaded.first?.scope == collection.scope)
        #expect(loaded.first?.query == collection.query)
        #expect(loaded.first?.fileExtension == collection.fileExtension)
        #expect(loaded.first?.minimumDuration == collection.minimumDuration)
        #expect(loaded.first?.maximumDuration == collection.maximumDuration)
        #expect(loaded.first?.favoritesOnly == collection.favoritesOnly)

        try persistence.deleteSavedCollection(id: collection.id)
        #expect(try persistence.loadSavedCollections().isEmpty)
    }

    @Test func savedCollectionsPreservePackAndFolderScopes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = LibraryPersistence(baseDirectory: directory)
        try persistence.save([])

        let packID = UUID()
        let packCollection = SavedCollection(name: "整包声音", scope: .pack(packID))
        let folderCollection = SavedCollection(
            name: "夜晚环境",
            scope: .folder(packID: packID, path: "环境/城市/夜晚")
        )
        let recentCollection = SavedCollection(name: "最近导入", scope: .recent)

        try persistence.saveSavedCollection(packCollection)
        try persistence.saveSavedCollection(folderCollection)
        try persistence.saveSavedCollection(recentCollection)

        let loaded = try persistence.loadSavedCollections()
        #expect(loaded.contains { $0.scope == .pack(packID) })
        #expect(loaded.contains {
            $0.scope == .folder(packID: packID, path: "环境/城市/夜晚")
        })
        #expect(loaded.contains { $0.scope == .recent })
    }

    @Test @MainActor func savedCollectionManagementRenamesDeletesAndMarksStaleScopes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let persistence = LibraryPersistence(baseDirectory: directory)
        let packID = UUID()
        let pack = SoundPack(
            id: packID,
            name: "集合测试包",
            rootPath: directory.path,
            items: [makeItem(packID: packID, path: "环境/雨.wav")]
        )
        let packCollection = SavedCollection(name: "旧名称", scope: .pack(packID))
        try persistence.save([pack])
        try persistence.saveSavedCollection(packCollection)

        let store = LibraryStore(persistence: persistence)
        let folderCollection = SavedCollection(
            name: "环境集合",
            scope: .folder(packID: packID, path: "环境")
        )
        let missingPackCollection = SavedCollection(
            name: "失效包",
            scope: .pack(UUID())
        )
        let missingFolderCollection = SavedCollection(
            name: "失效文件夹",
            scope: .folder(packID: packID, path: "不存在")
        )

        #expect(store.savedCollectionAvailability(packCollection) == .available)
        #expect(store.savedCollectionAvailability(folderCollection) == .available)
        #expect(store.savedCollectionAvailability(missingPackCollection) == .missingPack)
        #expect(store.savedCollectionAvailability(missingFolderCollection) == .missingFolder)

        #expect(store.renameSavedCollection(packCollection, to: "  新名称  "))
        #expect(store.savedCollections.first?.id == packCollection.id)
        #expect(store.savedCollections.first?.name == "新名称")
        #expect(!store.renameSavedCollection(packCollection, to: "   "))
        #expect(store.alertMessage == "集合名称不能为空。")

        store.removeSavedCollection(packCollection)
        #expect(store.savedCollections.isEmpty)
        await Task.yield()
    }

    @Test func audioIntelligenceRoundTripsInSQLite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = LibraryPersistence(baseDirectory: directory)
        try persistence.save([])

        let soundID = UUID()
        let analyzedAt = Date(timeIntervalSince1970: 1_750_000_123)
        let expected = AudioIntelligence(
            bpm: 128.4,
            bpmConfidence: 0.82,
            loudnessLUFS: -14.7,
            musicalKey: MusicalKey(root: .a, mode: .minor),
            keyConfidence: 0.76,
            analyzedAt: analyzedAt
        )
        try persistence.saveAudioIntelligence(soundID: soundID, intelligence: expected)
        let loaded = try persistence.loadAudioIntelligence()[soundID]

        #expect(loaded?.bpm == expected.bpm)
        #expect(loaded?.bpmConfidence == expected.bpmConfidence)
        #expect(loaded?.loudnessLUFS == expected.loudnessLUFS)
        #expect(loaded?.musicalKey == expected.musicalKey)
        #expect(loaded?.keyConfidence == expected.keyConfidence)
        #expect(loaded?.analyzedAt == expected.analyzedAt)
    }

    @Test func acousticFingerprintDistinguishesTimbreAndRoundTripsInSQLite() throws {
        let sampleRate = 48_000.0
        let count = 48_000
        let sineA = (0..<count).map { index in
            Float(sin(2 * Double.pi * 440 * Double(index) / sampleRate) * 0.6)
        }
        let sineB = (0..<count).map { index in
            Float(sin(2 * Double.pi * 442 * Double(index) / sampleRate + 0.2) * 0.35)
        }
        var state: UInt64 = 0x4A41_434B_5355_4E01
        let noise = (0..<count).map { _ -> Float in
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Float(Double((state >> 32) & 0xFFFF) / 32_767.5 - 1) * 0.35
        }
        let first = try #require(AcousticFingerprintAnalyzer.analyze(samples: sineA, sampleRate: sampleRate))
        let near = try #require(AcousticFingerprintAnalyzer.analyze(samples: sineB, sampleRate: sampleRate))
        let different = try #require(AcousticFingerprintAnalyzer.analyze(samples: noise, sampleRate: sampleRate))
        #expect(first.similarity(to: near) > first.similarity(to: different) + 0.15)

        let sourceID = UUID()
        let nearID = UUID()
        let differentID = UUID()
        func intelligence(_ fingerprint: AcousticFingerprint) -> AudioIntelligence {
            AudioIntelligence(
                bpm: nil,
                bpmConfidence: 0,
                loudnessLUFS: nil,
                musicalKey: nil,
                keyConfidence: 0,
                acousticFingerprint: fingerprint,
                analyzedAt: Date()
            )
        }
        let nearest = AcousticSimilarityIndex.nearest(
            to: first,
            sourceID: sourceID,
            in: [
                sourceID: intelligence(first),
                nearID: intelligence(near),
                differentID: intelligence(different)
            ],
            minimumSimilarity: 0
        )
        #expect(nearest.first?.soundID == nearID)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = LibraryPersistence(baseDirectory: directory)
        try persistence.save([])
        let soundID = UUID()
        let intelligence = AudioIntelligence(
            bpm: nil,
            bpmConfidence: 0,
            loudnessLUFS: -12,
            musicalKey: nil,
            keyConfidence: 0,
            acousticFingerprint: first,
            analyzedAt: Date(timeIntervalSince1970: 1_760_000_000)
        )
        try persistence.saveAudioIntelligence(soundID: soundID, intelligence: intelligence)
        #expect(try persistence.loadAudioIntelligence()[soundID] == intelligence)
    }

    @Test @MainActor func acousticCoverageCountLoadsOnceAndSupportsScopedResults() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = LibraryPersistence(baseDirectory: directory)
        let packID = UUID()
        let indexed = makeItem(packID: packID, path: "Transitions/Indexed.wav")
        let pending = makeItem(packID: packID, path: "Transitions/Pending.wav")
        try persistence.save([
            SoundPack(
                id: packID,
                name: "覆盖率",
                rootPath: directory.path,
                items: [indexed, pending]
            )
        ])
        let fingerprint = AcousticFingerprint(
            spectralBands: Array(repeating: 0.08, count: 12),
            spectralCentroid: 0.4,
            spectralRolloff: 0.6,
            spectralFlatness: 0.2,
            zeroCrossingRate: 0.1,
            crestFactor: 0.5,
            transientDensity: 0.3,
            dynamicRange: 0.4,
            analyzedDuration: 1
        )
        try persistence.saveAudioIntelligence(
            soundID: indexed.id,
            intelligence: AudioIntelligence(
                bpm: nil,
                bpmConfidence: 0,
                loudnessLUFS: nil,
                musicalKey: nil,
                keyConfidence: 0,
                acousticFingerprint: fingerprint,
                analyzedAt: Date()
            )
        )

        let store = LibraryStore(persistence: persistence)
        #expect(store.acousticFingerprintCount == 1)
        #expect(await store.acousticFingerprintCount(in: [indexed, pending]) == 1)
        #expect(await store.acousticFingerprintCount(in: [pending]) == 0)
    }

    @Test func acousticAnalysisQueueSkipsHiddenAndIndexedSoundsAcrossPacks() throws {
        let packID = UUID()
        let pending = makeItem(packID: packID, path: "Transitions/Pending.wav")
        var hidden = makeItem(packID: packID, path: "Transitions/Hidden.wav")
        hidden.isHidden = true
        let indexed = makeItem(packID: packID, path: "Transitions/Indexed.wav")
        let fingerprint = AcousticFingerprint(
            spectralBands: Array(repeating: 0.08, count: 12),
            spectralCentroid: 0.4,
            spectralRolloff: 0.6,
            spectralFlatness: 0.2,
            zeroCrossingRate: 0.1,
            crestFactor: 0.5,
            transientDensity: 0.3,
            dynamicRange: 0.4,
            analyzedDuration: 1
        )
        let intelligence = AudioIntelligence(
            bpm: nil,
            bpmConfidence: 0,
            loudnessLUFS: nil,
            musicalKey: nil,
            keyConfidence: 0,
            acousticFingerprint: fingerprint,
            analyzedAt: Date()
        )
        let pack = SoundPack(
            id: packID,
            name: "声音理解队列",
            rootPath: "/tmp/声音理解队列",
            items: [pending, hidden, indexed]
        )

        let fromPacks = try AcousticAnalysisQueueBuilder.candidates(
            in: [pack],
            intelligenceByID: [indexed.id: intelligence]
        )
        let fromItems = try AcousticAnalysisQueueBuilder.candidates(
            in: pack.items,
            intelligenceByID: [indexed.id: intelligence]
        )
        #expect(fromPacks.map(\.id) == [pending.id])
        #expect(fromItems.map(\.id) == [pending.id])
    }

    @Test func acousticAnalysisQueueBuildsCreatorScaleLibraryWithinOneSecond() throws {
        let packID = UUID()
        let fingerprint = AcousticFingerprint(
            spectralBands: Array(repeating: 0.08, count: 12),
            spectralCentroid: 0.4,
            spectralRolloff: 0.6,
            spectralFlatness: 0.2,
            zeroCrossingRate: 0.1,
            crestFactor: 0.5,
            transientDensity: 0.3,
            dynamicRange: 0.4,
            analyzedDuration: 1
        )
        let intelligence = AudioIntelligence(
            bpm: nil,
            bpmConfidence: 0,
            loudnessLUFS: nil,
            musicalKey: nil,
            keyConfidence: 0,
            acousticFingerprint: fingerprint,
            analyzedAt: Date()
        )
        var items: [SoundItem] = []
        var intelligenceByID: [UUID: AudioIntelligence] = [:]
        items.reserveCapacity(31_259)
        intelligenceByID.reserveCapacity(6_252)
        var expectedCount = 0
        for index in 0..<31_259 {
            var item = makeItem(
                packID: packID,
                path: "规模测试/声音-\(index).wav"
            )
            item.isHidden = index.isMultiple(of: 7)
            if index.isMultiple(of: 5) {
                intelligenceByID[item.id] = intelligence
            } else if !item.isHidden {
                expectedCount += 1
            }
            items.append(item)
        }
        let pack = SoundPack(
            id: packID,
            name: "31,259 条规模测试",
            rootPath: "/tmp/31,259 条规模测试",
            items: items
        )

        let clock = ContinuousClock()
        let start = clock.now
        let candidates = try AcousticAnalysisQueueBuilder.candidates(
            in: [pack],
            intelligenceByID: intelligenceByID
        )
        let elapsed = start.duration(to: clock.now)

        #expect(candidates.count == expectedCount)
        #expect(elapsed < .seconds(1))
    }

    @Test func soundResultIndexBuildsCreatorScaleMappingWithinOneSecond() throws {
        let packID = UUID()
        var items: [SoundItem] = []
        items.reserveCapacity(31_259)
        for index in 0..<31_259 {
            items.append(makeItem(packID: packID, path: "结果索引/声音-\(index).wav"))
        }

        let clock = ContinuousClock()
        let start = clock.now
        let indexByID = try SoundResultIndexBuilder.make(for: items)
        let elapsed = start.duration(to: clock.now)

        #expect(indexByID.count == items.count)
        #expect(indexByID[items[0].id] == 0)
        #expect(indexByID[items[15_629].id] == 15_629)
        #expect(indexByID[items[31_258].id] == 31_258)
        #expect(elapsed < .seconds(1))
    }

    @Test func creatorSearchUnderstandsShotMoodAndExplicitDuration() {
        let query = SoundSemanticEngine.query("推进镜头，紧张一点，两秒以内")
        #expect(query.concepts["detail:\(SmartSubcollection.transitionRiser.rawValue)"] != nil)
        #expect(query.concepts["q:tense"] != nil)
        #expect(query.creatorIntent.maximumDuration == 2)
        #expect(query.creatorIntent.minimumDuration == nil)
        #expect(query.conceptTitles.contains("推进 / 揭晓"))
        #expect(query.conceptTitles.contains("紧张"))
        #expect(query.conceptTitles.contains("≤ 2 秒"))

        let range = SoundSemanticEngine.query("找 2 到 5 秒的产品结尾落版")
        #expect(range.creatorIntent.minimumDuration == 2)
        #expect(range.creatorIntent.maximumDuration == 5)
        #expect(range.concepts["detail:\(SmartSubcollection.musicStinger.rawValue)"] != nil)
    }

    @Test func jacksunNamingProfilePersonalizesAndNumbersConflicts() throws {
        let profile = JacksunNamingProfile(
            entries: [.init(sourceTerm: "braam", preferredName: "深渊号角")],
            namePrefix: "Jacksun",
            separator: " · ",
            keepsSourceSequence: false,
            numbersConflicts: true
        )
        let packID = UUID()
        let first = makeItem(packID: packID, path: "A/Cinematic_Braam_01.wav")
        let second = makeItem(packID: packID, path: "B/Cinematic_Braam_02.wav")
        let baseSuggestion = SoundMetadataSuggestion(
            displayName: "电影重击 01",
            tags: ["冲击"],
            confidence: 0.8,
            reasons: ["测试"]
        )
        let candidates = SoundMetadataSuggestion.numberConflicts(
            in: [
                MetadataSuggestionCandidate(item: first, suggestion: baseSuggestion),
                MetadataSuggestionCandidate(item: second, suggestion: baseSuggestion)
            ],
            using: profile
        )
        #expect(profile.personalizedName(baseName: "电影重击 01", searchableText: first.searchableText) == "Jacksun · 深渊号角 · 电影重击")
        #expect(candidates.map(\.suggestion.displayName) == ["电影重击 01 · 01", "电影重击 01 · 02"])

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = LibraryPersistence(baseDirectory: directory)
        try persistence.save([])
        try persistence.saveNamingProfile(profile)
        #expect(try persistence.loadNamingProfile() == profile)
    }

    @Test func structuralSavePrunesIntelligenceForRemovedSounds() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = LibraryPersistence(baseDirectory: directory)
        let packID = UUID()
        let item = makeItem(packID: packID, path: "转场/whoosh.wav")
        try persistence.save([
            SoundPack(id: packID, name: "测试", rootPath: directory.path, items: [item])
        ])
        try persistence.saveAudioIntelligence(
            soundID: item.id,
            intelligence: .init(
                bpm: 120,
                bpmConfidence: 0.5,
                loudnessLUFS: -18,
                musicalKey: nil,
                keyConfidence: 0,
                analyzedAt: Date()
            )
        )
        #expect(try persistence.loadAudioIntelligence()[item.id] != nil)

        try persistence.save([])
        #expect(try persistence.loadAudioIntelligence()[item.id] == nil)
    }

    @Test func sqliteFullTextSearchFindsNamesPathsAndTags() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = LibraryPersistence(baseDirectory: directory)
        let packID = UUID()
        var item = makeItem(packID: packID, path: "Transitions/Silver_Whoosh_呼啸.wav")
        item.tags = ["电影", "银色"]
        try persistence.save([
            SoundPack(id: packID, name: "测试", rootPath: directory.path, items: [item])
        ])

        #expect(try persistence.searchSoundIDs(matching: "Silver").contains(item.id))
        #expect(try persistence.searchSoundIDs(matching: "银色").contains(item.id))
        #expect(try persistence.searchSoundIDs(matching: "呼").contains(item.id))
        #expect(try persistence.searchSoundIDs(matching: "啸").contains(item.id))

        try persistence.updateMetadata(soundID: item.id, customName: "月光呼啸", tags: ["夜景"])
        #expect(try persistence.searchSoundIDs(matching: "月光").contains(item.id))
    }

    @Test func indexedCJKSearchFindsHitsAcrossThousandsOfSounds() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let persistence = LibraryPersistence(baseDirectory: directory)
        let packID = UUID()
        let hitIndexes = Set(stride(from: 0, to: 6_000, by: 997))
        var items: [SoundItem] = []
        items.reserveCapacity(6_000)
        for index in 0..<6_000 {
            let stem = hitIndexes.contains(index)
                ? "呼啸_\(index)"
                : "ambience_\(index)"
            items.append(
                SoundItem(
                    packageID: packID,
                    relativePath: "大库/\(stem).wav",
                    fileName: "\(stem).wav",
                    folderPath: "大库",
                    fileExtension: "wav"
                )
            )
        }
        try persistence.save([
            SoundPack(id: packID, name: "六千条测试音效", rootPath: directory.path, items: items)
        ])

        let hits = try persistence.searchSoundIDs(matching: "啸")
        #expect(hits.count == hitIndexes.count)
        #expect(hits == Set(items.enumerated().compactMap { index, item in
            hitIndexes.contains(index) ? item.id : nil
        }))
    }

    @Test func legacyJSONAutomaticallyMigratesWithoutLosingIndex() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = LibraryPersistence(baseDirectory: directory)
        let packID = UUID()
        let itemID = UUID()
        let json = """
        [{
          "id":"\(packID.uuidString)",
          "name":"旧素材库",
          "rootPath":"/Volumes/声音",
          "importedAt":"2026-01-01T00:00:00Z",
          "lastScannedAt":"2026-01-01T00:00:00Z",
          "items":[{
            "id":"\(itemID.uuidString)",
            "packageID":"\(packID.uuidString)",
            "relativePath":"环境/雨.wav",
            "fileName":"雨.wav",
            "folderPath":"环境",
            "fileExtension":"wav",
            "duration":3,
            "isFavorite":true
          }]
        }]
        """
        try Data(json.utf8).write(to: persistence.legacyJSONURL)

        let loaded = try persistence.load()
        #expect(loaded.first?.items.first?.id == itemID)
        #expect(loaded.first?.items.first?.tags == [])
        #expect(loaded.first?.items.first?.customName == nil)
        #expect(FileManager.default.fileExists(atPath: persistence.legacyJSONURL.path))
        #expect(FileManager.default.fileExists(atPath: persistence.databaseURL.path))
    }

    @Test func legacyArrayRecoveryBackupRemainsReadable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let persistence = LibraryPersistence(baseDirectory: directory)
        let packID = UUID()
        let pack = SoundPack(
            id: packID,
            name: "旧恢复格式",
            rootPath: directory.path,
            items: [makeItem(packID: packID, path: "old.wav")]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([pack]).write(to: persistence.backupURL)

        #expect(try persistence.load().first?.id == packID)
        #expect(FileManager.default.fileExists(atPath: persistence.databaseURL.path))
    }

    @Test func corruptSQLiteRecoversFromBackupAndArchivesUnreadableFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = LibraryPersistence(baseDirectory: directory)
        let packID = UUID()
        let expected = SoundPack(
            id: packID,
            name: "可恢复素材",
            rootPath: directory.path,
            items: [makeItem(packID: packID, path: "recover.wav")]
        )
        try persistence.save([expected])
        let savedCollection = SavedCollection(
            name: "恢复后的集合",
            scope: .pack(packID)
        )
        let intelligence = AudioIntelligence(
            bpm: 96,
            bpmConfidence: 0.7,
            loudnessLUFS: -16,
            musicalKey: MusicalKey(root: .c, mode: .major),
            keyConfidence: 0.6,
            analyzedAt: Date(timeIntervalSince1970: 1_750_000_200)
        )
        try persistence.saveSavedCollection(savedCollection)
        try persistence.saveAudioIntelligence(
            soundID: expected.items[0].id,
            intelligence: intelligence
        )
        try persistence.saveRecoveryBackup(
            LibraryRecoverySnapshot(
                packs: [expected],
                savedCollections: [savedCollection],
                intelligenceByID: [expected.items[0].id: intelligence]
            )
        )
        try Data("not-a-sqlite-database".utf8).write(to: persistence.databaseURL)

        let recovered = try persistence.load()
        #expect(recovered.first?.id == packID)
        #expect(recovered.first?.items.count == 1)
        #expect((try? FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("Recovery"),
            includingPropertiesForKeys: nil
        ).isEmpty) == false)
        #expect(try persistence.load().first?.items.first?.fileName == "recover.wav")
        #expect(try persistence.loadSavedCollections().map(\.id) == [savedCollection.id])
        #expect(try persistence.loadAudioIntelligence()[expected.items[0].id] == intelligence)
    }

    @Test func smartCollectionsUseOriginalNamesAliasesAndTags() {
        let packID = UUID()
        var sound = makeItem(packID: packID, path: "misc/unknown.wav")
        #expect(SmartCollection.untagged.matches(sound))
        sound.customName = "未来科技按钮"
        sound.tags = ["界面"]
        #expect(SmartCollection.technology.matches(sound))
        #expect(!SmartCollection.untagged.matches(sound))
    }

    @Test func smartTaxonomyPartitionsLargeParentsIntoSpecificChildren() {
        let packID = UUID()
        let riser = makeItem(packID: packID, path: "Transitions/Fast_Riser_Whoosh_01.wav")
        #expect(SmartCollection.transition.matches(riser))
        #expect(SmartSubcollection.transitionRiser.matches(riser))
        #expect(!SmartSubcollection.transitionWhoosh.matches(riser))
        let instantRiser = SmartLeafCollection(detail: .transitionRiser, durationBand: .unknown)
        #expect(instantRiser.matches(riser))

        let rain = makeItem(packID: packID, path: "Atmospheres/Heavy_Rain_City.wav")
        #expect(SmartCollection.ambience.matches(rain))
        #expect(SmartSubcollection.ambienceWeather.matches(rain))

        var namedButUnknown = makeItem(packID: packID, path: "misc/opaque_001.wav")
        namedButUnknown.customName = "我的私人素材"
        #expect(SmartCollection.untagged.matches(namedButUnknown))
        #expect(SmartCollection.untagged.title == "未识别")

        let pack = SoundPack(
            id: packID,
            name: "测试包",
            rootPath: "/tmp/测试包",
            items: [riser, rain, namedButUnknown]
        )
        let index = SmartTaxonomy.index(for: [pack], revision: 1)
        #expect(index.contains(riser.id, in: .transition))
        #expect(index.contains(riser.id, in: .transitionRiser))
        #expect(index.contains(riser.id, in: SmartLeafCollection(detail: .transitionRiser, durationBand: .unknown)))
        #expect(index.contains(namedButUnknown.id, in: .unknown))
        #expect(index.parentCounts[.transition] == 1)
        #expect(index.detailCounts[.ambienceWeather] == 1)
    }

    @Test func smartTaxonomyCacheInvalidatesWhenSourcePathChanges() {
        let packID = UUID()
        let whoosh = makeItem(packID: packID, path: "转场/银色呼啸.wav")
        #expect(SmartCollection.transition.matches(whoosh))

        let footsteps = SoundItem(
            id: whoosh.id,
            packageID: packID,
            relativePath: "拟音/脚步.wav",
            fileName: "脚步.wav",
            folderPath: "拟音",
            fileExtension: "wav"
        )
        #expect(SmartCollection.foley.matches(footsteps))
        #expect(!SmartCollection.transition.matches(footsteps))
    }

    @Test func smartTaxonomyClassificationCacheFitsOneCreatorScaleLibraryWithinACostBudget() {
        let classification = SmartTaxonomy.classify(
            normalizedText: "cinematic fast riser whoosh transition"
        )
        let key = "00000000-0000-0000-0000-000000000000:123456789" as NSString
        let cost = SmartTaxonomyCachePolicy.estimatedCost(
            key: key,
            classification: classification
        )

        #expect(SmartTaxonomyCachePolicy.maximumClassificationEntries >= 36_487)
        #expect(SmartTaxonomyCachePolicy.maximumClassificationEntries < 100_000)
        #expect(SmartTaxonomyCachePolicy.maximumEstimatedClassificationBytes == 24 * 1_024 * 1_024)
        #expect(cost > key.lengthOfBytes(using: String.Encoding.utf8.rawValue))
        #expect(cost < 1_024)
    }

    @Test func localMetadataSuggestionCleansNamesAndNeverChangesSourceFields() {
        let packID = UUID()
        let item = makeItem(packID: packID, path: "电影音效/转场/Fast_Riser-01.wav")
        let suggestion = SoundMetadataSuggestion.make(for: item)
        #expect(suggestion.displayName == "快速 上升转场 01")
        #expect(suggestion.tags.contains("转场"))
        #expect(suggestion.confidence >= 0.8)
        #expect(!suggestion.reasons.isEmpty)
        #expect(item.fileName == "Fast_Riser-01.wav")
        #expect(item.relativePath == "电影音效/转场/Fast_Riser-01.wav")
    }

    @Test func metadataSuggestionRemovesDuplicatedEnglishAndStockNumbersFromChineseAlias() {
        let packID = UUID()
        let meaningfulChinese = makeItem(
            packID: packID,
            path: "车辆/100045_车快速一闪而过声_Car_Fast_Pass.wav"
        )
        let meaningfulSuggestion = SoundMetadataSuggestion.make(for: meaningfulChinese)
        #expect(meaningfulSuggestion.displayName == "车快速一闪而过声")

        let genericPrefix = makeItem(
            packID: packID,
            path: "Adobe/氛围1_Ambience_Car_Drive_Interior_Rain_02.wav"
        )
        let generatedSuggestion = SoundMetadataSuggestion.make(for: genericPrefix)
        #expect(!generatedSuggestion.displayName.contains("Ambience"))
        #expect(!generatedSuggestion.displayName.unicodeScalars.contains {
            CharacterSet.letters.contains($0) && $0.isASCII
        })
    }

    @Test func hybridSemanticSearchFindsCrossLanguageCreatorIntent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = LibraryPersistence(baseDirectory: directory)
        let packID = UUID()
        let rain = makeItem(
            packID: packID,
            path: "Atmospheres/Night/Far_Rain_Traffic_01.wav"
        )
        let engine = makeItem(packID: packID, path: "Foley/Vehicle/Car_Engine_Close_01.wav")
        let click = makeItem(packID: packID, path: "UI/Click_01.wav")
        try persistence.save([
            SoundPack(
                id: packID,
                name: "Semantic Pack",
                rootPath: directory.path,
                items: [rain, engine, click]
            )
        ])

        let literal = try persistence.searchSoundMatches(
            matching: "夜晚远处雨声",
            mode: .literal
        )
        let hybrid = try persistence.searchSoundMatches(
            matching: "夜晚远处雨声",
            mode: .hybrid
        )
        #expect(!literal.ids.contains(rain.id))
        #expect(hybrid.ids.contains(rain.id))
        #expect(!hybrid.ids.contains(click.id))
        #expect(hybrid.semanticMatchCount >= 1)
        #expect(hybrid.conceptTitles.contains("夜晚"))
    }

    @Test func legacyDatabaseBuildsSemanticIndexLazilyAndReportsProgress() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = LibraryPersistence(baseDirectory: directory)
        let packID = UUID()
        let rain = makeItem(packID: packID, path: "Atmospheres/Far_Night_Rain_01.wav")
        let click = makeItem(packID: packID, path: "UI/Click_01.wav")
        try persistence.save([
            SoundPack(
                id: packID,
                name: "旧资料库",
                rootPath: directory.path,
                items: [rain, click]
            )
        ])

        var database: OpaquePointer?
        #expect(sqlite3_open(persistence.databaseURL.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(database, "DELETE FROM sound_semantic_concepts", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(database, "DELETE FROM sound_variant_families", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(database, "DELETE FROM semantic_index_state", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        database = nil

        let recorder = ProgressRecorder()
        let matches = try persistence.searchSoundMatches(
            matching: "远处夜晚雨声",
            mode: .hybrid
        ) { progress in
            recorder.append(completed: progress.completed, total: progress.total)
        }

        #expect(matches.ids.contains(rain.id))
        #expect(!matches.ids.contains(click.id))
        #expect(recorder.snapshot().first?.0 == 0)
        #expect(recorder.snapshot().last?.0 == 2)
        #expect(recorder.snapshot().last?.1 == 2)
    }

    @Test func configuredCreatorScaleLibraryKeepsSemanticResultsBounded() throws {
        guard let directoryPath = ProcessInfo.processInfo.environment["SHIXIANG_CREATOR_LIBRARY_COPY"] else {
            return
        }
        let persistence = LibraryPersistence(
            baseDirectory: URL(fileURLWithPath: directoryPath, isDirectory: true)
        )
        let sounds = try persistence.load().flatMap(\.items)
        #expect(sounds.count >= 30_000)

        let clock = ContinuousClock()
        let firstStart = clock.now
        let first = try persistence.searchSoundMatches(
            matching: "快速呼啸转场",
            mode: .hybrid
        )
        let firstDuration = firstStart.duration(to: clock.now)
        #expect(!first.ids.isEmpty)
        #expect(firstDuration < .seconds(30))

        let warmStart = clock.now
        _ = try persistence.searchSoundMatches(matching: "雨夜远处汽车", mode: .hybrid)
        let warmDuration = warmStart.duration(to: clock.now)
        #expect(warmDuration < .seconds(3))

        let similarityStart = clock.now
        var similarityDuration = Duration.zero
        if let soundID = first.ids.first {
            let similar = try persistence.similarityCandidates(for: soundID)
            #expect(similar.count <= 400)
            similarityDuration = similarityStart.duration(to: clock.now)
        }
        print(
            "Creator-scale local semantic timings: cold=\(firstDuration), "
                + "warm=\(warmDuration), similar=\(similarityDuration)"
        )
    }

    @Test func similarityIndexKeepsNumberedAndDistanceVariantsInOneFamily() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = LibraryPersistence(baseDirectory: directory)
        let packID = UUID()
        let far = makeItem(packID: packID, path: "Vehicles/Car_Engine_Far_01.wav")
        let close = makeItem(packID: packID, path: "Vehicles/Car_Engine_Close_02.wav")
        let door = makeItem(packID: packID, path: "Vehicles/Car_Door_01.wav")
        try persistence.save([
            SoundPack(
                id: packID,
                name: "Vehicle Pack",
                rootPath: directory.path,
                items: [far, close, door]
            )
        ])

        let matches = try persistence.similarityCandidates(for: far.id)
        let closeMatch = try #require(matches.first { $0.soundID == close.id })
        #expect(closeMatch.isSameFamily)
        #expect(matches.first(where: { $0.soundID == door.id })?.isSameFamily != true)
    }

    @Test func metadataUndoBatchPersistsWithoutContainingAudioBytes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = LibraryPersistence(baseDirectory: directory)
        try persistence.save([])
        let change = MetadataUndoChange(
            soundID: UUID(),
            previousName: nil,
            previousTags: [],
            appliedName: "远处风声",
            appliedTags: ["环境", "远处"]
        )
        let batch = MetadataUndoBatch(changes: [change])
        try persistence.saveMetadataUndoBatch(batch)
        #expect(try persistence.loadLatestMetadataUndoBatch() == batch)
        try persistence.deleteMetadataUndoBatch(id: batch.id)
        #expect(try persistence.loadLatestMetadataUndoBatch() == nil)
    }

    @Test @MainActor func intelligentMetadataApplyAndUndoRoundTripsThroughStoreAndSQLite() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = LibraryPersistence(baseDirectory: directory)
        let packID = UUID()
        let item = makeItem(packID: packID, path: "Transitions/Fast_Riser_01.wav")
        try persistence.save([
            SoundPack(id: packID, name: "命名测试", rootPath: directory.path, items: [item])
        ])
        let store = LibraryStore(persistence: persistence)
        let candidate = MetadataSuggestionCandidate(
            item: item,
            suggestion: SoundMetadataSuggestion.make(for: item)
        )

        store.startApplyMetadataSuggestions([candidate], selectedIDs: [item.id])
        for _ in 0..<300 {
            if store.batchOperationProgress == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.batchOperationProgress == nil)
        #expect(store.sound(id: item.id)?.customName == "快速 上升转场 01")
        #expect(try persistence.load().first?.items.first?.customName == "快速 上升转场 01")
        #expect(store.lastMetadataUndoBatch != nil)

        store.startUndoLastMetadataSuggestions()
        for _ in 0..<300 {
            if store.batchOperationProgress == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.batchOperationProgress == nil)
        #expect(store.sound(id: item.id)?.customName == nil)
        #expect(store.sound(id: item.id)?.tags == [])
        #expect(try persistence.load().first?.items.first?.customName == nil)
        #expect(try persistence.loadLatestMetadataUndoBatch() == nil)
    }

    @Test func healthSnapshotBuilderPreservesRootsMetadataAndSourcePaths() throws {
        let fallbackRoot = URL(fileURLWithPath: "/Volumes/Original Pack", isDirectory: true)
        let scopedRoot = URL(fileURLWithPath: "/Volumes/Relinked Pack", isDirectory: true)
        let packID = UUID()
        let item = SoundItem(
            packageID: packID,
            relativePath: "Whooshes/Fast.wav",
            fileName: "Fast.wav",
            folderPath: "Whooshes",
            fileExtension: "wav",
            duration: 1.25,
            sampleRate: 48_000,
            channelCount: 2,
            sourceFileSize: 1_024,
            sourceModificationDate: Date(timeIntervalSince1970: 1_234),
            sourceContentSignature: 55
        )
        let snapshot = try LibraryHealthSnapshotBuilder.make(
            packs: [SoundPack(id: packID, name: "转场", rootPath: fallbackRoot.path, items: [item])],
            scopedRootURLs: [packID: scopedRoot],
            databaseBytes: 4_096,
            hasRecoveryBackup: true
        )

        #expect(snapshot.packs.first?.rootURL == scopedRoot)
        #expect(snapshot.items.first?.url == scopedRoot.appendingPathComponent(item.relativePath))
        #expect(snapshot.items.first?.sourceFileSize == item.sourceFileSize)
        #expect(snapshot.items.first?.sourceModificationDate == item.sourceModificationDate)
        #expect(snapshot.items.first?.sourceContentSignature == item.sourceContentSignature)
        #expect(snapshot.databaseBytes == 4_096)
        #expect(snapshot.hasRecoveryBackup)
    }

    @Test func healthCheckFindsMissingAndProbableDuplicatesWithoutChangingFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data(repeating: 0x5A, count: 40_000)
        let firstURL = directory.appendingPathComponent("one.wav")
        let secondURL = directory.appendingPathComponent("two.wav")
        try data.write(to: firstURL)
        try data.write(to: secondURL)
        let packID = UUID()
        let snapshot = LibraryHealthSnapshot(
            packs: [LibraryHealthPack(id: packID, name: "测试", rootURL: directory)],
            items: [
                LibraryHealthItem(id: UUID(), packID: packID, packName: "测试", displayName: "一", relativePath: "one.wav", url: firstURL),
                LibraryHealthItem(id: UUID(), packID: packID, packName: "测试", displayName: "二", relativePath: "two.wav", url: secondURL),
                LibraryHealthItem(id: UUID(), packID: packID, packName: "测试", displayName: "缺失", relativePath: "missing.wav", url: directory.appendingPathComponent("missing.wav"))
            ],
            databaseBytes: 1_024,
            hasRecoveryBackup: true
        )

        let report = try await LibraryHealthService.inspect(snapshot)
        #expect(report.missingItems.count == 1)
        #expect(report.probableDuplicateCount == 1)
        let repeatedReport = try await LibraryHealthService.inspect(snapshot)
        #expect(repeatedReport.reusedFingerprintCount == 2)
        #expect((try? Data(contentsOf: firstURL)) == data)
        #expect((try? Data(contentsOf: secondURL)) == data)
    }

    @Test func healthCheckReusesIndexedFingerprintsForUnchangedDuplicates() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data(repeating: 0x7B, count: 40_000)
        let firstURL = directory.appendingPathComponent("cached-one.wav")
        let secondURL = directory.appendingPathComponent("cached-two.wav")
        try data.write(to: firstURL)
        try data.write(to: secondURL)
        let firstValues = try firstURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let secondValues = try secondURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let packID = UUID()
        let signature: UInt64 = 9_876_543
        let snapshot = LibraryHealthSnapshot(
            packs: [LibraryHealthPack(id: packID, name: "缓存测试", rootURL: directory)],
            items: [
                LibraryHealthItem(
                    id: UUID(),
                    packID: packID,
                    packName: "缓存测试",
                    displayName: "一",
                    relativePath: "cached-one.wav",
                    url: firstURL,
                    sourceFileSize: Int64(firstValues.fileSize ?? 0),
                    sourceModificationDate: firstValues.contentModificationDate,
                    sourceContentSignature: signature
                ),
                LibraryHealthItem(
                    id: UUID(),
                    packID: packID,
                    packName: "缓存测试",
                    displayName: "二",
                    relativePath: "cached-two.wav",
                    url: secondURL,
                    sourceFileSize: Int64(secondValues.fileSize ?? 0),
                    sourceModificationDate: secondValues.contentModificationDate,
                    sourceContentSignature: signature
                )
            ],
            databaseBytes: 0,
            hasRecoveryBackup: false
        )

        let report = try await LibraryHealthService.inspect(snapshot)
        #expect(report.probableDuplicateCount == 1)
        #expect(report.reusedFingerprintCount == 2)
        #expect((try? Data(contentsOf: firstURL)) == data)
        #expect((try? Data(contentsOf: secondURL)) == data)
    }

    @Test func healthCheckKeepsDuplicateIdentityStableAcrossMixedIndexState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data(repeating: 0x35, count: 24_000)
        let firstURL = directory.appendingPathComponent("indexed.wav")
        let secondURL = directory.appendingPathComponent("legacy.wav")
        try data.write(to: firstURL)
        try data.write(to: secondURL)

        let packID = UUID()
        let scanned = try await LibraryScanner().scan(rootURL: directory, packageID: packID)
        let indexed = try #require(scanned.first { $0.fileName == firstURL.lastPathComponent })
        let snapshot = LibraryHealthSnapshot(
            packs: [LibraryHealthPack(id: packID, name: "混合索引", rootURL: directory)],
            items: [
                LibraryHealthItem(
                    id: indexed.id,
                    packID: packID,
                    packName: "混合索引",
                    displayName: "已扫描",
                    relativePath: indexed.relativePath,
                    url: firstURL,
                    sourceFileSize: indexed.sourceFileSize,
                    sourceModificationDate: indexed.sourceModificationDate,
                    sourceContentSignature: indexed.sourceContentSignature
                ),
                LibraryHealthItem(
                    id: UUID(),
                    packID: packID,
                    packName: "混合索引",
                    displayName: "旧索引",
                    relativePath: secondURL.lastPathComponent,
                    url: secondURL
                )
            ],
            databaseBytes: 0,
            hasRecoveryBackup: false
        )

        let report = try await LibraryHealthService.inspect(snapshot)
        #expect(report.probableDuplicateCount == 1)
        #expect(report.reusedFingerprintCount == 1)
        #expect(report.duplicateGroups.first?.fingerprint.hasPrefix("sample-v1:") == true)
    }

    @Test func incrementalScannerReusesStableFilesAndReportsOnlyRealChanges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstURL = root.appendingPathComponent("first.wav")
        let secondURL = root.appendingPathComponent("second.wav")
        let stableURL = root.appendingPathComponent("stable.wav")
        try Data(repeating: 0x11, count: 128).write(to: firstURL)
        try Data(repeating: 0x22, count: 256).write(to: secondURL)
        try Data(repeating: 0x33, count: 384).write(to: stableURL)

        let scanner = LibraryScanner()
        let packID = UUID()
        let initial = try await scanner.scanResult(rootURL: root, packageID: packID)
        let unchanged = try await scanner.scanResult(
            rootURL: root,
            packageID: packID,
            existingItems: initial.items
        )
        #expect(unchanged.statistics.reusedCount == 3)
        #expect(unchanged.statistics.analyzedCount == 0)
        #expect(unchanged.statistics.changedCount == 0)

        try Data(repeating: 0x44, count: 512).write(to: firstURL)
        try FileManager.default.removeItem(at: secondURL)
        try Data(repeating: 0x55, count: 640).write(to: root.appendingPathComponent("added.wav"))

        let changed = try await scanner.scanResult(
            rootURL: root,
            packageID: packID,
            existingItems: unchanged.items
        )
        #expect(changed.statistics.reusedCount == 1)
        #expect(changed.statistics.analyzedCount == 2)
        #expect(changed.statistics.addedCount == 1)
        #expect(changed.statistics.removedCount == 1)
        #expect(changed.statistics.updatedCount == 1)
        #expect((try? Data(contentsOf: stableURL)) == Data(repeating: 0x33, count: 384))
    }

    @Test func scannerReusesFractionalFileDatesAfterSQLiteRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let indexDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: indexDirectory)
        }

        let fileURL = root.appendingPathComponent("fractional-date.wav")
        let sourceBytes = Data(repeating: 0x4A, count: 1_024)
        try sourceBytes.write(to: fileURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_696_883_694.59)],
            ofItemAtPath: fileURL.path
        )

        let packID = UUID()
        let scanner = LibraryScanner()
        let initial = try await scanner.scanResult(rootURL: root, packageID: packID)
        let persistence = LibraryPersistence(baseDirectory: indexDirectory)
        try persistence.save([
            SoundPack(
                id: packID,
                name: "小数时间音效包",
                rootPath: root.path,
                items: initial.items
            )
        ])
        let loaded = try #require(persistence.load().first)
        let refreshed = try await scanner.scanResult(
            rootURL: root,
            packageID: packID,
            existingItems: loaded.items
        )

        #expect(refreshed.statistics.reusedCount == 1)
        #expect(refreshed.statistics.analyzedCount == 0)
        #expect(refreshed.statistics.updatedCount == 0)
        #expect((try? Data(contentsOf: fileURL)) == sourceBytes)
    }

    @Test func sourceDateToleranceAcceptsOnlyEpochRoundTripNoise() {
        let sourceDate = Date(timeIntervalSinceReferenceDate: 718_576_494.59)
        let sqliteRoundTrip = sourceDate.addingTimeInterval(0.000_000_238_418_579)
        let realChange = sourceDate.addingTimeInterval(0.001)

        #expect(SourceModificationDatePolicy.matches(sourceDate, sqliteRoundTrip))
        #expect(!SourceModificationDatePolicy.matches(sourceDate, realChange))
        #expect(!SourceModificationDatePolicy.matches(sourceDate, nil))
    }

    @Test @MainActor func unchangedManualRefreshSkipsPersistenceAndPreservesWorkingSet() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = directory.appendingPathComponent("source", isDirectory: true)
        let indexDirectory = directory.appendingPathComponent("index", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = root.appendingPathComponent("unchanged.wav")
        let sourceBytes = Data(repeating: 0x5B, count: 2_048)
        try sourceBytes.write(to: fileURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_696_883_694.59)],
            ofItemAtPath: fileURL.path
        )

        let packID = UUID()
        let scanned = try await LibraryScanner().scan(rootURL: root, packageID: packID)
        let scannedAt = Date(timeIntervalSince1970: 1_750_100_000)
        let persistence = LibraryPersistence(baseDirectory: indexDirectory)
        try persistence.save([
            SoundPack(
                id: packID,
                name: "零变化刷新",
                rootPath: root.path,
                lastScannedAt: scannedAt,
                items: scanned
            )
        ])

        let store = LibraryStore(persistence: persistence)
        let soundID = try #require(store.packs.first?.items.first?.id)
        store.selectSound(soundID)
        let originalItems = try #require(store.packs.first?.items)
        let originalLibraryRevision = store.libraryRevision
        let originalClassificationRevision = store.classificationRevision

        try FileManager.default.removeItem(at: persistence.databaseURL)
        try FileManager.default.createDirectory(
            at: persistence.databaseURL,
            withIntermediateDirectories: false
        )
        await store.refreshSelectedPack()
        try await Task.sleep(for: .milliseconds(350))

        #expect(store.lastScanResult?.statistics.reusedCount == 1)
        #expect(store.lastScanResult?.statistics.analyzedCount == 0)
        #expect(store.lastScanResult?.statistics.changedCount == 0)
        #expect(store.packs.first?.items == originalItems)
        #expect(store.packs.first?.lastScannedAt == scannedAt)
        #expect(store.selectedSoundID == soundID)
        #expect(store.libraryRevision == originalLibraryRevision)
        #expect(store.classificationRevision == originalClassificationRevision)
        #expect(store.alertMessage == nil)
        #expect((try? Data(contentsOf: fileURL)) == sourceBytes)
    }

    @Test func unreadableReplacementKeepsKnownAudioMetadataWithoutTouchingTheSource() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("temporarily-unreadable.wav")
        let originalBytes = Data(repeating: 0x31, count: 128)
        try originalBytes.write(to: fileURL)
        let originalDate = Date(timeIntervalSince1970: 1_750_001_000)
        try FileManager.default.setAttributes(
            [.modificationDate: originalDate],
            ofItemAtPath: fileURL.path
        )

        let packID = UUID()
        let previous = SoundItem(
            packageID: packID,
            relativePath: fileURL.lastPathComponent,
            fileName: fileURL.lastPathComponent,
            folderPath: "",
            fileExtension: "wav",
            duration: 12.5,
            sampleRate: 48_000,
            channelCount: 2,
            sourceFileSize: Int64(originalBytes.count),
            sourceModificationDate: originalDate,
            sourceContentSignature: 123,
            isFavorite: true,
            customName: "临时离线素材",
            tags: ["保留"]
        )

        let replacementBytes = Data(repeating: 0x7A, count: 256)
        try replacementBytes.write(to: fileURL)
        let replacementDate = originalDate.addingTimeInterval(20)
        try FileManager.default.setAttributes(
            [.modificationDate: replacementDate],
            ofItemAtPath: fileURL.path
        )

        let scanner = LibraryScanner()
        let changed = try await scanner.scanResult(
            rootURL: root,
            packageID: packID,
            existingItems: [previous]
        )
        let retained = try #require(changed.items.first)
        #expect(retained.id == previous.id)
        #expect(retained.duration == 12.5)
        #expect(retained.sampleRate == 48_000)
        #expect(retained.channelCount == 2)
        #expect(retained.isFavorite)
        #expect(retained.customName == "临时离线素材")
        #expect(retained.tags == ["保留"])
        #expect(retained.sourceFileSize == Int64(replacementBytes.count))
        #expect(changed.statistics.updatedCount == 1)
        #expect(changed.statistics.analyzedCount == 1)
        #expect((try? Data(contentsOf: fileURL)) == replacementBytes)

        let unchanged = try await scanner.scanResult(
            rootURL: root,
            packageID: packID,
            existingItems: changed.items
        )
        #expect(unchanged.statistics.reusedCount == 1)
        #expect(unchanged.statistics.analyzedCount == 0)
        #expect(unchanged.items.first?.duration == 12.5)
        #expect((try? Data(contentsOf: fileURL)) == replacementBytes)
    }

    @Test func sqliteBulkEditsRemainTargetedAndSearchable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let persistence = LibraryPersistence(baseDirectory: directory)
        let packID = UUID()
        let first = makeItem(packID: packID, path: "环境/雨声.wav")
        let second = makeItem(packID: packID, path: "拟音/脚步.wav")
        try persistence.save([
            SoundPack(
                id: packID,
                name: "批量测试",
                rootPath: directory.path,
                items: [first, second]
            )
        ])

        try persistence.updateFavorites(soundIDs: [first.id, second.id], isFavorite: true)
        try persistence.updateMetadata([
            LibraryMetadataUpdate(soundID: first.id, customName: nil, tags: ["夜景", "雨"]),
            LibraryMetadataUpdate(soundID: second.id, customName: "木地板脚步", tags: ["拟音"])
        ])

        let reloaded = try persistence.load().flatMap(\.items)
        #expect(reloaded.allSatisfy { $0.isFavorite })
        #expect(reloaded.first(where: { $0.id == first.id })?.tags == ["夜景", "雨"])
        #expect(reloaded.first(where: { $0.id == second.id })?.customName == "木地板脚步")
        #expect(try persistence.searchSoundIDs(matching: "夜景") == [first.id])
        #expect(try persistence.searchSoundIDs(matching: "木地板") == [second.id])
    }

    @Test func duplicateReviewStateRoundTripsAndRemainsIndexOnly() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("original.wav")
        let sourceData = Data(repeating: 0x2A, count: 128)
        try sourceData.write(to: sourceURL)

        let persistence = LibraryPersistence(baseDirectory: directory.appendingPathComponent("index"))
        let packID = UUID()
        let item = SoundItem(
            packageID: packID,
            relativePath: sourceURL.lastPathComponent,
            fileName: sourceURL.lastPathComponent,
            folderPath: "",
            fileExtension: "wav",
            isHidden: true
        )
        let fingerprint = "indexed-v1:128:42"
        try persistence.save(
            [SoundPack(id: packID, name: "重复项", rootPath: directory.path, items: [item])],
            savedCollections: [],
            intelligenceByID: [:],
            ignoredDuplicateFingerprints: [fingerprint]
        )

        #expect(try persistence.load().first?.items.first?.isHidden == true)
        #expect(try persistence.loadIgnoredDuplicateFingerprints() == [fingerprint])
        try persistence.updateHidden(soundIDs: [item.id], isHidden: false)
        try persistence.setDuplicateGroupIgnored(fingerprint: fingerprint, isIgnored: false)
        #expect(try persistence.load().first?.items.first?.isHidden == false)
        #expect(try persistence.loadIgnoredDuplicateFingerprints().isEmpty)
        #expect((try? Data(contentsOf: sourceURL)) == sourceData)
    }

    @Test @MainActor func hiddenSoundCountLoadsAndUpdatesWithoutRescanningTheLibrary() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = LibraryPersistence(baseDirectory: directory)
        let packID = UUID()
        var hidden = makeItem(packID: packID, path: "重复/隐藏.wav")
        hidden.isHidden = true
        let visible = makeItem(packID: packID, path: "重复/保留.wav")
        try persistence.save([
            SoundPack(
                id: packID,
                name: "重复项",
                rootPath: directory.path,
                items: [hidden, visible]
            )
        ])

        let store = LibraryStore(persistence: persistence)
        #expect(store.hiddenSoundCount == 1)
        #expect(store.setSoundsHidden([visible.id], isHidden: true) == 1)
        #expect(store.hiddenSoundCount == 2)
        for _ in 0..<100 {
            let saved = try persistence.load().flatMap(\.items)
            if saved.allSatisfy(\.isHidden) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try persistence.load().flatMap(\.items).allSatisfy(\.isHidden))
        store.restoreAllHiddenSounds()
        #expect(store.hiddenSoundCount == 0)
        #expect(store.batchOperationResult?.message == "已恢复 2 个隐藏声音")

        for _ in 0..<100 {
            let saved = try persistence.load().flatMap(\.items)
            if saved.allSatisfy({ !$0.isHidden }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try persistence.load().flatMap(\.items).allSatisfy { !$0.isHidden })
    }

    @Test func cancelledBulkFavoriteTransactionRollsBackCompletely() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = LibraryPersistence(baseDirectory: directory)
        let packID = UUID()
        let items = (0..<200).map { index in
            makeItem(packID: packID, path: "批量/\(index).wav")
        }
        try persistence.save([
            SoundPack(id: packID, name: "取消测试", rootPath: directory.path, items: items)
        ])

        do {
            try await Task.detached {
                try persistence.updateFavorites(
                    soundIDs: items.map(\.id),
                    isFavorite: true
                ) { completed, _ in
                    if completed > 0 {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            }.value
            Issue.record("批量事务应该响应取消")
        } catch is CancellationError {
            // Expected: the SQLite transaction rolls back before any UI state is applied.
        }

        #expect(try persistence.load().flatMap(\.items).allSatisfy { !$0.isFavorite })
    }

    @Test func largeResultPagingKeepsRenderedWindowBoundedAndRevealsTargets() {
        let total = 4_969
        let first = SoundPaging.initialRange(total: total)
        let second = SoundPaging.loadingNext(current: first, total: total)
        let third = SoundPaging.loadingNext(current: second, total: total)
        let fourth = SoundPaging.loadingNext(current: third, total: total)
        let targetWindow = SoundPaging.window(total: total, around: 1_200)

        #expect(first == 0..<240)
        #expect(second == 0..<480)
        #expect(third == 0..<720)
        #expect(fourth == 240..<960)
        #expect(fourth.count == SoundPaging.maximumWindowSize)
        #expect(targetWindow == 1_081..<1_321)
        #expect(targetWindow.contains(1_200))
        #expect(targetWindow.count == SoundPaging.pageSize)
        #expect(SoundPaging.loadingPrevious(current: targetWindow, total: total) == 841..<1_321)
        #expect(SoundPaging.window(total: total, around: total - 1) == 4_729..<4_969)
        #expect(SoundPaging.initialRange(total: 12) == 0..<12)
    }

    @Test func favoriteRevisionOnlyInvalidatesFavoriteDependentResults() {
        let revision: UInt64 = 42
        #expect(
            SoundResultsRevisionPolicy.favoriteRevision(
                scope: .all,
                favoritesOnly: false,
                revision: revision
            ) == 0
        )
        #expect(
            SoundResultsRevisionPolicy.favoriteRevision(
                scope: .smart(.transition),
                favoritesOnly: false,
                revision: revision
            ) == 0
        )
        #expect(
            SoundResultsRevisionPolicy.favoriteRevision(
                scope: .favorites,
                favoritesOnly: false,
                revision: revision
            ) == revision
        )
        #expect(
            SoundResultsRevisionPolicy.favoriteRevision(
                scope: .all,
                favoritesOnly: true,
                revision: revision
            ) == revision
        )
        #expect(
            SoundResultsRevisionPolicy.classificationRevision(
                scope: .all,
                revision: revision
            ) == 0
        )
        #expect(
            SoundResultsRevisionPolicy.classificationRevision(
                scope: .smart(.transition),
                revision: revision
            ) == revision
        )
        #expect(
            SoundResultsRevisionPolicy.metadataRevision(
                scope: .all,
                sortMode: .duration,
                query: "",
                revision: revision
            ) == 0
        )
        #expect(
            SoundResultsRevisionPolicy.metadataRevision(
                scope: .all,
                sortMode: .name,
                query: "",
                revision: revision
            ) == revision
        )
        #expect(
            SoundResultsRevisionPolicy.metadataRevision(
                scope: .folder(packID: UUID(), path: "环境"),
                sortMode: .format,
                query: "雨",
                revision: revision
            ) == revision
        )
        #expect(
            SoundResultsRevisionPolicy.metadataRevision(
                scope: .smart(.transition),
                sortMode: .duration,
                query: "",
                revision: revision
            ) == revision
        )
    }

    @Test @MainActor func singleMetadataMutationUsesExactRevisionAndRollsBackOnSaveFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = LibraryPersistence(baseDirectory: directory)
        let packID = UUID()
        let item = makeItem(packID: packID, path: "转场/whoosh.wav")
        try persistence.save([
            SoundPack(id: packID, name: "元数据测试", rootPath: directory.path, items: [item])
        ])

        let store = LibraryStore(persistence: persistence)
        let initialLibraryRevision = store.libraryRevision
        store.updateMetadata(for: item.id, customName: "银色呼啸", tags: ["电影", "转场"])
        #expect(store.libraryRevision == initialLibraryRevision)
        #expect(store.metadataRevision == 1)
        #expect(store.classificationRevision == 1)
        #expect(store.lastMetadataChangedIDs == [item.id])
        for _ in 0..<100 {
            let loaded = try persistence.load().first?.items.first
            if loaded?.customName == "银色呼啸", loaded?.tags == ["电影", "转场"] { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try persistence.load().first?.items.first?.customName == "银色呼啸")

        store.updateMetadata(for: item.id, customName: "银色呼啸", tags: ["电影", "转场"])
        #expect(store.metadataRevision == 1)
        #expect(store.classificationRevision == 1)

        try FileManager.default.removeItem(at: persistence.databaseURL)
        try FileManager.default.createDirectory(at: persistence.databaseURL, withIntermediateDirectories: false)
        store.updateMetadata(for: item.id, customName: "失败的新名字", tags: ["失败"])
        #expect(store.metadataRevision == 2)
        for _ in 0..<100 {
            if store.alertMessage?.contains("别名与标签保存失败") == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.alertMessage?.contains("别名与标签保存失败") == true)
        #expect(store.sound(id: item.id)?.customName == "银色呼啸")
        #expect(store.sound(id: item.id)?.tags == ["电影", "转场"])
        #expect(store.metadataRevision == 3)
        #expect(store.classificationRevision == 3)
        #expect(store.libraryRevision == initialLibraryRevision)
    }

    @Test @MainActor func directTagMutationRollsBackEveryUnchangedOptimisticRow() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = LibraryPersistence(baseDirectory: directory)
        let packID = UUID()
        let first = makeItem(packID: packID, path: "拟音/one.wav")
        let second = makeItem(packID: packID, path: "拟音/two.wav")
        try persistence.save([
            SoundPack(id: packID, name: "标签测试", rootPath: directory.path, items: [first, second])
        ])

        let store = LibraryStore(persistence: persistence)
        let initialLibraryRevision = store.libraryRevision
        try FileManager.default.removeItem(at: persistence.databaseURL)
        try FileManager.default.createDirectory(at: persistence.databaseURL, withIntermediateDirectories: false)

        #expect(store.addTags(["脚步"], to: [first.id, second.id]) == 2)
        #expect(store.metadataRevision == 1)
        for _ in 0..<100 {
            if store.alertMessage?.contains("批量标签保存失败") == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.alertMessage?.contains("批量标签保存失败") == true)
        #expect(store.sound(id: first.id)?.tags.isEmpty == true)
        #expect(store.sound(id: second.id)?.tags.isEmpty == true)
        #expect(store.metadataRevision == 2)
        #expect(Set(store.lastMetadataChangedIDs) == [first.id, second.id])
        #expect(store.classificationRevision == 2)
        #expect(store.libraryRevision == initialLibraryRevision)
    }

    @Test @MainActor func favoriteMutationUsesConstantTimeCountAndRollsBackOnSaveFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = LibraryPersistence(baseDirectory: directory)
        let packID = UUID()
        var first = makeItem(packID: packID, path: "收藏/one.wav")
        first.isFavorite = true
        let second = makeItem(packID: packID, path: "收藏/two.wav")
        try persistence.save([
            SoundPack(id: packID, name: "收藏测试", rootPath: directory.path, items: [first, second])
        ])

        let store = LibraryStore(persistence: persistence)
        let initialLibraryRevision = store.libraryRevision
        #expect(store.favoriteCount == 1)

        store.toggleFavorite(second)
        #expect(store.favoriteCount == 2)
        #expect(store.favoriteRevision == 1)
        #expect(store.lastFavoriteChangedIDs == [second.id])
        #expect(store.libraryRevision == initialLibraryRevision)
        for _ in 0..<100 {
            if try persistence.load().first?.items.first(where: { $0.id == second.id })?.isFavorite == true {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try persistence.load().first?.items.first(where: { $0.id == second.id })?.isFavorite == true)

        try FileManager.default.removeItem(at: persistence.databaseURL)
        try FileManager.default.createDirectory(at: persistence.databaseURL, withIntermediateDirectories: false)
        store.toggleFavorite(first)
        #expect(store.favoriteCount == 1)
        for _ in 0..<100 {
            if store.alertMessage?.contains("收藏状态保存失败") == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.alertMessage?.contains("收藏状态保存失败") == true)
        #expect(store.sound(id: first.id)?.isFavorite == true)
        #expect(store.favoriteCount == 2)
        #expect(store.favoriteRevision == 3)
        #expect(store.lastFavoriteChangedIDs == [first.id])
        #expect(store.libraryRevision == initialLibraryRevision)
    }

    @Test @MainActor func batchSelectAllUsesCompressedExceptions() {
        let first = UUID()
        let second = UUID()
        let selection = SoundBatchSelection()

        selection.selectAll()
        #expect(selection.selectsAll)
        #expect(selection.selectedIDs.isEmpty)
        #expect(selection.selectedCount(total: 36_487) == 36_487)
        #expect(selection.contains(first))

        selection.toggle(first)
        #expect(!selection.contains(first))
        #expect(selection.contains(second))
        #expect(selection.excludedIDs == [first])
        #expect(selection.selectedCount(total: 36_487) == 36_486)

        selection.clear()
        selection.selectOnly(second)
        #expect(!selection.selectsAll)
        #expect(selection.selectedIDs == [second])
        #expect(selection.selectedCount(total: 36_487) == 1)
    }

    @Test @MainActor func indexedSoundCountLoadsAndTracksStructuralRemoval() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let persistence = LibraryPersistence(baseDirectory: directory)
        let packID = UUID()
        try persistence.save([
            SoundPack(
                id: packID,
                name: "计数测试",
                rootPath: "/只读测试/计数测试",
                items: [
                    makeItem(packID: packID, path: "一.wav"),
                    makeItem(packID: packID, path: "二.wav"),
                    makeItem(packID: packID, path: "子目录/三.wav")
                ]
            )
        ])

        let store = LibraryStore(persistence: persistence)
        #expect(store.soundCount == 3)
        store.removeSelectedPack()
        #expect(store.soundCount == 0)
    }

    @Test func backgroundResultSnapshotMatchesFolderDescendantsAndSearch() throws {
        let packID = UUID()
        let pack = SoundPack(
            id: packID,
            name: "片场声音",
            rootPath: "/只读测试/片场声音",
            items: [
                makeItem(packID: packID, path: "环境/城市/夜晚.wav"),
                makeItem(packID: packID, path: "环境/自然/雨声.wav"),
                makeItem(packID: packID, path: "转场/呼啸.wav")
            ]
        )
        func request(query: String) -> SoundResultsRequest {
            SoundResultsRequest(
                libraryRevision: 1,
                favoriteRevision: 0,
                metadataRevision: 1,
                classificationRevision: 0,
                visibilityRevision: 0,
                scope: .folder(packID: packID, path: "环境"),
                sortMode: .name,
                selectedFormat: nil,
                minimumDuration: nil,
                maximumDuration: nil,
                favoritesOnly: false,
                showsHiddenSounds: false,
                query: query,
                searchMode: .literal,
                aiSearchEnabled: false
            )
        }

        let folderSnapshot = try SoundResultsSnapshot.make(
            packs: [pack],
            request: request(query: "")
        )
        #expect(folderSnapshot.sounds.count == 2)

        let searchSnapshot = try SoundResultsSnapshot.make(
            packs: [pack],
            request: request(query: "雨声")
        )
        #expect(searchSnapshot.sounds.map(\.fileName) == ["雨声.wav"])
    }

    @Test func workspaceStateRoundTripsSmartLeafAndSortMode() throws {
        let selectedSoundID = UUID()
        let scope = LibraryScope.smartLeaf(
            SmartLeafCollection(detail: .transitionRiser, durationBand: .veryShort)
        )
        let state = LibraryWorkspaceState(
            scope: scope,
            sortMode: .duration,
            selectedSoundID: selectedSoundID
        )
        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(LibraryWorkspaceState.self, from: encoded)

        #expect(decoded == state)
        #expect(decoded.schemaVersion == LibraryWorkspaceState.currentSchemaVersion)
        #expect(decoded.sortMode == .duration)
        #expect(decoded.selectedSoundID == selectedSoundID)
        #expect(decoded.resolvedScope(in: []) == scope)
    }

    @Test func workspaceStateDecodesBuild58StateWithoutASelection() throws {
        let build58JSON = """
        {"schemaVersion":1,"sortMode":"name","storedScope":{"favorites":{}}}
        """
        let decoded = try JSONDecoder().decode(
            LibraryWorkspaceState.self,
            from: Data(build58JSON.utf8)
        )

        #expect(decoded.selectedSoundID == nil)
        #expect(decoded.sortMode == .name)
        #expect(decoded.resolvedScope(in: []) == .favorites)
    }

    @Test func workspaceStateRestoresExistingPackAndFolderScopes() {
        let packID = UUID()
        let pack = SoundPack(
            id: packID,
            name: "电影拟音",
            rootPath: "/Volumes/Sounds/电影拟音",
            items: [makeItem(packID: packID, path: "环境/城市/夜晚.wav")]
        )

        let packState = LibraryWorkspaceState(scope: .pack(packID), sortMode: .format)
        let folderState = LibraryWorkspaceState(
            scope: .folder(packID: packID, path: "环境"),
            sortMode: .folder
        )

        #expect(packState.resolvedScope(in: [pack]) == .pack(packID))
        #expect(folderState.resolvedScope(in: [pack]) == .folder(packID: packID, path: "环境"))
    }

    @Test func workspaceStateFallsBackWhenPackOrFolderDisappears() {
        let packID = UUID()
        let pack = SoundPack(
            id: packID,
            name: "仍在的音效包",
            rootPath: "/Volumes/Sounds/仍在的音效包",
            items: [makeItem(packID: packID, path: "拟音/脚步.wav")]
        )
        let missingPack = LibraryWorkspaceState(scope: .pack(UUID()), sortMode: .name)
        let missingFolder = LibraryWorkspaceState(
            scope: .folder(packID: packID, path: "已经删除"),
            sortMode: .name
        )

        #expect(missingPack.resolvedScope(in: [pack]) == .all)
        #expect(missingFolder.resolvedScope(in: [pack]) == .all)
    }

    @Test func restoredFolderScopeExpandsOnlyItsOwnAncestors() {
        let selectedPackID = UUID()
        let otherPackID = UUID()
        let scope = LibraryScope.folder(
            packID: selectedPackID,
            path: "拟音/脚步/木地板"
        )

        #expect(scope.shouldExpandFolder(packID: selectedPackID, ancestorPath: "拟音"))
        #expect(scope.shouldExpandFolder(packID: selectedPackID, ancestorPath: "拟音/脚步"))
        #expect(scope.shouldExpandFolder(packID: selectedPackID, ancestorPath: "拟音/脚步/木地板"))
        #expect(!scope.shouldExpandFolder(packID: selectedPackID, ancestorPath: "拟音/门窗"))
        #expect(!scope.shouldExpandFolder(packID: otherPackID, ancestorPath: "拟音"))
    }

    @Test func localAISearchUsesDirectoryEvidenceAndKeepsLiteralHitsAfterFeaturedResults() throws {
        let packID = UUID()
        let aiPick = SoundItem(
            id: UUID(),
            packageID: packID,
            relativePath: "Technology/UI/Notification/clean_ping.wav",
            fileName: "clean_ping.wav",
            folderPath: "Technology/UI/Notification",
            fileExtension: "wav"
        )
        let literalHit = SoundItem(
            id: UUID(),
            packageID: packID,
            relativePath: "Archive/科技 UI 文字命中.wav",
            fileName: "科技 UI 文字命中.wav",
            folderPath: "Archive",
            fileExtension: "wav"
        )
        let matches = LibrarySearchMatches(
            ids: [aiPick.id, literalHit.id],
            literalIDs: [literalHit.id],
            relevanceByID: [aiPick.id: 240, literalHit.id: 1_000],
            semanticRelevanceByID: [aiPick.id: 1.2],
            semanticMatchCount: 1,
            conceptTitles: ["通知提示"]
        )
        let request = SoundResultsRequest(
            libraryRevision: 1,
            favoriteRevision: 0,
            metadataRevision: 0,
            classificationRevision: 0,
            visibilityRevision: 0,
            scope: .smart(.transition),
            sortMode: .name,
            selectedFormat: nil,
            minimumDuration: nil,
            maximumDuration: nil,
            favoritesOnly: false,
            showsHiddenSounds: false,
            query: "科技 UI 提示音",
            searchMode: .hybrid,
            aiSearchEnabled: true
        )

        let snapshot = try SoundResultsSnapshot.make(
            packs: [SoundPack(id: packID, name: "测试", rootPath: "/只读测试", items: [aiPick, literalHit])],
            request: request,
            queryMatches: matches,
            aiExpandedQuery: "科技 UI 通知提示"
        )

        #expect(snapshot.sounds.map(\.id) == [aiPick.id, literalHit.id])
        #expect(snapshot.aiFeaturedIDs == [aiPick.id])
    }

    @Test func localAISearchKeepsOriginalExactHitsAfterTheAIRecommendationShelf() throws {
        let packID = UUID()
        let aiPick = SoundItem(
            id: UUID(),
            packageID: packID,
            relativePath: "Music/Traditional/guqin_atmosphere.wav",
            fileName: "guqin_atmosphere.wav",
            folderPath: "Music/Traditional",
            fileExtension: "wav"
        )
        let exactHit = SoundItem(
            id: UUID(),
            packageID: packID,
            relativePath: "Music/古风歌曲_月光.mp3",
            fileName: "古风歌曲_月光.mp3",
            folderPath: "Music",
            fileExtension: "mp3"
        )
        let matches = LibrarySearchMatches(
            ids: [aiPick.id],
            relevanceByID: [aiPick.id: 240],
            semanticRelevanceByID: [aiPick.id: 1.2],
            semanticMatchCount: 1,
            conceptTitles: ["古风"]
        )
        let request = SoundResultsRequest(
            libraryRevision: 1,
            favoriteRevision: 0,
            metadataRevision: 0,
            classificationRevision: 0,
            visibilityRevision: 0,
            scope: .all,
            sortMode: .name,
            selectedFormat: nil,
            minimumDuration: nil,
            maximumDuration: nil,
            favoritesOnly: false,
            showsHiddenSounds: false,
            query: "古风歌曲",
            searchMode: .hybrid,
            aiSearchEnabled: true
        )

        let snapshot = try SoundResultsSnapshot.make(
            packs: [SoundPack(id: packID, name: "测试", rootPath: "/只读测试", items: [aiPick, exactHit])],
            request: request,
            queryMatches: matches,
            aiExpandedQuery: "古风歌曲",
            originalLiteralIDs: [exactHit.id]
        )

        #expect(snapshot.sounds.map(\.id) == [aiPick.id, exactHit.id])
        #expect(snapshot.aiFeaturedIDs == [aiPick.id])
        #expect(snapshot.exactSearchIDs == [exactHit.id])
    }

    @Test func localAIKeepsCompactCJKLibraryLabelsExact() async throws {
        let plan = try await LocalAISearchPlanner.plan(for: "古风歌曲")
        #expect(plan.keywords.isEmpty)
    }

    @Test func creatorSearchUnderstandsCafeDateAsACombinedScene() {
        let query = SoundSemanticEngine.query("咖啡馆约会")
        #expect(query.concepts["q:cafe"] != nil)
        #expect(query.concepts["q:romantic"] != nil)
        #expect(query.concepts["q:soft"] != nil)
        #expect(query.concepts["detail:\(SmartSubcollection.ambienceCrowd.rawValue)"] != nil)
        #expect(query.conceptTitles.contains("咖啡馆"))
        #expect(query.conceptTitles.contains("咖啡馆约会"))
        let applause = makeItem(packID: UUID(), path: "人群/大厅鼓掌.wav")
        let cafe = makeItem(packID: UUID(), path: "环境/Cafe_Crowd_Conversation.wav")
        #expect(SoundSemanticEngine.profile(for: applause).concepts["q:cafe"] == nil)
        #expect(SoundSemanticEngine.profile(for: cafe).concepts["q:cafe"] != nil)
    }

    @Test func aiSearchEvaluationSetCoversCreatorLanguageAndTargetDuration() {
        #expect(AISearchEvaluationSet.cases.count >= 100)
        let query = SoundSemanticEngine.query("产品结尾落版，一秒左右")
        #expect(query.intent.targetDuration == 1)
        #expect(query.intent.minimumDuration == 0.5)
        #expect(query.intent.maximumDuration == 1.5)
        let negative = SoundSemanticEngine.query("远处雷声，不要雨")
        #expect(negative.intent.excludedTerms.contains("雨"))
        #expect(AISearchIntentParser.searchAliases(for: "雨").contains("rain"))
        let thunder = SoundItem(
            packageID: UUID(),
            relativePath: "环境/雷声/雷声_01.wav",
            fileName: "雷声_01.wav",
            folderPath: "环境/雷声",
            fileExtension: "wav"
        )
        let gunshot = SoundItem(
            packageID: UUID(),
            relativePath: "远处/远距离射击.wav",
            fileName: "远距离射击.wav",
            folderPath: "远处",
            fileExtension: "wav"
        )
        #expect(LocalAISearchRanking.hasDirectSoundTypeEvidence(thunder, intent: negative.intent))
        #expect(!LocalAISearchRanking.hasDirectSoundTypeEvidence(gunshot, intent: negative.intent))
    }

    @Test func creatorSearchBridgesDoorOpeningAndAcousticIntensity() {
        let intent = AISearchIntentParser.parse("木头门被推开，短促，强烈")
        #expect(intent.soundTypes.contains(where: { $0.term == "推开" }))
        #expect(intent.dynamics.contains(where: { $0.term == "短促" }))
        #expect(intent.intensity ?? 0 > 1.2)
        #expect(AISearchIntentParser.searchAliases(for: "推开").contains("door_open"))
        #expect(AISearchIntentParser.searchAliases(for: "科技").contains("electronic"))

        let lowImpact = AcousticFingerprint(
            spectralBands: Array(repeating: 0.08, count: 12), spectralCentroid: 0.35,
            spectralRolloff: 0.5, spectralFlatness: 0.2, zeroCrossingRate: 0.1,
            crestFactor: 0.5, transientDensity: 0.18, dynamicRange: 0.3, analyzedDuration: 1
        )
        let hardImpact = AcousticFingerprint(
            spectralBands: Array(repeating: 0.08, count: 12), spectralCentroid: 0.35,
            spectralRolloff: 0.5, spectralFlatness: 0.2, zeroCrossingRate: 0.1,
            crestFactor: 0.5, transientDensity: 0.82, dynamicRange: 0.7, analyzedDuration: 1
        )
        let queryIntent = AISearchIntentParser.parse("短促，强烈")
        let lowScore = LocalAISearchRanking.acousticScoreForTesting(lowImpact, intent: queryIntent)
        let hardScore = LocalAISearchRanking.acousticScoreForTesting(hardImpact, intent: queryIntent)
        #expect(hardScore > lowScore)

        let fly = makeItem(packID: UUID(), path: "自然/苍蝇_上升_风铃.wav")
        let tech = makeItem(packID: UUID(), path: "科技/电子上升.wav")
        let techIntent = AISearchIntentParser.parse("科技上升，3 秒内")
        #expect(!LocalAISearchRanking.hasDirectSoundTypeEvidence(fly, intent: techIntent))
        #expect(LocalAISearchRanking.hasDirectSoundTypeEvidence(tech, intent: techIntent))
    }

    @Test func aiSearchIntentSurfacesOnlyRealConflicts() {
        let normal = AISearchIntentParser.parse("远处雷声，不要雨")
        #expect(normal.conflicts.isEmpty)

        let repeated = AISearchIntentParser.parse("雷声，不要雷声")
        #expect(repeated.conflicts.contains("同时要求与排除“雷声”"))

        let duration = AISearchIntentParser.parse("至少 5 秒，不超过 3 秒")
        #expect(duration.conflicts.contains("时长条件互相冲突"))

        let intensity = AISearchIntentParser.parse("克制但强烈的冲击")
        #expect(intensity.conflicts.contains("同时包含克制与强烈"))
    }

    @Test func directPathMatchIDsScansPacksWithoutChangingEvidence() throws {
        let packID = UUID()
        let exact = SoundItem(
            packageID: packID,
            relativePath: "门/木头门.wav",
            fileName: "木头门.wav",
            folderPath: "门",
            fileExtension: "wav"
        )
        let related = SoundItem(
            packageID: packID,
            relativePath: "门/开门关门.wav",
            fileName: "开门关门.wav",
            folderPath: "门",
            fileExtension: "wav"
        )
        let ids = try LocalAISearchRanking.directPathMatchIDs(
            in: [SoundPack(id: packID, name: "测试", rootPath: "/tmp", items: [exact, related])],
            query: "木头门"
        )
        #expect(ids == [exact.id])
    }

    private func makeItem(packID: UUID, path: String) -> SoundItem {
        SoundItem(
            packageID: packID,
            relativePath: path,
            fileName: (path as NSString).lastPathComponent,
            folderPath: LibraryScanner.folderPath(forRelativePath: path),
            fileExtension: (path as NSString).pathExtension
        )
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Int, Int)] = []

    func append(completed: Int, total: Int) {
        lock.lock()
        values.append((completed, total))
        lock.unlock()
    }

    func snapshot() -> [(Int, Int)] {
        lock.lock()
        let result = values
        lock.unlock()
        return result
    }
}
