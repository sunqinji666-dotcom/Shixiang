import Foundation
import Testing
@testable import Shixiang

/// 语义搜索排序质量评测（合成库）。
///
/// 目的：为 `LocalAISearchRanking.featuredIDs` 的权重、门禁、排除与多样化行为提供
/// 可回归的量化保护。所有用例使用确定性合成数据，不依赖真实用户库，也不接触音频文件。
struct AISearchRankingTests {

    // MARK: - featuredIDs 门禁

    /// 无语义、无目录证据的纯文本命中不应进入 AI 推荐货架。
    @Test func featuredIDsRequireSemanticOrDirectoryEvidence() throws {
        let packID = UUID()
        let riser = makeItem(packID: packID, path: "Transitions/Fast_Riser_01.wav")
        let opaque = makeItem(packID: packID, path: "opaque_001.wav") // 根目录 + 无语义文件名

        let intent = AISearchIntentParser.parse("快速上升转场")
        let matches = makeMatches(
            items: [riser, opaque],
            intent: intent,
            semantic: [riser.id: 0.9, opaque.id: 0]
        )

        let featured = LocalAISearchRanking.featuredIDs(
            in: [riser, opaque],
            expandedQuery: "快速上升转场",
            matches: matches
        )

        #expect(featured.contains(riser.id))
        #expect(!featured.contains(opaque.id))
    }

    /// 排除词做降权惩罚（×0.18）。当候选数充足时，高分排除项应被压出推荐货架。
    /// 已知边界：排除匹配只查字面（"雨"），英文文件名（Rain）在 featuredIDs 内不会命中
    /// searchAliases——该缺口与 LocalLibraryView 过滤层不一致，由 P2 硬过滤改进统一修复。
    @Test func featuredIDsDeprioritizeExcludedTerms() throws {
        let packID = UUID()
        let rain = makeItem(packID: packID, path: "Atmospheres/城市大雨_01.wav")
        var items = [rain]
        var semantic: [UUID: Double] = [rain.id: 1.0]
        for index in 0..<11 {
            let riser = makeItem(packID: packID, path: "Transitions/Riser_\(index).wav")
            items.append(riser)
            semantic[riser.id] = 0.8 - Double(index) * 0.03
        }

        let intent = AISearchIntentParser.parse("远处雷声，不要雨")
        #expect(intent.excludedTerms.contains("雨"))

        let matches = makeMatches(
            items: items,
            intent: intent,
            semantic: semantic
        )

        let featured = LocalAISearchRanking.featuredIDs(
            in: items,
            expandedQuery: "远处雷声 不要 雨",
            matches: matches
        )

        #expect(!featured.contains(rain.id))
        #expect(!featured.isEmpty)
    }

    /// 同一命名家族（Riser_0…Riser_19 去编号后同一族）在推荐货架中被压缩，避免刷屏。
    @Test func featuredIDsLimitRepeatsOfTheSameFamily() throws {
        let packID = UUID()
        var items: [SoundItem] = []
        var semantic: [UUID: Double] = [:]
        for index in 0..<20 {
            let item = makeItem(packID: packID, path: "Transitions/Riser_\(index).wav")
            items.append(item)
            semantic[item.id] = 0.5 + Double(index % 5) * 0.1
        }
        let matches = makeMatches(items: items, semantic: semantic)

        let featured = LocalAISearchRanking.featuredIDs(
            in: items,
            expandedQuery: "上升转场",
            matches: matches
        )
        #expect(featured.count <= LocalAISearchRanking.featuredLimit)
        // 20 个同族候选被 MMR 压缩到每族上限。
        #expect(featured.count <= max(1, LocalAISearchRanking.featuredLimit / 3))
    }

    /// MMR 让推荐货架覆盖多个目录：同语义候选分布在 5 个目录时全部进入推荐。
    @Test func featuredIDsSpreadAcrossDirectoriesUnderMMR() throws {
        let packID = UUID()
        let paths = [
            "Transitions/Riser.wav",
            "Music/Synth_Pad.wav",
            "Ambience/City_Traffic.wav",
            "UI/Button_Click.wav",
            "Foley/Footsteps.wav"
        ]
        var items: [SoundItem] = []
        var semantic: [UUID: Double] = [:]
        for (index, path) in paths.enumerated() {
            let item = makeItem(packID: packID, path: path)
            items.append(item)
            semantic[item.id] = 0.8 - Double(index) * 0.05
        }
        let matches = makeMatches(items: items, semantic: semantic)

        let featured = LocalAISearchRanking.featuredIDs(
            in: items,
            expandedQuery: "环境转场",
            matches: matches
        )
        #expect(featured.count == items.count)
        // 不同目录的候选都应进入推荐（MMR 不把它们当成重复族）。
        let directories = Set(featured.compactMap { id in
            items.first(where: { $0.id == id })?.folderPath
        })
        #expect(directories.count == paths.count)
    }

    // MARK: - 意图解析的确定性行为

    /// 冲突诊断只做提示，不崩溃、不丢弃合法意图。
    @Test func intentParserReportsContradictionsWithoutLosingSignals() {
        let intent = AISearchIntentParser.parse("克制但强烈")
        #expect(intent.conflicts.contains("同时包含克制与强烈"))
        #expect(intent.intensity != nil)
        #expect(intent.hasConflicts)
    }

    /// 强度冲突用就近原则收敛：最后一个强度词表达最终诉求。
    @Test func intentParserConvergesIntensityByNearestWord() {
        let restrainedThenForceful = AISearchIntentParser.parse("克制但强烈")
        #expect(restrainedThenForceful.intensity == 1.8)
        #expect(restrainedThenForceful.hasConflicts)

        let forcefulThenRestrained = AISearchIntentParser.parse("强烈但克制一点")
        #expect(forcefulThenRestrained.intensity == 0.45)
        #expect(forcefulThenRestrained.hasConflicts)
    }

    /// 否定名词通过正则被捕获（"不要雨" → 排除"雨"）。
    @Test func intentParserCapturesExplicitNegatedNouns() {
        let intent = AISearchIntentParser.parse("雷声，不要雨")
        #expect(intent.excludedTerms.contains("雨"))
        #expect(intent.soundTypes.contains { $0.term == "雷声" })
        #expect(intent.confidence > 0.5)
    }

    /// 时长目标会把检索收敛到 ±0.5 秒窗口。
    @Test func intentParserClampsTargetDurationWindow() {
        let intent = AISearchIntentParser.parse("产品结尾落版，一秒左右")
        #expect(intent.targetDuration == 1)
        #expect(intent.minimumDuration == 0.5)
        #expect(intent.maximumDuration == 1.5)
        #expect(intent.useCases.contains { $0.term == "落版" })
    }

    // MARK: - 声学证据的确定性

    /// 意图包含"低沉"时，低频质心（低 spectralCentroid）得到更高的声学分。
    @Test func acousticEvidenceRewardsLowFrequencyForDeepIntents() {
        let deep = AcousticFingerprint(
            spectralBands: Array(repeating: 0.08, count: 12),
            spectralCentroid: 0.18,
            spectralRolloff: 0.4,
            spectralFlatness: 0.3,
            zeroCrossingRate: 0.05,
            crestFactor: 0.5,
            transientDensity: 0.2,
            dynamicRange: 0.4,
            analyzedDuration: 1
        )
        let brightIntent = AISearchIntentParser.parse("明亮，尖锐")
        let deepIntent = AISearchIntentParser.parse("低沉，厚")

        let deepScoreForDeep = LocalAISearchRanking.acousticScoreForTesting(deep, intent: deepIntent)
        let deepScoreForBright = LocalAISearchRanking.acousticScoreForTesting(deep, intent: brightIntent)
        #expect(deepScoreForDeep > deepScoreForBright)
    }

    // MARK: - 库词汇表

    /// 词汇表从目录、文件名与标签提取库内真实 token，中文目录按层级独立成词。
    @Test func libraryVocabularyExtractsRealDirectoryAndFileTokens() throws {
        let packID = UUID()
        let items = [
            makeItem(packID: packID, path: "Transitions/Fast_Riser_01.wav"),
            makeItem(packID: packID, path: "Transitions/Slow_Riser_02.wav"),
            makeItem(packID: packID, path: "科技/上升/提示_01.wav")
        ]
        let vocabulary = LibraryVocabulary.build(from: items)

        #expect(vocabulary.isKnown("transitions"))
        #expect(vocabulary.isKnown("riser"))
        #expect(vocabulary.isKnown("fast"))
        #expect(vocabulary.isKnown("slow"))
        #expect(vocabulary.isKnown("科技"))
        #expect(vocabulary.isKnown("上升"))
        #expect(vocabulary.isKnown("提示"))
        #expect(vocabulary.frequency(of: "riser") == 2)
    }

    /// 停止词、纯数字与单字 token 不进词汇表。
    @Test func libraryVocabularyFiltersStopWordsNumbersAndSingletons() throws {
        let packID = UUID()
        let items = [
            makeItem(packID: packID, path: "Audio/sound_01.wav"),
            makeItem(packID: packID, path: "科技/up_2024.wav"),
            makeItem(packID: packID, path: "Music/a.wav")
        ]
        let vocabulary = LibraryVocabulary.build(from: items)

        #expect(!vocabulary.isKnown("audio"))
        #expect(!vocabulary.isKnown("sound"))
        #expect(!vocabulary.isKnown("01"))
        #expect(!vocabulary.isKnown("2024"))
        #expect(!vocabulary.isKnown("a"))
        #expect(vocabulary.isKnown("科技"))
        #expect(vocabulary.isKnown("up"))
        #expect(vocabulary.isKnown("music"))
    }

    /// 传入库词汇表后，featuredIDs 的排序结果不应退化（回归保护）。
    @Test func featuredIDsWithVocabularyKeepSemanticHits() throws {
        let packID = UUID()
        let riser = makeItem(packID: packID, path: "Transitions/Fast_Riser_01.wav")
        let opaque = makeItem(packID: packID, path: "opaque_001.wav")

        let intent = AISearchIntentParser.parse("快速上升转场")
        let matches = makeMatches(
            items: [riser, opaque],
            intent: intent,
            semantic: [riser.id: 0.9, opaque.id: 0]
        )
        let vocabulary = LibraryVocabulary.build(from: [riser, opaque])

        let featured = LocalAISearchRanking.featuredIDs(
            in: [riser, opaque],
            expandedQuery: "快速上升转场",
            matches: matches,
            vocabulary: vocabulary
        )

        #expect(featured.contains(riser.id))
        #expect(!featured.contains(opaque.id))
    }

    // MARK: - helpers

    private func makeMatches(
        items: [SoundItem],
        intent: AISearchIntent = .empty,
        semantic: [UUID: Double] = [:],
        literalIDs: [UUID] = []
    ) -> LibrarySearchMatches {
        LibrarySearchMatches(
            ids: Set(items.map(\.id)),
            literalIDs: Set(literalIDs),
            relevanceByID: semantic,
            semanticRelevanceByID: semantic,
            semanticMatchCount: semantic.count,
            conceptTitles: [],
            intent: intent
        )
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
