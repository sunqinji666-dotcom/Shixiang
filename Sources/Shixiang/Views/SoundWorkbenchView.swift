import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A deliberately optional inspector: the library keeps its width until the creator asks to
/// inspect or process one sound. Every operation reads the source and creates a new file.
struct SoundWorkbenchView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var standardPlayer: AudioPlayerController
    @EnvironmentObject private var preview: PitchPreviewController

    let item: SoundItem
    let fileURL: URL?
    let close: () -> Void

    @StateObject private var exporter = PitchExportController()

    @State private var semitones = 0
    @State private var analysisResult: KeyAnalysisResult?
    @State private var correctedOriginalKey: MusicalKey?
    @State private var selectedTargetKey: MusicalKey?
    @State private var analysisError: String?
    @State private var isAnalyzing = false
    @State private var analysisTask: Task<Void, Never>?
    @State private var intelligence: AudioIntelligence?
    @State private var isAnalyzingIntelligence = false
    @State private var intelligenceTask: Task<Void, Never>?
    @State private var customName = ""
    @State private var tagText = ""
    @State private var metadataSaved = false

    var body: some View {
        VStack(spacing: 0) {
            inspectorHeader
            Divider().overlay(ShixiangTheme.hairline)

            ScrollView {
                VStack(spacing: 14) {
                    fileOverview
                    intelligenceSection
                    metadataSection
                    keyAnalysisSection
                    pitchSection
                    previewSection
                    exportSection
                }
                .padding(14)
            }
        }
        .background(ShixiangTheme.workspaceGradient)
        .onChange(of: semitones) { _, value in
            preview.semitones = value
            if let correctedOriginalKey {
                selectedTargetKey = correctedOriginalKey.transposed(by: value)
            }
        }
        .onDisappear {
            analysisTask?.cancel()
            intelligenceTask?.cancel()
            isAnalyzingIntelligence = false
            preview.unload()
            exporter.cancel()
        }
        .onAppear {
            preview.prepareForNewSound()
            semitones = 0
            customName = item.customName ?? ""
            tagText = item.tags.joined(separator: "，")
            intelligence = library.intelligence(for: item.id)
        }
    }

    private var inspectorHeader: some View {
        HStack(spacing: 10) {
            ShixiangIconBadge(systemImage: "slider.horizontal.3", size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("声音工作台")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ShixiangTheme.primaryText)
                Text("分析与非破坏性处理")
                    .font(.system(size: 9))
                    .foregroundStyle(ShixiangTheme.tertiaryText)
            }
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark")
            }
            .buttonStyle(ShixiangRoundButtonStyle(size: 26))
            .help("关闭声音工作台")
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
    }

    private var fileOverview: some View {
        WorkbenchSection(title: "所选声音", icon: "waveform") {
            VStack(alignment: .leading, spacing: 11) {
                Text(item.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ShixiangTheme.primaryText)
                    .lineLimit(2)
                    .textSelection(.enabled)

                if item.customName != nil {
                    Text("原文件：\(item.fileName)")
                        .font(.system(size: 9))
                        .foregroundStyle(ShixiangTheme.tertiaryText)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }

                WaveformView(
                    fileURL: fileURL,
                    cacheIdentity: item.waveformCacheIdentity,
                    unplayedColor: ShixiangTheme.secondaryText.opacity(0.36)
                )
                .frame(height: 52)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(ShixiangTheme.canvas.opacity(0.52))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), alignment: .leading),
                        GridItem(.flexible(), alignment: .leading)
                    ],
                    alignment: .leading,
                    spacing: 9
                ) {
                    MetadataValue(label: "时长", value: item.duration.shixiangTimecode, icon: "clock")
                    MetadataValue(label: "格式", value: item.fileExtension.uppercased(), icon: "waveform.badge.plus")
                    MetadataValue(
                        label: "采样率",
                        value: item.sampleRate?.shixiangSampleRate ?? "未知",
                        icon: "waveform.path"
                    )
                    MetadataValue(
                        label: "声道",
                        value: item.channelCount.map(channelDescription) ?? "未知",
                        icon: "speaker.wave.2"
                    )
                }

                if fileURL == nil {
                    Label("原始文件当前不可访问", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(ShixiangTheme.gold)
                }
            }
        }
    }

    private var metadataSection: some View {
        WorkbenchSection(title: "别名与标签", icon: "tag.fill") {
            VStack(alignment: .leading, spacing: 11) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("显示别名")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(ShixiangTheme.secondaryText)
                    TextField("例如：低沉电影冲击", text: $customName)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: customName) { _, _ in metadataSaved = false }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("标签（用逗号分隔）")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(ShixiangTheme.secondaryText)
                    TextField("例如：冲击，电影，低频", text: $tagText)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: tagText) { _, _ in metadataSaved = false }
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 54), spacing: 6)],
                    alignment: .leading,
                    spacing: 6
                ) {
                    ForEach(["转场", "环境", "冲击", "拟音", "人声", "音乐", "科技"], id: \.self) { tag in
                        Button(tag) { toggleSuggestedTag(tag) }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .tint(parsedTags.contains(tag) ? ShixiangTheme.gold : ShixiangTheme.secondaryText)
                    }
                }

                Button {
                    let suggestion = SoundMetadataSuggestion.make(
                        for: item,
                        namingProfile: library.namingProfile
                    )
                    customName = suggestion.displayName
                    tagText = SoundItem.normalizedTags(parsedTags + suggestion.tags)
                        .joined(separator: "，")
                    metadataSaved = false
                } label: {
                    Label("本地智能整理建议", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(ShixiangCommandButtonStyle())
                .help("根据原文件名和目录生成别名与标签，不联网、不修改原文件")

                Button {
                    library.updateMetadata(
                        for: item.id,
                        customName: customName,
                        tags: parsedTags
                    )
                    metadataSaved = true
                } label: {
                    Label(
                        metadataSaved ? "已保存到拾响" : "保存别名与标签",
                        systemImage: metadataSaved ? "checkmark.circle.fill" : "square.and.arrow.down"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(ShixiangCommandButtonStyle(isPrimary: !metadataSaved))

                Text("仅写入本机 SQLite 资料库，不会修改原文件名、目录或音频内容。")
                    .font(.system(size: 9))
                    .foregroundStyle(ShixiangTheme.tertiaryText)
                    .lineSpacing(2)
            }
        }
    }

    private var intelligenceSection: some View {
        WorkbenchSection(title: "音频智能信息", icon: "waveform.path.ecg.rectangle") {
            VStack(alignment: .leading, spacing: 11) {
                if let intelligence {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), alignment: .leading),
                            GridItem(.flexible(), alignment: .leading)
                        ],
                        alignment: .leading,
                        spacing: 9
                    ) {
                        MetadataValue(
                            label: "BPM",
                            value: intelligence.bpm.map { "\(Int($0)) · \(Int(intelligence.bpmConfidence * 100))%" } ?? "未识别",
                            icon: "metronome"
                        )
                        MetadataValue(
                            label: "响度",
                            value: intelligence.loudnessLUFS.map { String(format: "%.1f LUFS", $0) } ?? "未识别",
                            icon: "speaker.wave.2"
                        )
                        MetadataValue(
                            label: "调性",
                            value: intelligence.musicalKey?.chineseDisplayName ?? "未识别",
                            icon: "tuningfork"
                        )
                        MetadataValue(
                            label: "调性置信度",
                            value: intelligence.musicalKey == nil ? "—" : "\(Int(intelligence.keyConfidence * 100))%",
                            icon: "checkmark.seal"
                        )
                        MetadataValue(
                            label: "音色指纹",
                            value: intelligence.acousticFingerprint == nil ? "未建立" : "已建立 · 本地",
                            icon: "ear.and.waveform"
                        )
                    }
                } else {
                    Text("本地分析 BPM、响度和调性。只在你主动点击后运行，不会导出或上传音频。")
                        .font(.system(size: 10))
                        .foregroundStyle(ShixiangTheme.secondaryText)
                        .lineSpacing(3)
                }

                Button {
                    isAnalyzingIntelligence = true
                    intelligenceTask?.cancel()
                    intelligenceTask = Task {
                        let result = await library.analyzeIntelligence(
                            for: item,
                            force: intelligence != nil
                        )
                        guard !Task.isCancelled else { return }
                        intelligence = result
                        isAnalyzingIntelligence = false
                    }
                } label: {
                    Label(
                        isAnalyzingIntelligence ? "正在分析…" : (intelligence == nil ? "分析音频信息" : "重新分析"),
                        systemImage: isAnalyzingIntelligence ? "hourglass" : "waveform.path.ecg"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(ShixiangCommandButtonStyle())
                .disabled(fileURL == nil || isAnalyzingIntelligence)
            }
        }
    }

    private var parsedTags: [String] {
        let separators = CharacterSet(charactersIn: ",，;；\n")
        return SoundItem.normalizedTags(
            tagText.components(separatedBy: separators)
        )
    }

    private func toggleSuggestedTag(_ tag: String) {
        var tags = parsedTags
        if let index = tags.firstIndex(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            tags.remove(at: index)
        } else {
            tags.append(tag)
        }
        tagText = tags.joined(separator: "，")
        metadataSaved = false
    }

    private var keyAnalysisSection: some View {
        WorkbenchSection(title: "调性分析", icon: "tuningfork") {
            VStack(alignment: .leading, spacing: 12) {
                if isAnalyzing {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text("正在寻找稳定的调性中心…")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(ShixiangTheme.secondaryText)
                } else if let analysisResult {
                    AnalysisResultView(result: analysisResult)
                } else if let analysisError {
                    Label(analysisError, systemImage: "exclamationmark.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(ShixiangTheme.gold)
                } else {
                    Text("适合音乐、氛围与带明确音高的声音。普通音效无需识别调性，也可以直接按半音变调。")
                        .font(.system(size: 10))
                        .foregroundStyle(ShixiangTheme.secondaryText)
                        .lineSpacing(3)
                }

                Button(action: analyzeKey) {
                    Label(
                        analysisResult == nil ? "分析调性" : "重新分析",
                        systemImage: "waveform.path.ecg"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(ShixiangCommandButtonStyle())
                .disabled(fileURL == nil || isAnalyzing)
            }
        }
    }

    private var pitchSection: some View {
        WorkbenchSection(title: "变调处理", icon: "music.note.list") {
            VStack(spacing: 13) {
                HStack(spacing: 10) {
                    Menu {
                        Button("未指定") {
                            correctedOriginalKey = nil
                            selectedTargetKey = nil
                        }
                        Divider()
                        ForEach(MusicalKey.Mode.allCases, id: \.self) { mode in
                            Section(mode.chineseName) {
                                ForEach(MusicalKey.allCases.filter { $0.mode == mode }, id: \.self) { key in
                                    Button {
                                        correctedOriginalKey = key
                                        selectedTargetKey = key.transposed(by: semitones)
                                    } label: {
                                        if correctedOriginalKey == key {
                                            Label(key.chineseDisplayName, systemImage: "checkmark")
                                        } else {
                                            Text(key.chineseDisplayName)
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        ToneValue(label: "原调（可校正）", value: originalKeyName, showsMenu: true)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(maxWidth: .infinity)

                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ShixiangTheme.tertiaryText)

                    Menu {
                        if let correctedOriginalKey {
                            ForEach(
                                MusicalKey.allCases.filter { $0.mode == correctedOriginalKey.mode },
                                id: \.self
                            ) { key in
                                Button {
                                    selectedTargetKey = key
                                    semitones = correctedOriginalKey.shortestSemitoneOffset(to: key)
                                } label: {
                                    if selectedTargetKey == key {
                                        Label(key.chineseDisplayName, systemImage: "checkmark")
                                    } else {
                                        Text(key.chineseDisplayName)
                                    }
                                }
                            }
                        }
                    } label: {
                        ToneValue(label: "目标调", value: targetKeyName, showsMenu: correctedOriginalKey != nil)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(maxWidth: .infinity)
                    .disabled(correctedOriginalKey == nil)
                }

                HStack(spacing: 10) {
                    Button {
                        semitones = max(-12, semitones - 1)
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(ShixiangRoundButtonStyle(size: 32))
                    .disabled(semitones <= -12)

                    VStack(spacing: 2) {
                        Text(signedSemitoneLabel)
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(semitones == 0 ? ShixiangTheme.secondaryText : ShixiangTheme.gold)
                        Text("半音")
                            .font(.system(size: 9))
                            .foregroundStyle(ShixiangTheme.tertiaryText)
                    }
                    .frame(maxWidth: .infinity)

                    Button {
                        semitones = min(12, semitones + 1)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(ShixiangRoundButtonStyle(size: 32))
                    .disabled(semitones >= 12)
                }

                Slider(
                    value: Binding(
                        get: { Double(semitones) },
                        set: { semitones = Int($0.rounded()) }
                    ),
                    in: -12...12,
                    step: 1
                )
                .tint(ShixiangTheme.violet)

                Button("恢复原始设置") {
                    semitones = 0
                    preview.semitones = 0
                    preview.setMode(.original)
                    selectedTargetKey = correctedOriginalKey
                    exporter.reset()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(ShixiangTheme.secondaryText)
                .disabled(semitones == 0 && preview.mode == .original)
            }
        }
    }

    private var previewSection: some View {
        WorkbenchSection(title: "对比试听", icon: "headphones") {
            VStack(spacing: 12) {
                Picker("试听版本", selection: $preview.mode) {
                    Text("原音").tag(PitchPreviewMode.original)
                    Text("变调").tag(PitchPreviewMode.processed)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack(spacing: 12) {
                    Button(action: togglePreview) {
                        Label(
                            preview.isPlaying ? "暂停" : "试听",
                            systemImage: preview.isPlaying ? "pause.fill" : "play.fill"
                        )
                        .frame(minWidth: 68)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ShixiangTheme.violet)
                    .disabled(fileURL == nil || !preview.isAvailable)

                    PitchPreviewProgressControl(
                        preview: preview,
                        clock: preview.clock
                    )
                }

                if let error = preview.displayedError(for: fileURL) {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.system(size: 9))
                        .foregroundStyle(ShixiangTheme.gold)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var exportSection: some View {
        WorkbenchSection(title: "生成副本", icon: "waveform.badge.plus") {
            VStack(alignment: .leading, spacing: 11) {
                Text("导出为新的 24-bit WAV。原始音频始终保持只读，不会被覆盖。")
                    .font(.system(size: 10))
                    .foregroundStyle(ShixiangTheme.secondaryText)
                    .lineSpacing(3)

                if exporter.isExporting {
                    ProgressView(value: exporter.progress)
                        .tint(ShixiangTheme.violet)
                    HStack {
                        Text("正在生成 \(Int(exporter.progress * 100))%")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(ShixiangTheme.tertiaryText)
                        Spacer()
                        Button("取消") { exporter.cancel() }
                            .buttonStyle(.plain)
                            .font(.system(size: 10))
                    }
                } else {
                    Button(action: chooseExportDestination) {
                        Label("导出变调 WAV 副本", systemImage: "waveform.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ShixiangTheme.gold)
                    .foregroundStyle(.black.opacity(0.82))
                    .disabled(fileURL == nil || semitones == 0 || !preview.isAvailable)
                }

                if semitones == 0 {
                    Text("选择非零半音后即可导出；0 半音与原音相同。")
                        .font(.system(size: 9))
                        .foregroundStyle(ShixiangTheme.tertiaryText)
                }

                if let error = exporter.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 9))
                        .foregroundStyle(ShixiangTheme.gold)
                }

                if let output = exporter.outputURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([output])
                    } label: {
                        Label("已生成：\(output.lastPathComponent)", systemImage: "checkmark.circle.fill")
                            .lineLimit(2)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(ShixiangTheme.gold)
                }
            }
        }
    }

    private var originalKeyName: String {
        correctedOriginalKey?.chineseDisplayName ?? "未指定"
    }

    private var targetKeyName: String {
        if let selectedTargetKey {
            return selectedTargetKey.chineseDisplayName
        }
        return semitones == 0 ? "自由变调" : signedSemitoneLabel
    }

    private var signedSemitoneLabel: String {
        semitones > 0 ? "+\(semitones)" : "\(semitones)"
    }

    private func analyzeKey() {
        guard let fileURL else { return }
        analysisTask?.cancel()
        isAnalyzing = true
        analysisResult = nil
        analysisError = nil

        analysisTask = Task {
            do {
                let result = try await KeyAnalyzer().analyze(url: fileURL)
                guard !Task.isCancelled else { return }
                analysisResult = result
                correctedOriginalKey = result.key
                selectedTargetKey = result.key?.transposed(by: semitones)
                isAnalyzing = false
            } catch is CancellationError {
                isAnalyzing = false
            } catch {
                guard !Task.isCancelled else { return }
                analysisError = "无法完成调性分析：\(error.localizedDescription)"
                isAnalyzing = false
            }
        }
    }

    private func togglePreview() {
        guard let fileURL else { return }
        preview.semitones = semitones

        if preview.currentURL == fileURL.standardizedFileURL {
            preview.toggle(stopping: standardPlayer)
        } else {
            preview.play(
                url: fileURL,
                semitones: semitones,
                mode: preview.mode,
                stopping: standardPlayer
            )
        }
    }

    private func chooseExportDestination() {
        guard let fileURL else { return }
        let panel = NSSavePanel()
        panel.title = "导出变调 WAV 副本"
        panel.message = "原始音频不会被修改。请选择处理副本的保存位置。"
        panel.prompt = "导出副本"
        panel.allowedContentTypes = [.wav]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = PitchShiftNaming.suggestedFileName(
            for: fileURL,
            semitones: semitones
        )

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        exporter.startExport(source: fileURL, destination: destination, semitones: semitones)
    }

    private func channelDescription(_ count: Int) -> String {
        switch count {
        case 1: return "单声道"
        case 2: return "立体声"
        default: return "\(count) 声道"
        }
    }
}

private struct PitchPreviewProgressControl: View {
    @ObservedObject var preview: PitchPreviewController
    @ObservedObject var clock: PlaybackClock

    @State private var dragTime: TimeInterval?
    @State private var isEditing = false
    @State private var wasPlayingBeforeDrag = false

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 120.0,
                paused: !clock.isAdvancing || isEditing
            )
        ) { timeline in
            let duration = max(clock.duration, 0.001)
            let displayedTime = dragTime ?? min(clock.displayedTime(at: timeline.date), duration)
            HStack(spacing: 9) {
                ShixiangDirectSlider(
                    value: displayedTime,
                    range: 0...duration,
                    tint: ShixiangTheme.violet,
                    isEnabled: preview.currentURL != nil && preview.isAvailable,
                    accessibilityName: "变调试听进度",
                    accessibilityValueText: "\(displayedTime.shixiangTimecode) / \(clock.duration.shixiangTimecode)",
                    accessibilityHintText: "上下调整变调试听位置",
                    onEditingBegan: beginEditing,
                    onChange: { dragTime = $0 },
                    onEditingEnded: finishEditing
                )

                Text(displayedTime.shixiangTimecode)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(ShixiangTheme.tertiaryText)
                    .frame(width: 32, alignment: .trailing)
            }
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private func beginEditing() {
        isEditing = true
        wasPlayingBeforeDrag = preview.isPlaying
        dragTime = preview.currentTime
        if wasPlayingBeforeDrag {
            preview.pause()
        }
    }

    private func finishEditing(_ finalTime: Double) {
        preview.finishScrubbing(
            to: finalTime,
            resumePlayback: wasPlayingBeforeDrag
        )
        dragTime = nil
        isEditing = false
        wasPlayingBeforeDrag = false
    }
}

private struct AnalysisResultView: View {
    let result: KeyAnalysisResult

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(statusColor)
                    Text(result.key?.chineseDisplayName ?? "无法可靠识别")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(ShixiangTheme.primaryText)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("置信度")
                        .font(.system(size: 8))
                        .foregroundStyle(ShixiangTheme.tertiaryText)
                    Text("\(Int((result.confidence * 100).rounded()))%")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(statusColor)
                }
            }

            Text(statusExplanation)
                .font(.system(size: 9))
                .foregroundStyle(ShixiangTheme.secondaryText)
                .lineSpacing(2)

            if !result.alternatives.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("其他候选")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(ShixiangTheme.tertiaryText)
                    ForEach(Array(result.alternatives.prefix(3).enumerated()), id: \.offset) { _, candidate in
                        HStack {
                            Text(candidate.key.chineseDisplayName)
                            Spacer()
                            Text("\(Int((candidate.confidence * 100).rounded()))%")
                                .fontDesign(.monospaced)
                        }
                        .font(.system(size: 9))
                        .foregroundStyle(ShixiangTheme.secondaryText)
                    }
                }
            }
        }
    }

    private var statusTitle: String {
        switch result.status {
        case .stable: return "检测到稳定调性"
        case .tooShort: return "片段过短"
        case .insufficientSignal: return "有效信号不足"
        case .lowConfidence: return "调性置信度较低"
        case .noStableTonalCenter: return "未找到稳定调性"
        }
    }

    private var statusExplanation: String {
        switch result.status {
        case .stable:
            return result.confidence >= 0.7
                ? "可以把它作为原调，并根据目标调自动计算半音。"
                : "结果置信度偏低，建议先用原音/变调对比试听确认。"
        case .tooShort:
            return "声音太短，音高信息不足；仍可直接按半音试听和导出。"
        case .insufficientSignal:
            return "静音、噪声或打击声占比较高；无需调性也能直接变调。"
        case .lowConfidence:
            return "候选调性接近，无法可靠确认；建议先对比试听，或直接按半音处理。"
        case .noStableTonalCenter:
            return "素材可能是无调性音效或调性变化较多；仍可直接变调。"
        }
    }

    private var statusColor: Color {
        result.status == .stable && result.confidence >= 0.7
            ? ShixiangTheme.gold
            : ShixiangTheme.secondaryText
    }
}

private struct WorkbenchSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ShixiangIconBadge(systemImage: icon, size: 24, tint: ShixiangTheme.gold)
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ShixiangTheme.secondaryText)
                Spacer(minLength: 0)
            }
            content
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    ShixiangTheme.elevated.opacity(0.80),
                    ShixiangTheme.surface.opacity(0.74)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(ShixiangTheme.hairline, lineWidth: 1)
        }
    }
}

private struct MetadataValue: View {
    let label: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(ShixiangTheme.gold.opacity(0.76))
                .frame(width: 19, height: 19)
                .background(ShixiangTheme.gold.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 8))
                    .foregroundStyle(ShixiangTheme.tertiaryText)
                Text(value)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ShixiangTheme.secondaryText)
            }
        }
    }
}

private struct ToneValue: View {
    let label: String
    let value: String
    var showsMenu = false

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(ShixiangTheme.tertiaryText)
            HStack(spacing: 4) {
                Text(value)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                if showsMenu {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(ShixiangTheme.tertiaryText)
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(ShixiangTheme.primaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(ShixiangTheme.canvas.opacity(0.58))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
