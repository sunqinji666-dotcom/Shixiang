import XCTest
import UniformTypeIdentifiers
@preconcurrency import AVFoundation
@testable import Shixiang

@MainActor
final class AudioTests: XCTestCase {
    func testPlayerStartsInAStableStoppedState() {
        let player = AudioPlayerController()

        XCTAssertNil(player.currentItem)
        XCTAssertNil(player.currentURL)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.currentTime, 0)
        XCTAssertEqual(player.duration, 0)
        XCTAssertEqual(player.volume, 0.85, accuracy: 0.001)
    }

    func testPlayerBarUsesIndexedDurationBeforeAudioIsLoaded() {
        XCTAssertEqual(
            PlayerBarTiming.displayedDuration(
                clockDuration: 0,
                hasLoadedAudio: false,
                indexedDuration: 6.4
            ),
            6.4
        )
        XCTAssertEqual(
            PlayerBarTiming.displayedDuration(
                clockDuration: 6.25,
                hasLoadedAudio: true,
                indexedDuration: 99
            ),
            6.25
        )
        XCTAssertEqual(
            PlayerBarTiming.displayedDuration(
                clockDuration: 0,
                hasLoadedAudio: false,
                indexedDuration: .infinity
            ),
            0
        )
    }

    func testPlayerBarFollowsPlaybackThenReturnsToStoppedSelection() {
        let selectedID = UUID()
        let loadedID = UUID()

        XCTAssertEqual(
            PlayerBarItemPolicy.displayedItemID(
                selectedItemID: selectedID,
                loadedItemID: loadedID,
                isPlaying: true
            ),
            loadedID
        )
        XCTAssertEqual(
            PlayerBarItemPolicy.displayedItemID(
                selectedItemID: selectedID,
                loadedItemID: loadedID,
                isPlaying: false
            ),
            selectedID
        )
        XCTAssertEqual(
            PlayerBarItemPolicy.displayedItemID(
                selectedItemID: nil,
                loadedItemID: loadedID,
                isPlaying: false
            ),
            loadedID
        )
    }

    func testPlayerBarOnlyShowsPlaybackErrorForItsSound() {
        let failedID = UUID()
        let otherID = UUID()
        let message = "音频解码失败。"

        XCTAssertEqual(
            PlayerBarErrorPolicy.displayedMessage(
                issueItemID: failedID,
                displayedItemID: failedID,
                message: message
            ),
            message
        )
        XCTAssertNil(
            PlayerBarErrorPolicy.displayedMessage(
                issueItemID: failedID,
                displayedItemID: otherID,
                message: message
            )
        )
        XCTAssertNil(
            PlayerBarErrorPolicy.displayedMessage(
                issueItemID: nil,
                displayedItemID: failedID,
                message: message
            )
        )
    }

    func testPlaybackFailureBelongsToAttemptedSound() {
        let player = AudioPlayerController()
        let item = SoundItem(
            packageID: UUID(),
            relativePath: "missing.wav",
            fileName: "missing.wav",
            folderPath: "",
            fileExtension: "wav"
        )
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shixiang-missing-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        player.play(item: item, url: missingURL)

        XCTAssertFalse(player.isPlaying)
        XCTAssertNil(player.currentItem)
        XCTAssertEqual(player.playbackErrorItemID, item.id)
        XCTAssertTrue(player.playbackError?.contains("missing.wav") == true)

        player.clearPlaybackError()
        XCTAssertNil(player.playbackIssue)
    }

    func testVolumeIsClampedToAudioPlayerRange() {
        let player = AudioPlayerController()

        player.volume = 2
        XCTAssertEqual(player.volume, 1)

        player.volume = -0.5
        XCTAssertEqual(player.volume, 0)
    }

    func testLoopModeHasAQuietDefaultAndCanBeEnabled() {
        let player = AudioPlayerController()

        XCTAssertFalse(player.isLooping)
        player.isLooping = true
        XCTAssertTrue(player.isLooping)
    }

    func testPreviewQueuePreservesOrderAndCanBeEdited() {
        let player = AudioPlayerController()
        let packageID = UUID()
        let first = SoundItem(packageID: packageID, relativePath: "one.wav", fileName: "one.wav", folderPath: "", fileExtension: "wav")
        let second = SoundItem(packageID: packageID, relativePath: "two.wav", fileName: "two.wav", folderPath: "", fileExtension: "wav")
        let firstURL = URL(fileURLWithPath: "/tmp/one.wav")
        let secondURL = URL(fileURLWithPath: "/tmp/two.wav")

        player.enqueue(item: first, url: firstURL)
        player.enqueue(item: second, url: secondURL)
        XCTAssertEqual(player.queueItems.map(\.item.id), [first.id, second.id])

        let queuedFirst = try! XCTUnwrap(player.queueItems.first)
        player.removeQueuedItem(queuedFirst)
        XCTAssertEqual(player.queueItems.map(\.item.id), [second.id])
        player.clearQueue()
        XCTAssertTrue(player.queueItems.isEmpty)
    }

    func testFolderMonitorRoutesNestedPackChanges() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shixiang-monitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let packID = UUID()
        let monitor = LibraryFolderMonitor()
        let expectation = expectation(description: "nested folder event routing")
        expectation.assertForOverFulfill = false
        let delivery = OneShotDelivery()
        monitor.start(roots: [packID: root]) { observedPackID, changedPath in
            guard observedPackID == packID,
                  changedPath == root.path || changedPath.hasPrefix(root.path + "/") else { return }
            guard delivery.claim() else { return }
            expectation.fulfill()
        }

        let nested = root.appendingPathComponent("New/Nested/new.wav")
        monitor.receive(paths: [nested.path])
        wait(for: [expectation], timeout: 1)
        monitor.stop()
    }

    func testSegmentLoopStartsClearAndCanBeReset() {
        let player = AudioPlayerController()
        XCTAssertNil(player.loopStart)
        XCTAssertNil(player.loopEnd)
        XCTAssertFalse(player.isSegmentLooping)
        player.clearSegmentLoop()
        XCTAssertFalse(player.isSegmentLooping)
    }

    func testDragProviderPublishesOriginalFileURL() throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shixiang-drag-test")
            .appendingPathExtension("wav")
        try Data().write(to: temporaryURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let provider = SoundDragProvider.itemProvider(for: temporaryURL)

        XCTAssertEqual(provider.suggestedName, temporaryURL.lastPathComponent)
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        XCTAssertTrue(provider.registeredTypeIdentifiers.contains("public.file-url"))
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.wav.identifier))
    }

    func testDragProviderLoadsPublicFileURLDataRepresentation() throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shixiang-file-url-data-test")
            .appendingPathExtension("wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let audioFile = try AVAudioFile(forWriting: temporaryURL, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410)!
        buffer.frameLength = 4_410
        try audioFile.write(from: buffer)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let provider = SoundDragProvider.itemProvider(for: temporaryURL)
        let expectation = expectation(description: "file URL representation loads")
        var loadedURL: URL?
        var loadedError: Error?
        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
            if let data {
                loadedURL = URL(dataRepresentation: data, relativeTo: nil)
            }
            loadedError = error
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        XCTAssertNil(loadedError)
        XCTAssertEqual(loadedURL?.standardizedFileURL, temporaryURL.standardizedFileURL)
    }

    func testFinalCutDeliveryDiagnosticsValidatesAReadableWaveFile() throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shixiang-fcp-diagnostics-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        try autoreleasepool {
            let audioFile = try AVAudioFile(forWriting: temporaryURL, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
            buffer.frameLength = 4_800
            try audioFile.write(from: buffer)
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let report = try FinalCutDeliveryDiagnostics.inspect(url: temporaryURL)

        XCTAssertTrue(
            report.isReady,
            report.checks.filter { $0.state == .failed }.map { "\($0.title): \($0.detail)" }.joined(separator: " | ")
        )
        XCTAssertEqual(report.sampleRate, 48_000, accuracy: 0.1)
        XCTAssertEqual(report.channelCount, 2)
        XCTAssertEqual(report.duration, 0.1, accuracy: 0.001)
        XCTAssertTrue(report.advertisedTypeIdentifiers.contains(UTType.fileURL.identifier))
        XCTAssertTrue(report.advertisedTypeIdentifiers.contains(UTType.wav.identifier))
    }

    func testDeliveryTypeRecognitionUsesTheStableImportAllowlist() {
        XCTAssertTrue(SoundDragProvider.isSupportedAudioExtension("WAV"))
        XCTAssertTrue(SoundDragProvider.isSupportedAudioExtension("flac"))
        XCTAssertFalse(SoundDragProvider.isSupportedAudioExtension("txt"))
    }

    func testTrimmedExportBoxReusesOneTask() async throws {
        let counter = ExportInvocationCounter()
        let expectedURL = URL(fileURLWithPath: "/tmp/shixiang-shared-clip.m4a")
        let box = DragClipExportBox {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(20))
            return expectedURL
        }

        async let first = box.outputURL()
        async let second = box.outputURL()
        let (firstURL, secondURL) = try await (first, second)
        let invocationCount = await counter.value

        XCTAssertEqual(firstURL, expectedURL)
        XCTAssertEqual(secondURL, expectedURL)
        XCTAssertEqual(invocationCount, 1)
    }

    func testDragProviderAdvertisesTrimmedClipWhenABRangeIsSet() throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shixiang-trim-test")
            .appendingPathExtension("wav")
        try Data().write(to: temporaryURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let provider = SoundDragProvider.itemProvider(
            for: temporaryURL,
            timeRange: 0.5...2.5
        )
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.mpeg4Audio.identifier))
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        XCTAssertTrue(provider.registeredTypeIdentifiers.contains("public.file-url"))
        XCTAssertEqual(provider.suggestedName, "shixiang-trim-test-clip.m4a")
    }

    func testTrimmedClipUsesReadableSourceNameForFinalCutImport() {
        let sourceURL = URL(fileURLWithPath: "/tmp/01_基础上升音效:测试?.wav")
        let identifier = UUID(uuidString: "12345678-90AB-CDEF-1234-567890ABCDEF")!

        let fileName = SoundDragProvider.dragClipFileName(
            for: sourceURL,
            identifier: identifier
        )

        XCTAssertEqual(fileName, "01_基础上升音效_测试_-clip-12345678.m4a")
        XCTAssertFalse(fileName.contains(":"))
        XCTAssertFalse(fileName.contains("?"))
    }

    func testDragClipCleanupRemovesOnlyExpiredGeneratedClips() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shixiang-drag-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let oldClip = directory.appendingPathComponent("old.m4a")
        let recentClip = directory.appendingPathComponent("recent.m4a")
        let unrelated = directory.appendingPathComponent("keep.txt")
        try Data([1]).write(to: oldClip)
        try Data([2]).write(to: recentClip)
        try Data([3]).write(to: unrelated)

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-8 * 24 * 60 * 60)],
            ofItemAtPath: oldClip.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-60)],
            ofItemAtPath: recentClip.path
        )

        SoundDragProvider.cleanupExpiredDragClips(in: directory, now: now)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldClip.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentClip.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testDragClipCleanupThrottleDoesNotChangeExplicitCleanup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shixiang-drag-cleanup-throttle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = directory.appendingPathComponent("keep.m4a")
        try Data([1]).write(to: clip)
        SoundDragProvider.cleanupExpiredDragClips(in: directory, now: Date())
        XCTAssertTrue(FileManager.default.fileExists(atPath: clip.path))
    }

    func testWaveformScrubbingMapsAndClampsPointerCoordinates() {
        XCTAssertEqual(WaveformScrubbing.progress(locationX: 50, width: 200), 0.25)
        XCTAssertEqual(WaveformScrubbing.progress(locationX: -10, width: 200), 0)
        XCTAssertEqual(WaveformScrubbing.progress(locationX: 240, width: 200), 1)
        XCTAssertEqual(WaveformScrubbing.progress(locationX: 10, width: 0), 0)
    }

    func testWaveformScrubbingMapsProgressToTime() {
        XCTAssertEqual(WaveformScrubbing.time(progress: 0.25, duration: 120), 30)
        XCTAssertEqual(WaveformScrubbing.time(progress: -1, duration: 120), 0)
        XCTAssertEqual(WaveformScrubbing.time(progress: 2, duration: 120), 120)
        XCTAssertEqual(WaveformScrubbing.time(progress: 0.5, duration: 0), 0)
    }

    func testPreviewPreloaderBoundsAndCancelsPendingDecoderWork() {
        let preloader = AudioPreviewPreloader()
        let urls = (0..<100).map { index in
            URL(fileURLWithPath: "/tmp/shixiang-preload-" + String(index) + ".wav")
        }

        preloader.preload(urls: urls)
        XCTAssertLessThanOrEqual(preloader.pendingRequestCount, 18)

        preloader.cancelPendingPreloads()
        XCTAssertEqual(preloader.pendingRequestCount, 0)
        preloader.clear()
    }

    func testPreviewPreloadPolicyUsesDecodedCostAndRejectsOversizedSounds() {
        let packageID = UUID()
        let oneMinuteStereo = SoundItem(
            packageID: packageID,
            relativePath: "long.wav",
            fileName: "long.wav",
            folderPath: "",
            fileExtension: "wav",
            duration: 60,
            sampleRate: 48_000,
            channelCount: 2,
            sourceFileSize: 2_000_000
        )
        let estimated = AudioPreviewPreloadPolicy.estimatedResidentBytes(for: oneMinuteStereo)
        XCTAssertEqual(estimated, 23_040_000)
        XCTAssertTrue(AudioPreviewPreloadPolicy.shouldPreload(estimatedResidentBytes: estimated))

        let oversized = AudioPreviewPreloadPolicy.maximumEstimatedResidentBytes + 1
        XCTAssertFalse(AudioPreviewPreloadPolicy.shouldPreload(estimatedResidentBytes: oversized))
        let preloader = AudioPreviewPreloader()
        preloader.preload(candidates: [
            AudioPreviewCandidate(
                url: URL(fileURLWithPath: "/tmp/shixiang-oversized.wav"),
                estimatedResidentBytes: oversized
            )
        ])
        XCTAssertEqual(preloader.pendingRequestCount, 0)
        XCTAssertEqual(preloader.preloadedPlayerCount, 0)
    }

    func testPreviewPreloaderEvictsOldPlayersToStayWithinMemoryBudget() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shixiang-preload-budget-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441)!
        buffer.frameLength = 441
        let firstURL = directory.appendingPathComponent("first.wav")
        let secondURL = directory.appendingPathComponent("second.wav")
        for url in [firstURL, secondURL] {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }

        let preloader = AudioPreviewPreloader()
        preloader.store(
            try AVAudioPlayer(contentsOf: firstURL),
            url: firstURL,
            estimatedResidentBytes: 40 * 1_024 * 1_024
        )
        preloader.store(
            try AVAudioPlayer(contentsOf: secondURL),
            url: secondURL,
            estimatedResidentBytes: 20 * 1_024 * 1_024
        )
        for _ in 0..<100 {
            if preloader.pendingRequestCount == 0,
               preloader.estimatedPreloadedBytes == 20 * 1_024 * 1_024 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(preloader.preloadedPlayerCount, 1)
        XCTAssertEqual(preloader.estimatedPreloadedBytes, 20 * 1_024 * 1_024)
        XCTAssertLessThanOrEqual(
            preloader.estimatedPreloadedBytes,
            AudioPreviewPreloadPolicy.maximumEstimatedResidentBytes
        )
        preloader.clear()
    }

    func testWaveformCachePrunesExpiredAndOldestFilesWithinBudget() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shixiang-waveform-prune-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let old = directory.appendingPathComponent("old.waveform")
        let oldestRecent = directory.appendingPathComponent("oldest-recent.waveform")
        let newestRecent = directory.appendingPathComponent("newest-recent.waveform")
        let unrelated = directory.appendingPathComponent("keep.txt")
        try Data(repeating: 1, count: 4).write(to: old)
        try Data(repeating: 2, count: 8).write(to: oldestRecent)
        try Data(repeating: 3, count: 8).write(to: newestRecent)
        try Data(repeating: 4, count: 20).write(to: unrelated)

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-31 * 24 * 60 * 60)],
            ofItemAtPath: old.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-20)],
            ofItemAtPath: oldestRecent.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-10)],
            ofItemAtPath: newestRecent.path
        )

        let report = await WaveformCacheMaintenance.pruneIfNeeded(
            in: directory,
            policy: WaveformCachePolicy(maximumBytes: 8, maximumAge: 30 * 24 * 60 * 60),
            now: now
        )

        XCTAssertEqual(report.scannedFiles, 3)
        XCTAssertEqual(report.removedFiles, 2)
        XCTAssertEqual(report.remainingBytes, 8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldestRecent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newestRecent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }
}

private final class OneShotDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var hasDelivered = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !hasDelivered else { return false }
        hasDelivered = true
        return true
    }
}

private actor ExportInvocationCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
