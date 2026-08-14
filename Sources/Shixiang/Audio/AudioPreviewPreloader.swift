import Foundation
@preconcurrency import AVFoundation

struct AudioPreviewCandidate: Sendable {
    let url: URL
    let estimatedResidentBytes: Int64

    init(url: URL, item: SoundItem) {
        self.url = url
        estimatedResidentBytes = AudioPreviewPreloadPolicy.estimatedResidentBytes(for: item)
    }

    init(url: URL, estimatedResidentBytes: Int64) {
        self.url = url
        self.estimatedResidentBytes = max(0, estimatedResidentBytes)
    }
}

enum AudioPreviewPreloadPolicy {
    static let maximumEstimatedResidentBytes: Int64 = 48 * 1_024 * 1_024
    static let defaultUnknownCost: Int64 = 1 * 1_024 * 1_024

    static func estimatedResidentBytes(for item: SoundItem) -> Int64 {
        estimatedResidentBytes(
            duration: item.duration,
            sampleRate: item.sampleRate,
            channelCount: item.channelCount,
            sourceFileSize: item.sourceFileSize
        )
    }

    static func estimatedResidentBytes(
        duration: Double,
        sampleRate: Double?,
        channelCount: Int?,
        sourceFileSize: Int64?
    ) -> Int64 {
        let safeDuration = duration.isFinite ? min(max(duration, 0), 3_600) : 0
        let safeSampleRate = min(max(sampleRate ?? 48_000, 8_000), 192_000)
        let safeChannelCount = min(max(channelCount ?? 2, 1), 8)
        let decodedBytes = safeDuration * safeSampleRate * Double(safeChannelCount) * 4
        let decodedEstimate = Int64(min(decodedBytes, Double(Int64.max)))
        return max(defaultUnknownCost, max(sourceFileSize ?? 0, decodedEstimate))
    }

    static func shouldPreload(estimatedResidentBytes: Int64) -> Bool {
        estimatedResidentBytes > 0
            && estimatedResidentBytes <= maximumEstimatedResidentBytes
    }
}

/// Keeps a very small set of visible sounds decoded and ready to start.
///
/// The cache owns prepared `AVAudioPlayer` instances rather than audio buffers. This keeps
/// memory bounded for large libraries while avoiding the decoder-open hitch between clicks.
/// Source files remain read-only and players are discarded whenever the library changes.
final class AudioPreviewPreloader: @unchecked Sendable {
    static let shared = AudioPreviewPreloader()

    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "com.jacksun.shixiang.audio-preloader",
        qos: .userInitiated
    )
    private let capacity = 12
    /// Keep the decoder queue bounded as well as the resident-player cache. A fast fling can
    /// create hundreds of visible-row tasks; allowing all of them onto the serial queue means
    /// the user still pays the decoder-open cost long after those rows left the viewport.
    private let maximumPendingRequests = 18
    private var players: [String: CachedPlayer] = [:]
    private var recency: [String] = []
    private var scheduled: Set<String> = []
    private var pendingTokens: [String: UInt64] = [:]
    private var pendingRequests: [PendingRequest] = []
    private var workerActive = false
    private var nextToken: UInt64 = 0
    private var generation: UInt64 = 0
    private var estimatedResidentBytes: Int64 = 0
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    private struct CachedPlayer {
        let player: AVAudioPlayer
        let estimatedResidentBytes: Int64
    }

    private struct PendingRequest {
        enum Kind {
            case preload(URL)
            case store(AVAudioPlayer)
        }

        let key: String
        let token: UInt64
        let generation: UInt64
        let kind: Kind
        let estimatedResidentBytes: Int64
    }

    init() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.clear()
        }
        source.resume()
        memoryPressureSource = source
    }

    deinit {
        memoryPressureSource?.cancel()
    }

    /// Read-only diagnostic used by tests and health instrumentation. It intentionally exposes
    /// only the number of pending requests, never the source URLs or players.
    var pendingRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingRequests.count
    }

    var preloadedPlayerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return players.count
    }

    var estimatedPreloadedBytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return estimatedResidentBytes
    }

    func preload(urls: [URL]) {
        preload(candidates: urls.map {
            AudioPreviewCandidate(
                url: $0,
                estimatedResidentBytes: AudioPreviewPreloadPolicy.defaultUnknownCost
            )
        })
    }

    func preload(candidates: [AudioPreviewCandidate]) {
        var shouldStartWorker = false
        lock.lock()
        for candidate in candidates where AudioPreviewPreloadPolicy.shouldPreload(
            estimatedResidentBytes: candidate.estimatedResidentBytes
        ) {
            let normalizedURL = candidate.url.standardizedFileURL
            let key = normalizedURL.path

            let shouldSchedule = players[key] == nil && !scheduled.contains(key)
            guard shouldSchedule else { continue }

            nextToken &+= 1
            let token = nextToken
            pendingTokens[key] = token
            scheduled.insert(key)
            pendingRequests.append(
                PendingRequest(
                    key: key,
                    token: token,
                    generation: generation,
                    kind: .preload(normalizedURL),
                    estimatedResidentBytes: candidate.estimatedResidentBytes
                )
            )
            trimPendingLocked()
        }
        shouldStartWorker = startWorkerIfNeededLocked()
        lock.unlock()

        if shouldStartWorker {
            queue.async { [weak self] in
                self?.drainPendingRequests()
            }
        }
    }

    /// Transfers ownership to the live transport. A consumed player is no longer cached.
    func take(url: URL) -> AVAudioPlayer? {
        let key = url.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        recency.removeAll { $0 == key }
        guard let cached = players.removeValue(forKey: key) else { return nil }
        estimatedResidentBytes -= cached.estimatedResidentBytes
        return cached.player
    }

    /// Makes the just-stopped sound cheap to revisit with the up/down keys.
    func store(
        _ player: AVAudioPlayer,
        url: URL,
        estimatedResidentBytes: Int64 = AudioPreviewPreloadPolicy.defaultUnknownCost
    ) {
        let key = url.standardizedFileURL.path
        player.delegate = nil
        player.stop()
        player.currentTime = 0

        var shouldStartWorker = false
        lock.lock()
        let storeGeneration = generation
        nextToken &+= 1
        let token = nextToken
        // A store request supersedes any queued preload for the same file. The live transport
        // owns this player now, so preparing an older queued decoder would only waste I/O.
        pendingRequests.removeAll { request in
            guard request.key == key else { return false }
            if pendingTokens[key] == request.token {
                pendingTokens.removeValue(forKey: key)
                scheduled.remove(key)
            }
            return true
        }
        pendingTokens[key] = token
        scheduled.insert(key)
        pendingRequests.append(
            PendingRequest(
                key: key,
                token: token,
                generation: storeGeneration,
                kind: .store(player),
                estimatedResidentBytes: estimatedResidentBytes
            )
        )
        trimPendingLocked()
        shouldStartWorker = startWorkerIfNeededLocked()
        lock.unlock()

        if shouldStartWorker {
            queue.async { [weak self] in
                self?.drainPendingRequests()
            }
        }
    }

    /// Invalidates queued decoder work without evicting already prepared players. This is used
    /// when the visible dataset changes; callers can safely invoke it from the main actor while
    /// old queue blocks are still draining on the private serial queue.
    func cancelPendingPreloads() {
        lock.lock()
        generation &+= 1
        scheduled.removeAll(keepingCapacity: true)
        pendingTokens.removeAll(keepingCapacity: true)
        pendingRequests.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func clear() {
        lock.lock()
        generation &+= 1
        let oldPlayers = players.values.map(\.player)
        players.removeAll(keepingCapacity: true)
        estimatedResidentBytes = 0
        recency.removeAll(keepingCapacity: true)
        scheduled.removeAll(keepingCapacity: true)
        pendingTokens.removeAll(keepingCapacity: true)
        pendingRequests.removeAll(keepingCapacity: true)
        lock.unlock()

        oldPlayers.forEach {
            $0.delegate = nil
            $0.stop()
        }
    }

    private func insertLocked(
        _ player: AVAudioPlayer,
        for key: String,
        estimatedBytes: Int64
    ) {
        guard AudioPreviewPreloadPolicy.shouldPreload(
            estimatedResidentBytes: estimatedBytes
        ) else {
            player.stop()
            return
        }
        recency.removeAll { $0 == key }
        if let replaced = players.removeValue(forKey: key) {
            estimatedResidentBytes -= replaced.estimatedResidentBytes
            replaced.player.stop()
        }
        players[key] = CachedPlayer(
            player: player,
            estimatedResidentBytes: estimatedBytes
        )
        estimatedResidentBytes += estimatedBytes
        recency.append(key)

        while recency.count > capacity
            || estimatedResidentBytes > AudioPreviewPreloadPolicy.maximumEstimatedResidentBytes {
            let evictedKey = recency.removeFirst()
            if let evicted = players.removeValue(forKey: evictedKey) {
                estimatedResidentBytes -= evicted.estimatedResidentBytes
                evicted.player.delegate = nil
                evicted.player.stop()
            }
        }
    }

    private func startWorkerIfNeededLocked() -> Bool {
        guard !workerActive, !pendingRequests.isEmpty else { return false }
        workerActive = true
        return true
    }

    private func drainPendingRequests() {
        while true {
            lock.lock()
            guard !pendingRequests.isEmpty else {
                workerActive = false
                lock.unlock()
                return
            }
            let request = pendingRequests.removeFirst()
            let stillCurrent = generation == request.generation
                && pendingTokens[request.key] == request.token
            lock.unlock()

            guard stillCurrent else { continue }
            switch request.kind {
            case let .preload(url):
                preparePreload(url: url, key: request.key, request: request)
            case let .store(player):
                prepareStoredPlayer(player, key: request.key, request: request)
            }
        }
    }

    private func preparePreload(url: URL, key: String, request: PendingRequest) {
        lock.lock()
        let stillCurrent = generation == request.generation
            && pendingTokens[key] == request.token
        lock.unlock()
        guard stillCurrent else { return }

        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        let preparedPlayer: AVAudioPlayer?
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            preparedPlayer = player
        } catch {
            preparedPlayer = nil
        }
        finish(request, player: preparedPlayer)
    }

    private func prepareStoredPlayer(_ player: AVAudioPlayer, key: String, request: PendingRequest) {
        lock.lock()
        let stillCurrent = generation == request.generation
            && pendingTokens[key] == request.token
        lock.unlock()
        guard stillCurrent else { return }

        player.prepareToPlay()
        finish(request, player: player)
    }

    private func finish(_ request: PendingRequest, player: AVAudioPlayer?) {
        lock.lock()
        let isCurrent = generation == request.generation
            && pendingTokens[request.key] == request.token
        if isCurrent {
            scheduled.remove(request.key)
            pendingTokens.removeValue(forKey: request.key)
            if let player {
                insertLocked(
                    player,
                    for: request.key,
                    estimatedBytes: request.estimatedResidentBytes
                )
            }
        }
        lock.unlock()

        if !isCurrent {
            player?.stop()
        }
    }

    /// Drops the oldest not-yet-started requests so a fling can never leave an unbounded tail of
    /// decoder work. The queued closures remain cheap no-ops because their token no longer
    /// matches when they eventually reach the serial queue.
    private func trimPendingLocked() {
        while pendingRequests.count > maximumPendingRequests {
            let stale = pendingRequests.removeFirst()
            if pendingTokens[stale.key] == stale.token {
                pendingTokens.removeValue(forKey: stale.key)
                scheduled.remove(stale.key)
            }
        }
    }
}
