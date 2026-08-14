import Combine
import Foundation
@preconcurrency import AVFoundation

/// A small, real-time transport meter for the bottom player. It reads AVAudioPlayer's actual
/// channel power data; the held peak falls back gradually so short transients remain visible.
/// Keeping it separate from AudioPlayerController avoids invalidating the whole library view at
/// meter-refresh frequency.
@MainActor
final class PlaybackLevelMeter: ObservableObject {
    private(set) var leftLevel: Float = 0
    private(set) var rightLevel: Float = 0
    private(set) var leftPeak: Float = 0
    private(set) var rightPeak: Float = 0
    private(set) var history: [PlaybackMeterSample] = []
    private(set) var sampleTick: UInt = 0

    /// A cheap live sample that the display-linked player bar can poll while the file's exact
    /// FFT overview is still being prepared. It lets playback react on the first audible buffer
    /// without publishing another high-frequency SwiftUI update stream.
    var currentSample: PlaybackMeterSample {
        PlaybackMeterSample(
            left: leftLevel,
            right: rightLevel,
            peak: max(leftPeak, rightPeak)
        )
    }

    private weak var player: AVAudioPlayer?
    private var timer: Timer?
    private var lastSampleDate: Date?
    private let historyLimit = 144

    func start(for player: AVAudioPlayer) {
        guard self.player !== player || timer == nil else { return }
        stop()
        self.player = player
        player.isMeteringEnabled = true
        sample()
        // The visible spectrum is capped at 30 Hz. Sampling meters four times faster only adds
        // main-run-loop publications around play/stop without producing another visible frame.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sample()
            }
        }
        timer.tolerance = 1.0 / 120.0
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop(reset: Bool = true) {
        timer?.invalidate()
        timer = nil
        player?.isMeteringEnabled = false
        player = nil
        guard reset else { return }
        leftLevel = 0
        rightLevel = 0
        leftPeak = 0
        rightPeak = 0
        history.removeAll(keepingCapacity: true)
        sampleTick = 0
        lastSampleDate = nil
    }

    private func sample() {
        guard let player, player.isPlaying else {
            stop()
            return
        }
        player.updateMeters()
        let channelCount = max(player.numberOfChannels, 1)
        let left = normalizedLevel(player.averagePower(forChannel: 0))
        let leftTransient = normalizedLevel(player.peakPower(forChannel: 0))
        let rightIndex = channelCount > 1 ? 1 : 0
        let right = normalizedLevel(player.averagePower(forChannel: rightIndex))
        let rightTransient = normalizedLevel(player.peakPower(forChannel: rightIndex))

        let now = Date()
        let deltaTime = min(max(now.timeIntervalSince(lastSampleDate ?? now), 1.0 / 30.0), 0.1)
        lastSampleDate = now

        // Fast attack keeps transients truthful. A gentler release removes single-frame jitter
        // without making the display visibly trail the sound.
        leftLevel = smoothedLevel(previous: leftLevel, incoming: left)
        rightLevel = smoothedLevel(previous: rightLevel, incoming: right)
        let peakDecay = Float(pow(0.25, deltaTime))
        leftPeak = max(leftTransient, leftPeak * peakDecay)
        rightPeak = max(rightTransient, rightPeak * peakDecay)

        history.append(
            PlaybackMeterSample(
                left: leftLevel,
                right: rightLevel,
                peak: max(leftPeak, rightPeak)
            )
        )
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
        sampleTick &+= 1
    }

    private func smoothedLevel(previous: Float, incoming: Float) -> Float {
        let response: Float = incoming >= previous ? 0.78 : 0.30
        return previous + (incoming - previous) * response
    }

    private func normalizedLevel(_ decibels: Float) -> Float {
        guard decibels.isFinite else { return 0 }
        return min(max((decibels + 60) / 60, 0), 1)
    }
}

struct PlaybackMeterSample: Equatable, Sendable {
    let left: Float
    let right: Float
    let peak: Float

    var energy: Float {
        (left + right) * 0.5
    }
}

/// Playback time is anchored once when transport state changes, then interpolated by
/// display-linked SwiftUI timelines. No timer publishes into the view tree while audio plays.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published fileprivate(set) var currentTime: TimeInterval = 0
    @Published fileprivate(set) var duration: TimeInterval = 0
    @Published fileprivate(set) var isAdvancing = false

    private var anchorTime: TimeInterval = 0
    private var anchorDate = Date()
    private var repeats = false

    var progress: Double {
        progress(at: Date())
    }

    func displayedTime(at date: Date) -> TimeInterval {
        guard duration > 0 else { return 0 }
        guard isAdvancing else { return min(max(currentTime, 0), duration) }

        let elapsed = max(0, date.timeIntervalSince(anchorDate))
        let advancedTime = anchorTime + elapsed
        if repeats {
            return advancedTime.truncatingRemainder(dividingBy: duration)
        }
        return min(max(advancedTime, 0), duration)
    }

    func progress(at date: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(displayedTime(at: date) / duration, 0), 1)
    }

    func update(
        time: TimeInterval,
        duration: TimeInterval? = nil,
        advancing: Bool = false,
        repeats: Bool? = nil,
        at date: Date = Date()
    ) {
        currentTime = max(0, time)
        if let duration {
            self.duration = max(0, duration)
        }
        if let repeats {
            self.repeats = repeats
        }
        anchorTime = currentTime
        anchorDate = date
        isAdvancing = advancing
    }

    func reset() {
        currentTime = 0
        duration = 0
        anchorTime = 0
        anchorDate = Date()
        repeats = false
        isAdvancing = false
    }
}

/// Owns the single preview player used by the local sound library.
///
/// The controller always reads the original source. A correctly suffixed symbolic alias is used
/// only when a legacy file's extension disagrees with its verified WAVE header.
@MainActor
final class AudioPlayerController: NSObject, ObservableObject {
    @Published private(set) var currentItem: SoundItem?
    @Published private(set) var currentURL: URL?
    @Published private(set) var isPlaying = false
    @Published private(set) var playbackIssue: AudioPlaybackIssue?
    @Published private(set) var queueItems: [PreviewQueueItem] = []
    @Published private(set) var loopStart: TimeInterval?
    @Published private(set) var loopEnd: TimeInterval?
    @Published var isSegmentLooping = false {
        didSet {
            if let player, player.isPlaying {
                scheduleCompletionGuard(for: player)
            }
        }
    }
    @Published var isLooping = false {
        didSet {
            player?.numberOfLoops = isLooping ? -1 : 0
            if let player {
                clock.update(
                    time: player.currentTime,
                    duration: player.duration,
                    advancing: player.isPlaying,
                    repeats: isLooping
                )
                if player.isPlaying {
                    scheduleCompletionGuard(for: player)
                }
            }
        }
    }

    /// Volume changes can arrive at pointer frequency. Keeping this value non-published
    /// prevents a volume drag from invalidating the player card and every visible sound row.
    private var storedVolume: Float = 0.85
    private var playbackVolumeMultiplier: Float = 1
    var volume: Float {
        get { storedVolume }
        set {
            let clamped = min(max(newValue, 0), 1)
            storedVolume = clamped
            player?.volume = min(1, clamped * playbackVolumeMultiplier)
        }
    }

    let clock = PlaybackClock()
    let levelMeter = PlaybackLevelMeter()

    var currentItemID: UUID? { currentItem?.id }
    var playbackError: String? { playbackIssue?.message }
    var playbackErrorItemID: UUID? { playbackIssue?.itemID }
    /// The display clock is authoritative. Some AVAudioPlayer formats briefly continue to
    /// report `duration` after their completion callback, which otherwise leaves a stale
    /// full progress bar even though the row has already returned to its idle appearance.
    var currentTime: TimeInterval { clock.displayedTime(at: Date()) }
    var duration: TimeInterval { clock.duration }
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    private var player: AVAudioPlayer?
    private var currentPlaybackURL: URL?
    private var isAccessingSecurityScopedURL = false
    private var completionGuardTask: Task<Void, Never>?

    override init() {
        super.init()
    }

    /// Plays a sound, or pauses it when the same sound is already playing.
    func togglePlayback(item: SoundItem, url: URL) {
        if currentItem?.id == item.id, currentURL == url {
            togglePlayback()
        } else {
            play(item: item, url: url)
        }
    }

    /// Toggles the already loaded sound without changing the library selection.
    func togglePlayback() {
        guard let player else { return }
        if player.isPlaying {
            pause()
        } else {
            resume()
        }
    }

    func play(item: SoundItem, url: URL) {
        play(item: item, url: url, startingProgress: 0, volumeMultiplier: 1)
    }

    /// Starts a newly selected sound at an exact normalized position. This avoids the
    /// audible "play from zero, then seek" flash when a waveform is clicked.
    func play(item: SoundItem, url: URL, startingProgress: Double) {
        play(item: item, url: url, startingProgress: startingProgress, volumeMultiplier: 1)
    }

    /// `volumeMultiplier` is used by rapid A/B comparison to attenuate louder candidates.
    /// Normal playback always calls this with 1, so comparison gain never leaks into the
    /// regular library transport.
    func play(
        item: SoundItem,
        url: URL,
        startingProgress: Double = 0,
        volumeMultiplier: Float
    ) {
        releaseCurrentFileAccess()
        clearSegmentLoop()
        playbackIssue = nil

        let accessed = url.startAccessingSecurityScopedResource()
        do {
            let playbackURL = AudioPlaybackCompatibility.resolvedURL(for: url)
            let newPlayer = try AudioPreviewPreloader.shared.take(url: playbackURL)
                ?? AVAudioPlayer(contentsOf: playbackURL)
            newPlayer.delegate = self
            newPlayer.isMeteringEnabled = true
            playbackVolumeMultiplier = min(max(volumeMultiplier, 0.05), 1)
            newPlayer.volume = min(1, volume * playbackVolumeMultiplier)
            newPlayer.numberOfLoops = isLooping ? -1 : 0
            newPlayer.prepareToPlay()

            let safeProgress = min(max(startingProgress, 0), 1)
            newPlayer.currentTime = newPlayer.duration * safeProgress

            player = newPlayer
            currentItem = item
            currentURL = url
            currentPlaybackURL = playbackURL
            isAccessingSecurityScopedURL = accessed
            clock.update(
                time: newPlayer.currentTime,
                duration: newPlayer.duration,
                repeats: isLooping
            )

            guard newPlayer.play() else {
                throw AudioPlaybackError.couldNotStart
            }
            isPlaying = true
            levelMeter.start(for: newPlayer)
            clock.update(
                time: newPlayer.currentTime,
                duration: newPlayer.duration,
                advancing: true,
                repeats: isLooping
            )
            scheduleCompletionGuard(for: newPlayer)
        } catch {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
            player = nil
            currentItem = nil
            currentURL = nil
            currentPlaybackURL = nil
            isAccessingSecurityScopedURL = false
            clock.reset()
            isPlaying = false
            playbackIssue = AudioPlaybackIssue(
                itemID: item.id,
                message: "无法播放“\(item.fileName)”：\(error.localizedDescription)"
            )
        }
    }

    func resetComparisonVolume() {
        playbackVolumeMultiplier = 1
        player?.volume = volume
    }

    func pause() {
        guard let player, player.isPlaying else { return }
        completionGuardTask?.cancel()
        player.pause()
        levelMeter.stop()
        clock.update(
            time: player.currentTime,
            duration: player.duration,
            repeats: isLooping
        )
        isPlaying = false
    }

    private func resume() {
        guard let player else { return }
        playbackIssue = nil
        if player.currentTime >= player.duration {
            player.currentTime = 0
        }
        guard player.play() else {
            playbackIssue = currentItemID.map {
                AudioPlaybackIssue(
                    itemID: $0,
                    message: AudioPlaybackError.couldNotStart.localizedDescription
                )
            }
            return
        }
        isPlaying = true
        levelMeter.start(for: player)
        clock.update(
            time: player.currentTime,
            duration: player.duration,
            advancing: true,
            repeats: isLooping
        )
        scheduleCompletionGuard(for: player)
    }

    /// Stops preview playback but keeps the current sound loaded, ready to play again.
    func stop() {
        completionGuardTask?.cancel()
        player?.stop()
        levelMeter.stop()
        player?.currentTime = 0
        clock.update(time: 0, duration: player?.duration, repeats: isLooping)
        isPlaying = false
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        let safeTime = min(max(time, 0), player.duration)
        player.currentTime = safeTime
        clock.update(
            time: safeTime,
            duration: player.duration,
            advancing: player.isPlaying,
            repeats: isLooping
        )
        if player.isPlaying {
            scheduleCompletionGuard(for: player)
        }
    }

    /// Commits a completed waveform drag. During the drag the player is paused and the
    /// UI moves locally; only this final call touches the decoder, preventing repeated
    /// fragments and keeping pointer tracking smooth.
    func finishScrubbing(to time: TimeInterval, resumePlayback: Bool) {
        seek(to: time)
        guard resumePlayback, time < duration else { return }
        resume()
    }

    func setLoopStart() {
        guard duration > 0 else { return }
        let start = min(max(currentTime, 0), duration)
        loopStart = start
        if let end = loopEnd, end <= start {
            loopEnd = nil
            isSegmentLooping = false
        }
        if let player, player.isPlaying {
            scheduleCompletionGuard(for: player)
        }
    }

    func setLoopEnd() {
        guard duration > 0, let start = loopStart else { return }
        let end = min(max(currentTime, 0), duration)
        guard end > start + 0.05 else { return }
        loopEnd = end
        isSegmentLooping = true
        if let player, player.isPlaying {
            scheduleCompletionGuard(for: player)
        }
    }

    func clearSegmentLoop() {
        loopStart = nil
        loopEnd = nil
        isSegmentLooping = false
    }

    func enqueue(item: SoundItem, url: URL) {
        queueItems.append(PreviewQueueItem(item: item, url: url))
    }

    func removeQueuedItem(_ queuedItem: PreviewQueueItem) {
        queueItems.removeAll { $0.id == queuedItem.id }
    }

    func clearQueue() {
        queueItems.removeAll()
    }

    /// Jumps by a signed number of seconds. Negative values move backwards.
    func skip(seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    func skip(by seconds: TimeInterval) {
        skip(seconds: seconds)
    }

    func skipBackward(seconds: TimeInterval = 5) {
        skip(seconds: -abs(seconds))
    }

    func skipForward(seconds: TimeInterval = 5) {
        skip(seconds: abs(seconds))
    }

    private func finishPlayback() {
        completionGuardTask?.cancel()
        if let next = queueItems.first {
            queueItems.removeFirst()
            releaseCurrentFileAccess()
            play(item: next.item, url: next.url)
            return
        }
        player?.stop()
        levelMeter.stop()
        player?.currentTime = 0
        player?.prepareToPlay()
        isPlaying = false
        clock.update(time: 0, duration: clock.duration, repeats: isLooping)
    }

    private func scheduleCompletionGuard(for observedPlayer: AVAudioPlayer) {
        completionGuardTask?.cancel()
        let segmentEnd = isSegmentLooping ? loopEnd : nil
        guard segmentEnd != nil || !isLooping else { return }
        let targetEnd = segmentEnd ?? observedPlayer.duration
        let remaining = max(0, targetEnd - observedPlayer.currentTime)
        completionGuardTask = Task { [weak self, weak observedPlayer] in
            try? await Task.sleep(for: .seconds(remaining + 0.12))
            guard !Task.isCancelled,
                  let self,
                  let observedPlayer,
                  observedPlayer === self.player else { return }

            if let segmentEnd = self.isSegmentLooping ? self.loopEnd : nil,
               observedPlayer.currentTime >= segmentEnd - 0.08 || self.clock.currentTime >= segmentEnd - 0.08 {
                self.restartSegment(on: observedPlayer)
                return
            }
            guard !self.isLooping else { return }

            let reachedEnd = observedPlayer.currentTime >= observedPlayer.duration - 0.08
                || self.clock.progress(at: Date()) >= 0.999
            if reachedEnd && !observedPlayer.isPlaying {
                self.finishPlayback()
            }
        }
    }

    private func restartSegment(on observedPlayer: AVAudioPlayer) {
        guard let start = loopStart, let end = loopEnd, end > start else {
            isSegmentLooping = false
            return
        }
        observedPlayer.currentTime = min(max(start, 0), observedPlayer.duration)
        guard observedPlayer.play() else {
            isSegmentLooping = false
            return
        }
        isPlaying = true
        clock.update(
            time: observedPlayer.currentTime,
            duration: observedPlayer.duration,
            advancing: true,
            repeats: isLooping
        )
        scheduleCompletionGuard(for: observedPlayer)
    }

    func clearPlaybackError() {
        playbackIssue = nil
    }

    /// Prepares visible rows off the main thread. The cache is deliberately tiny, so a
    /// 36k-item library never turns into a large memory resident audio cache.
    func preload(urls: [URL]) {
        AudioPreviewPreloader.shared.preload(
            urls: urls.map(AudioPlaybackCompatibility.resolvedURL(for:))
        )
    }

    func preload(item: SoundItem, url: URL) {
        AudioPreviewPreloader.shared.preload(
            candidates: [AudioPreviewCandidate(
                url: AudioPlaybackCompatibility.resolvedURL(for: url),
                item: item
            )]
        )
    }

    func cancelPendingPreloads() {
        AudioPreviewPreloader.shared.cancelPendingPreloads()
    }

    func clearPreloadedAudio() {
        AudioPreviewPreloader.shared.clear()
    }

    /// Resets every transport-owned reference before the library index is replaced.
    /// This prevents a decoder, queue item, or preloaded URL from the old index surviving
    /// long enough to play against the newly imported snapshot.
    func resetForLibraryReplacement() {
        releaseCurrentFileAccess()
        queueItems.removeAll(keepingCapacity: false)
        currentItem = nil
        currentURL = nil
        currentPlaybackURL = nil
        clearSegmentLoop()
        clearPreloadedAudio()
        clock.reset()
        isPlaying = false
        playbackIssue = nil
    }

    private func releaseCurrentFileAccess() {
        completionGuardTask?.cancel()
        levelMeter.stop()
        if let oldPlayer = player, let oldURL = currentPlaybackURL {
            // Detach before stopping so a delayed callback from the old decoder can never
            // overwrite the transport state of the newly selected sound.
            oldPlayer.delegate = nil
            oldPlayer.stop()
            clock.update(
                time: oldPlayer.currentTime,
                duration: oldPlayer.duration,
                repeats: isLooping
            )
            let estimatedBytes = currentItem.map(AudioPreviewPreloadPolicy.estimatedResidentBytes)
                ?? AudioPreviewPreloadPolicy.defaultUnknownCost
            AudioPreviewPreloader.shared.store(
                oldPlayer,
                url: oldURL,
                estimatedResidentBytes: estimatedBytes
            )
        }
        isPlaying = false
        player = nil
        currentPlaybackURL = nil
        if isAccessingSecurityScopedURL {
            currentURL?.stopAccessingSecurityScopedResource()
        }
        isAccessingSecurityScopedURL = false
    }
}

struct PreviewQueueItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let item: SoundItem
    let url: URL

    init(id: UUID = UUID(), item: SoundItem, url: URL) {
        self.id = id
        self.item = item
        self.url = url
    }
}

extension AudioPlayerController: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === self.player else { return }
        finishPlayback()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard player === self.player else { return }
        clock.update(
            time: player.currentTime,
            duration: player.duration,
            repeats: isLooping
        )
        isPlaying = false
        guard let itemID = currentItemID else {
            playbackIssue = nil
            return
        }
        playbackIssue = AudioPlaybackIssue(
            itemID: itemID,
            message: error.map { "音频解码失败：\($0.localizedDescription)" } ?? "音频解码失败。"
        )
    }
}

struct AudioPlaybackIssue: Equatable, Sendable {
    let itemID: UUID
    let message: String
}

private enum AudioPlaybackError: LocalizedError {
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .couldNotStart:
            return "音频播放器无法启动。"
        }
    }
}
