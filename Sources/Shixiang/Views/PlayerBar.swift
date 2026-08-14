import SwiftUI

struct PlayerBar: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: AudioPlayerController
    @Environment(\.stopPitchPreview) private var stopPitchPreview
    @ObservedObject var selection: LibrarySelection
    @State private var isQueuePresented = false
    @State private var isDragHintVisible = false
    @AppStorage("shixiang.library.dragHintPresented") private var hasPresentedDragHint = false
    @StateObject private var spectrum = PlaybackSpectrum()

    private var displayedItemID: UUID? {
        PlayerBarItemPolicy.displayedItemID(
            selectedItemID: selection.soundID,
            loadedItemID: player.currentItemID,
            isPlaying: player.isPlaying
        )
    }

    private var currentItem: SoundItem? {
        library.sound(id: displayedItemID)
    }

    private var currentPlaybackError: String? {
        PlayerBarErrorPolicy.displayedMessage(
            issueItemID: player.playbackErrorItemID,
            displayedItemID: displayedItemID,
            message: player.playbackError
        )
    }

    private var isCurrentItemLoaded: Bool {
        displayedItemID != nil && displayedItemID == player.currentItemID
    }

    private var currentFileURL: URL? {
        currentItem.flatMap(library.url(for:))
    }

    private var presentationDuration: TimeInterval {
        PlayerBarTiming.displayedDuration(
            clockDuration: player.clock.duration,
            hasLoadedAudio: isCurrentItemLoaded,
            indexedDuration: currentItem?.duration
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            trackIdentity
                .frame(minWidth: 180, idealWidth: 240, maxWidth: 280, alignment: .leading)

            transport
                .contentShape(Rectangle())
                .zIndex(2)

            compactTimeline
                .frame(minWidth: 180, maxWidth: .infinity)

            PlaybackVolumeControl()
        }
        .padding(.horizontal, 12)
        .frame(height: 86)
        .background(ShixiangTheme.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(ShixiangTheme.hairline).frame(height: 1)
        }
        .popover(isPresented: $isQueuePresented, arrowEdge: .bottom) {
            PreviewQueuePopover()
                .environmentObject(player)
        }
        .task(id: currentFileURL?.standardizedFileURL.path) {
            await spectrum.load(url: currentFileURL)
        }
        .task(id: library.isInitialLoadComplete) {
            guard library.isInitialLoadComplete,
                  library.soundCount > 0,
                  !hasPresentedDragHint else { return }
            // Let the library rows settle, then keep this coach mark visible until the user
            // explicitly closes it. A new session starts with no selected sound, so the hint
            // must not depend on currentFileURL becoming non-nil.
            try? await Task.sleep(for: .seconds(5.1))
            guard !Task.isCancelled, !hasPresentedDragHint else { return }
            withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
                isDragHintVisible = true
            }
        }
    }

    private var progress: some View {
        PlaybackProgressSlider(
            clock: player.clock,
            isEnabled: isCurrentItemLoaded,
            presentationDuration: presentationDuration
        )
    }

    private var compactTimeline: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Only playback needs display-linked updates. Play and stop switch states directly,
            // so the timeline can become completely idle as soon as the audio clock stops.
            TimelineView(.animation(
                minimumInterval: 1.0 / 30.0,
                paused: !player.clock.isAdvancing
            )) { timeline in
                // Fixed x positions: left is low frequency and right is high frequency. The
                // current playback time selects the matching FFT frame from the source file.
                // Until that frame exists, the already-running AVAudioPlayer meter supplies an
                // immediate first response instead of leaving a complex sound visually silent.
                PlaybackLiveWaveformView(
                    bands: spectrum.bands(
                        at: player.clock.displayedTime(at: timeline.date),
                        liveFallback: player.levelMeter.currentSample
                    ),
                    isActive: player.clock.isAdvancing
                )
            }
            .frame(height: 36)
            .allowsHitTesting(false)

            HStack(alignment: .center, spacing: 10) {
                progress
                    .opacity(0.82)
                    .frame(maxWidth: .infinity)

                PlaybackTimeLine(
                    clock: player.clock,
                    presentationDuration: presentationDuration
                )
                .frame(width: 78, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transport: some View {
        HStack(spacing: 7) {
            Button {
                player.skip(seconds: -5)
            } label: {
                Image(systemName: "gobackward.5")
                    .shixiangHoverIcon("gobackward.5")
            }
            .buttonStyle(ShixiangRoundButtonStyle(size: 32))
            .disabled(!isCurrentItemLoaded)
            .accessibilityLabel("后退 5 秒")

            Button(action: togglePlayback) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .offset(x: player.isPlaying ? 0 : 0.5)
                    .shixiangHoverIcon(player.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(ShixiangRoundButtonStyle(isPrimary: currentItem != nil, size: 42))
            .disabled(currentItem == nil)
            .accessibilityLabel(player.isPlaying ? "暂停" : "播放")

            Button {
                player.skip(seconds: 5)
            } label: {
                Image(systemName: "goforward.5")
                    .shixiangHoverIcon("goforward.5")
            }
            .buttonStyle(ShixiangRoundButtonStyle(size: 32))
            .disabled(!isCurrentItemLoaded)
            .accessibilityLabel("前进 5 秒")

            Button {
                player.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .shixiangHoverIcon("stop.fill")
            }
            .buttonStyle(ShixiangRoundButtonStyle(size: 32))
            .disabled(!isCurrentItemLoaded)
            .accessibilityLabel("停止")

            Button("A") {
                player.setLoopStart()
            }
            .buttonStyle(
                ShixiangRoundButtonStyle(
                    isActive: isCurrentItemLoaded && player.loopStart != nil,
                    size: 28
                )
            )
            .disabled(!isCurrentItemLoaded)
            .accessibilityLabel("设置片段循环起点 A")
            .help("设置片段循环起点 A")

            Button("B") {
                player.setLoopEnd()
            }
            .buttonStyle(
                ShixiangRoundButtonStyle(
                    isActive: isCurrentItemLoaded && player.isSegmentLooping,
                    size: 28
                )
            )
            .disabled(player.loopStart == nil || !isCurrentItemLoaded)
            .accessibilityLabel("设置片段循环终点 B")
            .help("设置片段循环终点 B")

            if isCurrentItemLoaded && (player.loopStart != nil || player.loopEnd != nil) {
                Button {
                    player.clearSegmentLoop()
                } label: {
                Image(systemName: "xmark")
                    .shixiangHoverIcon("xmark")
                }
                .buttonStyle(ShixiangRoundButtonStyle(size: 28))
                .accessibilityLabel("清除片段循环")
                .help("清除片段循环")
            }

            Button {
                player.isLooping.toggle()
            } label: {
                Image(systemName: "repeat")
                    .shixiangHoverIcon("repeat")
            }
            .buttonStyle(ShixiangRoundButtonStyle(isActive: player.isLooping, size: 32))
            .accessibilityLabel(player.isLooping ? "关闭循环试听" : "开启循环试听")
            .help(player.isLooping ? "关闭循环试听" : "循环试听")

            Button {
                isQueuePresented.toggle()
            } label: {
                Image(systemName: player.queueItems.isEmpty ? "list.bullet" : "list.number")
                    .shixiangHoverIcon(player.queueItems.isEmpty ? "list.bullet" : "list.number")
            }
            .buttonStyle(ShixiangRoundButtonStyle(isActive: !player.queueItems.isEmpty, size: 32))
            .accessibilityLabel(player.queueItems.isEmpty ? "试听队列为空" : "打开试听队列，共 \(player.queueItems.count) 条")
            .help(player.queueItems.isEmpty ? "试听队列为空" : "打开试听队列")
        }
        .padding(.horizontal, 2)
        .frame(height: 58)
        .contentShape(Rectangle())
    }

    private var trackIdentity: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomLeading) {
                draggableSoundIcon
                if isDragHintVisible {
                    DragHintBubble {
                        dismissDragHint()
                    }
                        .offset(x: -6, y: -38)
                        .transition(.scale(scale: 0.88, anchor: .topLeading).combined(with: .opacity))
                        .zIndex(5)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(currentPlaybackError ?? currentItem?.displayName ?? "未选择声音")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        currentPlaybackError == nil
                            ? (currentItem == nil ? ShixiangTheme.secondaryText : ShixiangTheme.primaryText)
                            : ShixiangTheme.gold
                    )
                    .lineLimit(1)

                if let currentItem {
                    Text(currentItem.folderPath.isEmpty ? currentItem.fileExtension.uppercased() : currentItem.folderPath)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(ShixiangTheme.tertiaryText)
                        .lineLimit(1)
                }
            }
        }
        .frame(height: 58, alignment: .leading)
        .onChange(of: currentFileURL?.path) { _, newPath in
            guard newPath != nil, !hasPresentedDragHint else { return }
            withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
                isDragHintVisible = true
            }
        }
    }

    private func dismissDragHint() {
        hasPresentedDragHint = true
        withAnimation(.easeOut(duration: 0.18)) {
            isDragHintVisible = false
        }
    }

    @ViewBuilder
    private var draggableSoundIcon: some View {
        let icon = CurrentSoundDragIcon(isEnabled: currentFileURL != nil) {
            dismissDragHint()
        }
        if let currentFileURL {
            icon.onDrag {
                let clipRange = isCurrentItemLoaded
                    ? player.loopStart.flatMap { start in
                        player.loopEnd.map { end in start...end }
                    }
                    : nil
                return SoundDragProvider.itemProvider(
                    for: currentFileURL,
                    timeRange: clipRange
                )
            }
        } else {
            icon
        }
    }

    private func togglePlayback() {
        guard let currentItem, let url = library.url(for: currentItem) else { return }
        stopPitchPreview()
        player.togglePlayback(item: currentItem, url: url)
    }
}

enum PlayerBarItemPolicy {
    static func displayedItemID(
        selectedItemID: UUID?,
        loadedItemID: UUID?,
        isPlaying: Bool
    ) -> UUID? {
        if isPlaying {
            return loadedItemID ?? selectedItemID
        }
        return selectedItemID ?? loadedItemID
    }
}

enum PlayerBarErrorPolicy {
    static func displayedMessage(
        issueItemID: UUID?,
        displayedItemID: UUID?,
        message: String?
    ) -> String? {
        guard issueItemID != nil, issueItemID == displayedItemID else { return nil }
        return message
    }
}

enum PlayerBarTiming {
    static func displayedDuration(
        clockDuration: TimeInterval,
        hasLoadedAudio: Bool,
        indexedDuration: TimeInterval?
    ) -> TimeInterval {
        let candidate = hasLoadedAudio ? clockDuration : (indexedDuration ?? 0)
        guard candidate.isFinite else { return 0 }
        return max(candidate, 0)
    }
}

private struct CurrentSoundDragIcon: View {
    let isEnabled: Bool
    var onInteraction: () -> Void = {}
    var size: CGFloat = 36
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ShixiangIconBadge(
                systemImage: isEnabled ? "waveform" : "waveform.slash",
                size: size,
                tint: isEnabled ? ShixiangTheme.violet : ShixiangTheme.tertiaryText
            )

            if isEnabled {
                ZStack {
                    Circle().fill(ShixiangTheme.gold)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.78))
                        .accessibilityHidden(true)
                }
                .frame(width: max(10, size * 0.34), height: max(10, size * 0.34))
                .offset(x: 2, y: 2)
            }
        }
        .scaleEffect(isHovering && isEnabled ? 1.035 : 1)
        .onHover { isHovering = $0 }
        .onTapGesture { onInteraction() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isEnabled ? "拖出当前声音" : "未选择可拖出的声音")
        .accessibilityHint(isEnabled ? "按住并拖入 Final Cut Pro" : "选择声音后可拖出")
        .help(isEnabled ? "按住这个图标，拖入 Final Cut Pro" : "选择声音后可拖入 Final Cut Pro")
    }
}

private struct DragHintBubble: View {
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.up.right")
                .font(.system(size: 9, weight: .bold))
            Text("拖到剪辑软件")
                .font(.system(size: 9, weight: .semibold))
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Color.black.opacity(0.78))
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Color.white.opacity(0.98))
        .clipShape(Capsule())
        .overlay { Capsule().stroke(Color.black.opacity(0.12), lineWidth: 1) }
        .shadow(color: .black.opacity(0.28), radius: 12, y: 5)
    }
}

private struct PreviewQueuePopover: View {
    @EnvironmentObject private var player: AudioPlayerController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("试听队列")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("清空") { player.clearQueue() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ShixiangTheme.gold)
                    .disabled(player.queueItems.isEmpty)
            }
            .padding(14)

            Divider().overlay(ShixiangTheme.hairline)

            if player.queueItems.isEmpty {
                ContentUnavailableView(
                    "队列为空",
                    systemImage: "list.bullet",
                    description: Text("在音效行的右键菜单中加入试听队列。")
                )
                .frame(width: 300, height: 150)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(player.queueItems) { queuedItem in
                            HStack(spacing: 8) {
                                Image(systemName: "waveform")
                                    .foregroundStyle(ShixiangTheme.violet)
                                Text(queuedItem.item.displayName)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                Spacer()
                                Button {
                                    player.removeQueuedItem(queuedItem)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .semibold))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(ShixiangTheme.tertiaryText)
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                        }
                    }
                }
                .frame(width: 320, height: min(CGFloat(player.queueItems.count * 32), 260))
            }
        }
        .background(ShixiangTheme.canvas)
    }
}

private struct PlaybackVolumeControl: View {
    @EnvironmentObject private var player: AudioPlayerController
    @AppStorage("shixiang.previewVolume") private var savedVolume = 0.85
    @AppStorage("shixiang.previewVolumeBeforeMute") private var savedVolumeBeforeMute = 0.85
    @State private var localVolume = 0.85

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggleMute) {
                Image(systemName: volumeIcon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(localVolume <= 0.001 ? ShixiangTheme.gold : ShixiangTheme.tertiaryText)
                    .frame(width: 16, height: 18)
            }
            .buttonStyle(.plain)
            .help(localVolume <= 0.001 ? "恢复试听音量" : "静音试听")

            ShixiangDirectSlider(
                value: localVolume,
                range: 0...1,
                tint: ShixiangTheme.violet,
                accessibilityName: "试听音量",
                accessibilityValueText: "\(Int((localVolume * 100).rounded()))%",
                accessibilityHintText: "上下调整试听音量",
                onChange: { newVolume in
                    localVolume = newVolume
                    player.volume = Float(newVolume)
                },
                onEditingEnded: persistVolume
            )
            .frame(width: 120)

            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 12))
                .foregroundStyle(ShixiangTheme.tertiaryText)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 11)
        .frame(height: 54)
        .help("试听音量")
        .onAppear {
            let restored = min(max(savedVolume, 0), 1)
            localVolume = restored
            player.volume = Float(restored)
            if restored > 0.001 {
                savedVolumeBeforeMute = restored
            }
        }
        .onDisappear {
            persistVolume(localVolume)
        }
    }

    private var volumeIcon: String {
        switch localVolume {
        case ...0.001: return "speaker.slash.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    private func toggleMute() {
        if localVolume > 0.001 {
            savedVolumeBeforeMute = localVolume
            localVolume = 0
            savedVolume = 0
            player.volume = 0
        } else {
            let restored = min(max(savedVolumeBeforeMute, 0.1), 1)
            localVolume = restored
            savedVolume = restored
            player.volume = Float(restored)
        }
    }

    /// Pointer updates stay entirely in memory. UserDefaults is committed once when the drag
    /// ends, so a volume gesture cannot compete with playback and waveform rendering.
    private func persistVolume(_ volume: Double) {
        let clamped = min(max(volume, 0), 1)
        savedVolume = clamped
        if clamped > 0.001 {
            savedVolumeBeforeMute = clamped
        }
    }
}

private struct PlaybackProgressSlider: View {
    @EnvironmentObject private var player: AudioPlayerController
    @ObservedObject var clock: PlaybackClock
    let isEnabled: Bool
    let presentationDuration: TimeInterval

    @State private var dragTime: TimeInterval?
    @State private var isEditing = false
    @State private var wasPlayingBeforeDrag = false

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 60.0,
                paused: !clock.isAdvancing || isEditing
            )
        ) { timeline in
            let duration = max(presentationDuration, 0.001)
            let clockTime = isEnabled ? clock.displayedTime(at: timeline.date) : 0
            let displayedTime = dragTime ?? min(clockTime, duration)
            ShixiangDirectSlider(
                value: displayedTime,
                range: 0...duration,
                tint: ShixiangTheme.violet,
                isEnabled: isEnabled,
                accessibilityName: "播放进度",
                accessibilityValueText: "\(displayedTime.shixiangTimecode) / \(presentationDuration.shixiangTimecode)",
                accessibilityHintText: "上下调整播放位置",
                onEditingBegan: beginEditing,
                onChange: { newTime in
                    dragTime = min(max(newTime, 0), clock.duration)
                },
                onEditingEnded: finishEditing
            )
            .padding(.horizontal, 10)
            .frame(height: 14)
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private func beginEditing() {
        isEditing = true
        wasPlayingBeforeDrag = player.isPlaying
        dragTime = clock.displayedTime(at: Date())
        if wasPlayingBeforeDrag {
            player.pause()
        }
    }

    private func finishEditing(_ finalTime: Double) {
        let committedTime = min(max(finalTime, 0), clock.duration)
        player.finishScrubbing(
            to: committedTime,
            resumePlayback: wasPlayingBeforeDrag
        )
        dragTime = nil
        isEditing = false
        wasPlayingBeforeDrag = false
    }
}

/// A detailed, fixed-position live waveform for the player bar. It is deliberately a meter
/// (recent audio energy), not a duplicate of the static file waveform used in the sound list.
private struct PlaybackLiveWaveformView: View {
    let bands: [Float]
    let isActive: Bool
    @State private var displayedBands = Array(repeating: Float.zero, count: PlaybackSpectrum.bandCount)
    @State private var peakCaps = Array(repeating: Float.zero, count: PlaybackSpectrum.bandCount)
    @State private var peakHoldFrames = Array(repeating: 0, count: PlaybackSpectrum.bandCount)

    var body: some View {
        Canvas { context, size in
            // Playback is a frequent, latency-sensitive action. Switch between the idle mark
            // and the live spectrum immediately instead of morphing one into the other.
            if !isActive {
                drawIdleWord(in: &context, size: size, opacity: 1, collapse: 0)
            }

            let bars = displayedBands.isEmpty
                ? Array(repeating: Float.zero, count: PlaybackSpectrum.bandCount)
                : displayedBands
            let gap: CGFloat = 0.75
            let barWidth = max(1, (size.width - gap * CGFloat(bars.count - 1)) / CGFloat(bars.count))
            let centerY = size.height * 0.5
            let maximumHalfHeight = max(2, size.height * 0.39)
            let capHeight: CGFloat = 2.2

            for (index, sample) in bars.enumerated() {
                let x = CGFloat(index) * (barWidth + gap)
                // Expand visual contrast: low residual energy stays near the floor while strong
                // bands travel close to full height, producing a clear up/down beat response.
                let energy = pow(CGFloat(sample), 1.32)
                let bodyHalfHeight = isActive ? max(0.45, energy * maximumHalfHeight) : 0
                let bodyRect = CGRect(x: x, y: centerY - bodyHalfHeight, width: barWidth, height: bodyHalfHeight * 2)
                context.fill(
                    Path(roundedRect: bodyRect, cornerRadius: barWidth * 0.5),
                    with: .linearGradient(
                        Gradient(colors: [
                            ShixiangTheme.blue.opacity(0.92),
                            ShixiangTheme.violet.opacity(0.98),
                            ShixiangTheme.gold.opacity(0.78)
                        ]),
                        startPoint: CGPoint(x: x, y: centerY - bodyHalfHeight),
                        endPoint: CGPoint(x: x, y: centerY + bodyHalfHeight)
                    ),
                    style: FillStyle()
                )

                // Independent peak cap: the body pushes this small "brick" upward instantly.
                // It holds briefly after the body falls, then drops under its own faster decay.
                let capValue = peakCaps.indices.contains(index) ? peakCaps[index] : sample
                let capTravel = pow(CGFloat(capValue), 1.18) * maximumHalfHeight
                let capReveal: CGFloat = isActive ? 1 : 0
                let capRect = CGRect(
                    x: x,
                    y: max(1, centerY - capTravel * capReveal - capHeight - 1.5),
                    width: barWidth,
                    height: capHeight
                )
                context.fill(
                    Path(roundedRect: capRect, cornerRadius: min(1, barWidth * 0.35)),
                    with: .color(ShixiangTheme.gold.opacity(0.98 * capReveal))
                )
            }
        }
        .padding(.horizontal, 5)
        .background {
            Capsule()
                .fill(ShixiangTheme.canvas.opacity(0.72))
                .overlay { Capsule().stroke(ShixiangTheme.violet.opacity(0.16), lineWidth: 1) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("实时播放频谱")
        .help("按当前播放位置显示真实低频到高频能量")
        .onChange(of: bands, initial: true) { _, incoming in
            guard isActive else { return }
            updateBallistics(with: incoming)
        }
        .onChange(of: isActive, initial: true) { _, active in
            if active {
                updateBallistics(with: bands)
            }
        }
    }

    /// A restrained 5×7 pixel signature occupying the same surface as the spectrum. At 53
    /// columns wide it remains legible only on a second look — a quiet creator mark, not a logo
    /// competing with the transport controls.
    private func drawIdleWord(
        in context: inout GraphicsContext,
        size: CGSize,
        opacity: CGFloat,
        collapse: CGFloat
    ) {
        guard opacity > 0.001 else { return }
        let glyphs: [Character: [String]] = [
            "J": ["11111", "00100", "00100", "00100", "00100", "10100", "01100"],
            "A": ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
            "C": ["01111", "10000", "10000", "10000", "10000", "10000", "01111"],
            "K": ["10001", "10010", "10100", "11000", "10100", "10010", "10001"],
            "U": ["10001", "10001", "10001", "10001", "10001", "10001", "01110"],
            "D": ["11110", "10001", "10001", "10001", "10001", "10001", "11110"],
            "I": ["11111", "00100", "00100", "00100", "00100", "00100", "11111"],
            "O": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"]
        ]
        let word = Array("JACKAUDIO")
        let columns = word.count * 5 + max(0, word.count - 1)
        let rows = 7
        let gap: CGFloat = 0.85
        let cellWidth = min(
            3.2,
            max(1.25, (size.width - CGFloat(columns - 1) * gap) / CGFloat(columns))
        )
        let cellHeight = min(2.6, max(1.7, (size.height - CGFloat(rows - 1) * gap) / CGFloat(rows)))
        let drawingWidth = CGFloat(columns) * cellWidth + CGFloat(columns - 1) * gap
        let drawingHeight = CGFloat(rows) * cellHeight + CGFloat(rows - 1) * gap
        let originX = (size.width - drawingWidth) / 2
        let originY = (size.height - drawingHeight) / 2

        var columnOffset = 0
        for (letterIndex, character) in word.enumerated() {
            guard let glyph = glyphs[character] else { continue }
            for row in 0..<rows {
                for column in 0..<5 where glyph[row][glyph[row].index(glyph[row].startIndex, offsetBy: column)] == "1" {
                    let globalColumn = columnOffset + column
                    let rect = CGRect(
                        x: originX + CGFloat(globalColumn) * (cellWidth + gap),
                        y: centerCollapsedY(
                            originY + CGFloat(row) * (cellHeight + gap),
                            cellHeight: cellHeight,
                            canvasHeight: size.height,
                            collapse: collapse
                        ),
                        width: cellWidth,
                        height: max(0.7, cellHeight * (1 - collapse * 0.72))
                    )
                    let progress = CGFloat(globalColumn) / CGFloat(max(1, columns - 1))
                    let color = progress < 0.72
                        ? ShixiangTheme.violet.opacity(0.34 * opacity)
                        : ShixiangTheme.gold.opacity(0.38 * opacity)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: min(0.75, cellWidth * 0.28)),
                        with: .color(color)
                    )
                }
            }
            columnOffset += 5
            if letterIndex < word.count - 1 { columnOffset += 1 }
        }
    }

    private func centerCollapsedY(
        _ originalY: CGFloat,
        cellHeight: CGFloat,
        canvasHeight: CGFloat,
        collapse: CGFloat
    ) -> CGFloat {
        let originalCenter = originalY + cellHeight * 0.5
        let collapsedCenter = canvasHeight * 0.5
        let interpolatedCenter = originalCenter + (collapsedCenter - originalCenter) * collapse
        let collapsedHeight = max(0.7, cellHeight * (1 - collapse * 0.72))
        return interpolatedCenter - collapsedHeight * 0.5
    }

    private func smoothstep(_ lower: CGFloat, _ upper: CGFloat, _ value: CGFloat) -> CGFloat {
        guard upper > lower else { return value >= upper ? 1 : 0 }
        let progress = min(max((value - lower) / (upper - lower), 0), 1)
        return progress * progress * (3 - 2 * progress)
    }

    private func updateBallistics(with incoming: [Float]) {
        let source = incoming.isEmpty
            ? Array(repeating: Float.zero, count: PlaybackSpectrum.bandCount)
            : incoming
        guard source.count == PlaybackSpectrum.bandCount else { return }

        if displayedBands.count != source.count {
            displayedBands = Array(repeating: 0, count: source.count)
            peakCaps = Array(repeating: 0, count: source.count)
            peakHoldFrames = Array(repeating: 0, count: source.count)
        }

        for index in source.indices {
            let target = source[index]
            let current = displayedBands[index]
            // Stronger visual ballistics layered on truthful FFT values: instant attack and a
            // decisive fall make bass impacts read as separate hits rather than a soft plateau.
            displayedBands[index] = target >= current
                ? target
                : max(target, current - 0.105)

            if target >= peakCaps[index] {
                peakCaps[index] = target
                peakHoldFrames[index] = 4 // about 130 ms at the 30 Hz display cadence
            } else if peakHoldFrames[index] > 0 {
                peakHoldFrames[index] -= 1
            } else {
                peakCaps[index] = max(displayedBands[index], peakCaps[index] - 0.055)
            }
        }
    }
}

private struct PlaybackTimeLine: View {
    @ObservedObject var clock: PlaybackClock
    let presentationDuration: TimeInterval

    var body: some View {
        // The label displays whole seconds, so refreshing it at animation-frame frequency only
        // spends main-thread work without changing a visible glyph. The progress surfaces keep
        // their 60 Hz cadence; this text stays responsive at five updates per second.
        TimelineView(.animation(minimumInterval: 0.2, paused: !clock.isAdvancing)) { timeline in
            HStack(spacing: 7) {
                HStack(spacing: 4) {
                    Text(clock.displayedTime(at: timeline.date).shixiangTimecode)
                    Text("/")
                    Text(presentationDuration.shixiangTimecode)
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(ShixiangTheme.tertiaryText)
            }
            .lineLimit(1)
        }
    }
}
