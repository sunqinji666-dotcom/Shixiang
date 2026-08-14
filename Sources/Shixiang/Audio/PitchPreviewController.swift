import Combine
import Foundation
import AudioToolbox
@preconcurrency import AVFoundation

enum PitchPreviewMode: String, CaseIterable, Sendable {
    case original
    case processed

    var title: String {
        switch self {
        case .original: return "原音"
        case .processed: return "处理音"
        }
    }
}

/// Audio-unit availability differs between a normal desktop macOS install and
/// restricted/headless environments. Probe before constructing AVAudio nodes so
/// the workbench can explain why pitch processing is unavailable instead of
/// terminating during app launch.
enum PitchAudioAvailability {
    static var isAvailable: Bool {
        let manager = AVAudioUnitComponentManager.shared()
        return requiredDescriptions.allSatisfy { description in
            !manager.components(matching: description).isEmpty
        }
    }

    private static let requiredDescriptions: [AudioComponentDescription] = [
        AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_NewTimePitch,
            componentManufacturer: 0,
            componentFlags: 0,
            componentFlagsMask: 0
        ),
        AudioComponentDescription(
            componentType: kAudioUnitType_Generator,
            componentSubType: kAudioUnitSubType_ScheduledSoundPlayer,
            componentManufacturer: 0,
            componentFlags: 0,
            componentFlagsMask: 0
        )
    ]
}

/// A dedicated, non-destructive pitch preview path.
///
/// It intentionally lives beside `AudioPlayerController` instead of changing the proven 0.2
/// player. `AVAudioUnitTimePitch` changes pitch while its rate stays at 1, so preview duration is
/// preserved. Callers can pass the standard player to `play`/`togglePlayback` to prevent two
/// previews from sounding at once.
@MainActor
final class PitchPreviewController: ObservableObject {
    @Published private(set) var currentURL: URL?
    @Published private(set) var isPlaying = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var errorItemURL: URL?
    @Published private(set) var isAvailable = false

    @Published var mode: PitchPreviewMode = .processed {
        didSet { applyPitchSettings() }
    }

    @Published var semitones: Int = 0 {
        didSet {
            let clamped = Self.clamp(semitones)
            if clamped != semitones {
                semitones = clamped
                return
            }
            applyPitchSettings()
        }
    }

    @Published var volume: Float = 0.85 {
        didSet {
            let clamped = min(max(volume, 0), 1)
            if clamped != volume {
                volume = clamped
                return
            }
            playerNode?.volume = clamped
        }
    }

    let clock = PlaybackClock()

    var currentTime: TimeInterval { clock.displayedTime(at: Date()) }
    var duration: TimeInterval { clock.duration }
    var progress: Double { clock.progress }

    func displayedError(for url: URL?) -> String? {
        PitchPreviewErrorPolicy.displayedMessage(
            issueURL: errorItemURL,
            displayedURL: url,
            message: errorMessage,
            isAvailable: isAvailable
        )
    }

    private let engine = AVAudioEngine()
    private let playerNode: AVAudioPlayerNode?
    private let timePitch: AVAudioUnitTimePitch?
    private var audioFile: AVAudioFile?
    private var scheduledStartFrame: AVAudioFramePosition = 0
    private var playbackGeneration = UUID()
    private var isAccessingSecurityScopedURL = false

    init() {
        let available = PitchAudioAvailability.isAvailable
        isAvailable = available
        if available {
            let playerNode = AVAudioPlayerNode()
            let timePitch = AVAudioUnitTimePitch()
            self.playerNode = playerNode
            self.timePitch = timePitch
            engine.attach(playerNode)
            engine.attach(timePitch)
        } else {
            playerNode = nil
            timePitch = nil
            errorMessage = PitchPreviewError.audioComponentsUnavailable.localizedDescription
        }
        playerNode?.volume = volume
        applyPitchSettings()
    }

    /// Loads the original file in place. It never writes to the source URL.
    func load(url: URL) throws {
        guard isAvailable,
              let playerNode,
              let timePitch else {
            throw PitchPreviewError.audioComponentsUnavailable
        }
        let normalizedURL = url.standardizedFileURL
        if currentURL == normalizedURL, audioFile != nil {
            return
        }

        unload()
        let accessed = normalizedURL.startAccessingSecurityScopedResource()

        do {
            let file = try AVAudioFile(forReading: normalizedURL)
            guard file.processingFormat.sampleRate > 0, file.processingFormat.channelCount > 0 else {
                throw PitchPreviewError.unsupportedAudioFormat
            }

            engine.disconnectNodeOutput(playerNode)
            engine.disconnectNodeOutput(timePitch)
            engine.connect(playerNode, to: timePitch, format: file.processingFormat)
            engine.connect(timePitch, to: engine.mainMixerNode, format: file.processingFormat)
            engine.prepare()
            try engine.start()

            audioFile = file
            currentURL = normalizedURL
            isAccessingSecurityScopedURL = accessed
            let loadedDuration = Double(file.length) / file.processingFormat.sampleRate
            clock.update(time: 0, duration: loadedDuration)
            errorMessage = nil
            errorItemURL = nil
            schedule(from: 0)
        } catch {
            if accessed {
                normalizedURL.stopAccessingSecurityScopedResource()
            }
            resetLoadedState()
            errorItemURL = normalizedURL
            throw error
        }
    }

    func play(
        url: URL,
        semitones: Int,
        mode: PitchPreviewMode = .processed,
        stopping standardPlayer: AudioPlayerController? = nil
    ) {
        standardPlayer?.stop()
        self.semitones = semitones
        self.mode = mode

        do {
            try load(url: url)
            resume()
        } catch {
            errorMessage = "无法试听变调：\(error.localizedDescription)"
            errorItemURL = url.standardizedFileURL
            isPlaying = false
        }
    }

    func togglePlayback(stopping standardPlayer: AudioPlayerController? = nil) {
        standardPlayer?.stop()
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    func toggle(stopping standardPlayer: AudioPlayerController? = nil) {
        togglePlayback(stopping: standardPlayer)
    }

    func pause() {
        guard isPlaying, let playerNode else { return }
        let pausedTime = renderedCurrentTime()
        playerNode.pause()
        clock.update(time: pausedTime, duration: duration)
        isPlaying = false
    }

    /// Stops and returns to the beginning while keeping the source loaded.
    func stop() {
        playerNode?.stop()
        isPlaying = false
        clock.update(time: 0, duration: duration)
        if audioFile != nil {
            schedule(from: 0)
        }
    }

    func seek(to time: TimeInterval) {
        guard audioFile != nil, let playerNode else { return }
        let target = min(max(time, 0), duration)
        let shouldResume = isPlaying
        schedule(from: target)
        if shouldResume, target < duration {
            playerNode.play()
            isPlaying = true
            clock.update(time: target, duration: duration, advancing: true)
        } else {
            isPlaying = false
            clock.update(time: target, duration: duration)
        }
    }

    /// Commits one completed pointer scrub. The engine is touched once at release, so the
    /// processed preview never chatters through fragments while the thumb is moving.
    func finishScrubbing(to time: TimeInterval, resumePlayback: Bool) {
        seek(to: time)
        guard resumePlayback, time < duration, !isPlaying else { return }
        resume()
    }

    func skip(seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    func setMode(_ mode: PitchPreviewMode) {
        self.mode = mode
    }

    func clearError() {
        errorMessage = nil
        errorItemURL = nil
    }

    /// Resets only per-sound audition state when the workbench moves to another source.
    /// Volume remains a user preference, while pitch and mode must never silently carry across
    /// two different sounds.
    func prepareForNewSound() {
        unload()
        semitones = 0
        mode = .processed
        clearError()
        if !isAvailable {
            errorMessage = PitchPreviewError.audioComponentsUnavailable.localizedDescription
        }
    }

    func unload() {
        playerNode?.stop()
        engine.stop()
        audioFile = nil
        if isAccessingSecurityScopedURL {
            currentURL?.stopAccessingSecurityScopedResource()
        }
        resetLoadedState()
    }

    static func clamp(_ semitones: Int) -> Int {
        min(max(semitones, -12), 12)
    }

    private func resume() {
        guard isAvailable, audioFile != nil, let playerNode else {
            errorMessage = PitchPreviewError.audioComponentsUnavailable.localizedDescription
            errorItemURL = nil
            return
        }
        errorMessage = nil
        errorItemURL = nil

        if currentTime >= duration {
            schedule(from: 0)
            clock.update(time: 0, duration: duration)
        }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                errorMessage = "音频引擎无法启动：\(error.localizedDescription)"
                errorItemURL = currentURL
                return
            }
        }
        playerNode.play()
        isPlaying = true
        clock.update(time: currentTime, duration: duration, advancing: true)
    }

    private func schedule(from time: TimeInterval) {
        guard let audioFile, let playerNode else { return }
        playbackGeneration = UUID()
        let generation = playbackGeneration
        playerNode.stop()

        let sampleRate = audioFile.processingFormat.sampleRate
        let requestedFrame = AVAudioFramePosition((time * sampleRate).rounded(.down))
        let startFrame = min(max(requestedFrame, 0), audioFile.length)
        scheduledStartFrame = startFrame
        let remaining = max(0, audioFile.length - startFrame)

        guard remaining > 0 else { return }
        let frameCount = AVAudioFrameCount(min(remaining, AVAudioFramePosition(UInt32.max)))
        playerNode.scheduleSegment(
            audioFile,
            startingFrame: startFrame,
            frameCount: frameCount,
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.finishPlayback(generation: generation)
            }
        }
    }

    private func applyPitchSettings() {
        timePitch?.rate = 1
        timePitch?.pitch = Float(semitones * 100)
        timePitch?.bypass = mode == .original
    }

    private func renderedCurrentTime() -> TimeInterval {
        guard let audioFile,
              let playerNode,
              let renderTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: renderTime) else {
            return clock.displayedTime(at: Date())
        }

        let absoluteFrame = scheduledStartFrame + playerTime.sampleTime
        return min(
            duration,
            max(0, Double(absoluteFrame) / audioFile.processingFormat.sampleRate)
        )
    }

    private func finishPlayback(generation: UUID) {
        guard generation == playbackGeneration else { return }
        isPlaying = false
        clock.update(time: 0, duration: duration)
        schedule(from: 0)
    }

    private func resetLoadedState() {
        playbackGeneration = UUID()
        currentURL = nil
        isAccessingSecurityScopedURL = false
        clock.reset()
        isPlaying = false
    }
}

enum PitchPreviewErrorPolicy {
    static func displayedMessage(
        issueURL: URL?,
        displayedURL: URL?,
        message: String?,
        isAvailable: Bool
    ) -> String? {
        guard let message else { return nil }
        if !isAvailable { return message }
        guard let issueURL, let displayedURL,
              issueURL.standardizedFileURL == displayedURL.standardizedFileURL else {
            return nil
        }
        return message
    }
}

private enum PitchPreviewError: LocalizedError {
    case audioComponentsUnavailable
    case unsupportedAudioFormat

    var errorDescription: String? {
        switch self {
        case .audioComponentsUnavailable:
            return "当前系统没有可用的变调音频组件，请在正常 macOS 音频环境中运行。"
        case .unsupportedAudioFormat:
            return "不支持此音频格式。"
        }
    }
}
