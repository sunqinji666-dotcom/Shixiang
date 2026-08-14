import Foundation

/// The local model does not search the library directly. It turns a natural-language request
/// into a small, controlled set of terms, then lets SQLite remain responsible for retrieval.
struct LocalAISearchPlan: Equatable, Sendable {
    let keywords: [String]

    init(keywords: [String]) {
        var seen = Set<String>()
        self.keywords = keywords.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 48 else { return nil }
            let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            // These words describe the library, not the requested sound. Letting a small model
            // add them turns a precise query such as “风” into a near-global match.
            guard !Self.genericKeywords.contains(key) else { return nil }
            return seen.insert(key).inserted ? trimmed : nil
        }
        .prefix(10)
        .map { $0 }
    }

    func expandedQuery(originalQuery: String) -> String {
        ([originalQuery] + keywords).joined(separator: " ")
    }

    private static let genericKeywords: Set<String> = [
        "sound", "sounds", "sound effect", "sound effects", "sound-effect", "sound-effects",
        "effect", "effects", "audio", "audios", "soundtrack", "sfx", "fx",
        "声音", "音效", "音频", "素材", "声音效果"
    ]
}

enum LocalAISearchError: LocalizedError {
    case runtimeUnavailable
    case modelUnavailable
    case plannerUnavailable
    case generationFailed(String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            return "没有找到本地 AI 运行环境。"
        case .modelUnavailable:
            return "没有找到已下载的 Qwen 1.7B 模型。"
        case .plannerUnavailable:
            return "本地 AI 搜索组件不完整。"
        case let .generationFailed(message):
            return "本地 AI 搜索失败：\(message)"
        case .malformedResponse:
            return "本地 AI 没有返回可用的搜索词。"
        }
    }
}

/// A deliberately narrow bridge to the local MLX environment prepared by AI Studio.
/// It is opt-in from the search field, has no network path, and never exposes library files
/// to the model: only the user-entered search sentence is passed to the subprocess.
enum LocalAISearchPlanner {
    /// Keeps the opt-in planner responsive after the first request. The model process is still
    /// isolated per miss, but repeated searches (including returning to a previous query) do not
    /// pay the model startup cost again during this app session.
    private actor PlanCache {
        private var values: [String: LocalAISearchPlan] = [:]
        private let capacity = 64

        func value(for key: String) -> LocalAISearchPlan? {
            values[key]
        }

        func insert(_ value: LocalAISearchPlan, for key: String) {
            if values.count >= capacity, values[key] == nil {
                values.removeValue(forKey: values.keys.first!)
            }
            values[key] = value
        }
    }

    private static let planCache = PlanCache()
    private static let environment = ProcessInfo.processInfo.environment
    private static let externalAudioTaggingDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ShixiangAIStudio/AudioTagging", isDirectory: true)

    /// Release builds carry the complete local AI runtime inside the app bundle. Keep the
    /// existing Application Support location as a development/legacy fallback so an already
    /// configured local environment continues to work while the bundled payload is assembled.
    private static var bundledAudioTaggingDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("AI/AudioTagging", isDirectory: true)
    }

    static func plan(for query: String) async throws -> LocalAISearchPlan {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return LocalAISearchPlan(keywords: []) }

        let cacheKey = trimmedQuery.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        if let cached = await planCache.value(for: cacheKey) {
            return cached
        }

        // Single concepts such as “风”, “雨”, “UI” already have exact local taxonomy and
        // directory matches. Asking a 1.7B model to elaborate them is less accurate than
        // using that evidence directly, and often introduces generic words like “sound”.
        if trimmedQuery.filter({ !$0.isWhitespace }).count <= 2 {
            let plan = LocalAISearchPlan(keywords: Self.shortQueryAliases[trimmedQuery] ?? [])
            await planCache.insert(plan, for: cacheKey)
            return plan
        }

        // A compact CJK phrase is usually a creator's real library label ("古风歌曲",
        // "科技提示音"), not a sentence that benefits from creative rewriting. Keep it exact:
        // the semantic index still participates, but Qwen is not allowed to turn it into a
        // looser set such as "音乐 / 旋律 / 节奏" and hide the files the user already named.
        if Self.isCompactCJKLibraryLabel(trimmedQuery) {
            let plan = LocalAISearchPlan(keywords: [])
            await planCache.insert(plan, for: cacheKey)
            return plan
        }

        let plan = try await Task.detached(priority: .userInitiated) {
            try run(query: trimmedQuery)
        }.value
        let enriched = Self.enrich(plan, for: trimmedQuery)
        await planCache.insert(enriched, for: cacheKey)
        return enriched
    }

    private static func run(query: String) throws -> LocalAISearchPlan {
        let fileManager = FileManager.default
        let pythonURL = runtimeURL
        guard fileManager.isExecutableFile(atPath: pythonURL.path) else {
            throw LocalAISearchError.runtimeUnavailable
        }

        let modelURL = modelURL
        guard fileManager.fileExists(atPath: modelURL.path) else {
            throw LocalAISearchError.modelUnavailable
        }

        guard let scriptURL = Bundle.main.url(forResource: "qwen_search_planner", withExtension: "py") else {
            throw LocalAISearchError.plannerUnavailable
        }

        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = pythonURL
        process.arguments = [
            scriptURL.path,
            "--model", modelURL.path,
            "--query", query
        ]
        // The bundled runtime lives inside a sealed, signed app. Python must never create
        // __pycache__ or user-site files beside it, otherwise the first AI search would mutate
        // the bundle and invalidate its code signature.
        var processEnvironment = environment
        processEnvironment["PYTHONDONTWRITEBYTECODE"] = "1"
        processEnvironment["PYTHONNOUSERSITE"] = "1"
        // Make the bundled Python relocatable. A venv's pyvenv.cfg records the build Mac's
        // absolute path; PYTHONHOME anchors the standard library to the copy beside this
        // executable so the same signed App works after being dragged to another Mac.
        processEnvironment["PYTHONHOME"] = pythonURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        process.environment = processEnvironment
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()

        let errorText = String(
            decoding: errors.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        guard process.terminationStatus == 0 else {
            let message = errorText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n")
                .suffix(2)
                .joined(separator: " ")
            throw LocalAISearchError.generationFailed(message.isEmpty ? "进程意外结束。" : message)
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        struct Response: Decodable { let keywords: [String] }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw LocalAISearchError.malformedResponse
        }
        return LocalAISearchPlan(keywords: response.keywords)
    }

    /// Small, reviewable aliases for common creator shorthand. These are not model guesses;
    /// they keep very short requests useful without allowing Qwen to add broad filler words.
    private static let shortQueryAliases: [String: [String]] = [
        "风": ["wind", "breeze", "gust"],
        "雨": ["rain", "storm"],
        "水": ["water", "ocean", "river"],
        "火": ["fire", "flame", "burn"],
        "古风": ["古筝", "古琴", "古韵", "traditional chinese", "oriental"],
        "古筝": ["guzheng", "古风"],
        "古琴": ["guqin", "古风"],
        "UI": ["interface", "button", "click"],
        "ui": ["interface", "button", "click"]
    ]

    /// Small deterministic bridges for creator language that the local model can express in
    /// Chinese but the library often stores in English. They are retrieval aliases, not extra
    /// creative guesses: the original sentence remains in the expanded query and the semantic
    /// index still decides whether a file is a real match.
    private static func enrich(_ plan: LocalAISearchPlan, for query: String) -> LocalAISearchPlan {
        let normalized = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
        var aliases = plan.keywords
        if normalized.contains("咖啡馆") || normalized.contains("咖啡店") || normalized.contains("cafe") || normalized.contains("coffee shop") {
            aliases += ["cafe", "coffee shop", "咖啡馆"]
        }
        if normalized.contains("约会") || normalized.contains("情侣") || normalized.contains("dating") || normalized.contains("date") {
            aliases += ["romantic", "conversation", "couple", "约会"]
        }
        return LocalAISearchPlan(keywords: aliases)
    }

    private static func isCompactCJKLibraryLabel(_ value: String) -> Bool {
        let characters = value.filter { !$0.isWhitespace }
        guard (3...8).contains(characters.count) else { return false }
        return characters.unicodeScalars.allSatisfy {
            (0x3400...0x4DBF).contains($0.value)
                || (0x4E00...0x9FFF).contains($0.value)
                || (0xF900...0xFAFF).contains($0.value)
        }
    }

    private static var runtimeURL: URL {
        if let configured = environment["SHIXIANG_AI_PYTHON_PATH"], !configured.isEmpty {
            return URL(fileURLWithPath: configured)
        }
        if let bundled = bundledAudioTaggingDirectory {
            let candidate = bundled.appendingPathComponent(".venv/bin/python")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return externalAudioTaggingDirectory.appendingPathComponent(".venv/bin/python")
    }

    private static var modelURL: URL {
        if let configured = environment["SHIXIANG_AI_MODEL_PATH"], !configured.isEmpty {
            return URL(fileURLWithPath: configured)
        }
        let directory = bundledAudioTaggingDirectory ?? externalAudioTaggingDirectory
        return directory
            .appendingPathComponent("hf-cache/models--mlx-community--Qwen3-1.7B-4bit/snapshots", isDirectory: true)
            .appendingPathComponent("3b1b1768f8f8cf8351c712464f906e86c2b8269e", isDirectory: true)
    }
}

/// 排序权重的集中定义。
///
/// 权重校准应基于带标注的评测集（见 `AISearchRankingTests`）：采样真实库数据，为每个
/// 查询标注"应当召回 / 应当靠前 / 不应出现"三档，再跑网格搜索或最小二乘拟合。当前
/// 默认值保留项目既有手拍值，集中到一处便于将来校准与回溯。校准方法：以评测集的
/// NDCG@10 为目标，对四个信号权重在 0.05 步长内扫描，取指标最高的组合。
enum SearchRankingWeights {
    /// 各信号在加权求和中的权重。
    static let semanticWeight = 0.58
    static let directoryWeight = 0.24
    static let metadataWeight = 0.06
    static let acousticWeight = 0.12
    /// AI 推荐门禁：普通文本命中只有同时具备语义或目录证据才算推荐。
    static let semanticGate = 0.20
    static let directoryGate = 0.34
    /// FTS 语义相关原始分数 → 0...1 的归一化分母。
    static let semanticDenominator = 1.5
    /// 精确字面命中的加成。
    static let literalBoost = 0.06
    /// 排除词命中时的分数惩罚（仅在保底路径使用）。
    static let excludedPenalty = 0.18
    /// 无音色意图时声学信号的中性基线。
    static let acousticNeutralBaseline = 0.5
}

/// 声学判定阈值。当前是经验值；校准建议：采样库内已归类样本（如"低沉"类目），
/// 观察实际 spectralCentroid / transientDensity 的分布，以 p50 / p75 反推替换，
/// 让阈值与库的真实音色分布一致而不是与常识一致。
enum AcousticThresholds {
    /// 判"低频倾向"的质心上限。
    static let centroidLow: Float = 0.35
    /// 判"高频明亮"的质心下限。
    static let centroidHigh: Float = 0.45
    /// 判"瞬态克制"的密度上限。
    static let transientSoft: Float = 0.45
    /// 判"瞬态明显"的密度下限。
    static let transientSharp: Float = 0.35
    /// 判"动态强烈/克制"的密度分界。
    static let intensityActive: Float = 0.42
    /// 声学证据中各信号的归一化分母。
    static let centroidLowDenominator = 0.65
    static let centroidHighDenominator = 0.72
    static let transientSoftDenominator = 0.8
    static let transientSharpDenominator = 0.65
    static let intensityDenominator = 0.7
}

/// A fast, deterministic second stage for local AI search. Qwen understands the request once;
/// this scorer then combines the semantic index with the creator's directory vocabulary rather
/// than asking the model to inspect thousands of files one by one.
enum LocalAISearchRanking {
    static let featuredLimit = 10

    static func hasDirectSoundTypeEvidence(_ item: SoundItem, intent: AISearchIntent) -> Bool {
        let types = intent.soundTypes
        guard !types.isEmpty else { return true }
        let haystack = normalize(([item.displayName, item.fileName] + item.tags).joined(separator: " "))
        // “科技上升” contains a scene/category anchor plus a motion. The scene must be
        // visible in the candidate name or tag; otherwise generic risers (flies, bells, wind)
        // can outrank the requested technology sound.
        if let technology = types.first(where: { normalize($0.term) == normalize("科技") }) {
            return AISearchIntentParser.searchAliases(for: technology.term)
                .contains { haystack.contains(normalize($0)) }
        }
        return types.contains { type in
            AISearchIntentParser.searchAliases(for: type.term)
                .contains { haystack.contains(normalize($0)) }
        }
    }

    static func explanation(
        for item: SoundItem,
        query: String,
        intent: AISearchIntent,
        creatorIntent: CreatorSearchIntent,
        intelligence: AudioIntelligence? = nil
    ) -> [String] {
        var reasons: [String] = []
        let normalizedName = normalize(([item.displayName, item.fileName]).joined(separator: " "))
        let normalizedFolder = normalize(item.folderPath)
        let normalizedTags = normalize(item.tags.joined(separator: " "))
        let haystack = normalize(([item.displayName, item.fileName, item.folderPath] + item.tags).joined(separator: " "))
        if directPathMatchScore(item, query: query) > 0 {
            reasons.append(normalizedName.contains(normalize(query)) ? "文件名直接命中" : "目录直接命中")
        }
        if let type = intent.soundTypes.first(where: {
            AISearchIntentParser.searchAliases(for: $0.term)
                .contains { haystack.contains(normalize($0)) }
        }) {
            reasons.append("类别证据：\(type.term)")
        }
        if let folderTerm = intent.requiredTerms.first(where: {
            let token = normalize($0)
            return token.count > 1 && normalizedFolder.contains(token)
        }) {
            reasons.append("目录证据：\(folderTerm)")
        }
        for term in Array(intent.requiredTerms.dropFirst(intent.soundTypes.count)) + intent.preferredTerms {
            let token = normalize(term)
            guard token.count > 1, (normalizedName.contains(token) || normalizedTags.contains(token) || normalizedFolder.contains(token)) else { continue }
            reasons.append(term == "咖啡馆" ? "咖啡馆场景" : "标签/语义：\(term)")
        }
        if let minimum = creatorIntent.minimumDuration, item.duration >= minimum {
            reasons.append("满足 ≥ \(minimum.formatted()) 秒")
        }
        if let maximum = creatorIntent.maximumDuration, item.duration <= maximum {
            reasons.append("满足 ≤ \(maximum.formatted()) 秒")
        }
        if let target = intent.targetDuration, item.duration.isFinite {
            let delta = abs(item.duration - target)
            if delta <= 0.5 { reasons.append("时长接近 \(target.formatted()) 秒") }
        }
        if let excluded = intent.excludedTerms.first(where: { term in
            AISearchIntentParser.searchAliases(for: term).contains { haystack.contains(normalize($0)) }
        }) {
            reasons.append("注意：含排除词“\(excluded)”")
        }
        if let acoustic = acousticExplanation(for: intelligence?.acousticFingerprint, intent: intent) {
            reasons.append("声学：\(acoustic)")
        }
        var uniqueReasons: [String] = []
        var seenReasons = Set<String>()
        for reason in reasons where seenReasons.insert(reason).inserted {
            uniqueReasons.append(reason)
        }
        return Array(uniqueReasons.prefix(3))
    }

    private static func acousticExplanation(
        for acoustic: AcousticFingerprint?,
        intent: AISearchIntent
    ) -> String? {
        guard let acoustic else { return nil }
        let terms = intent.tonalQualities.map(\.term) + intent.dynamics.map(\.term)
        if terms.contains(where: { ["低沉", "低频", "厚", "deep", "low"].contains($0.lowercased()) }),
           acoustic.spectralCentroid < AcousticThresholds.centroidLow {
            return "低频倾向"
        }
        if terms.contains(where: { ["明亮", "尖锐", "bright", "sharp", "高频"].contains($0.lowercased()) }),
           acoustic.spectralCentroid > AcousticThresholds.centroidHigh {
            return "高频明亮"
        }
        if terms.contains(where: { ["柔和", "轻柔", "克制", "soft", "gentle"].contains($0.lowercased()) }),
           acoustic.transientDensity < AcousticThresholds.transientSoft {
            return "瞬态克制"
        }
        if terms.contains(where: { ["短促", "冲击", "爆发", "short", "impact"].contains($0.lowercased()) }),
           acoustic.transientDensity > AcousticThresholds.transientSharp {
            return "瞬态明显"
        }
        if let intensity = intent.intensity,
           intensity > 1.2,
           acoustic.transientDensity > AcousticThresholds.intensityActive {
            return "动态强烈"
        }
        if let intensity = intent.intensity,
           intensity < 0.7,
           acoustic.transientDensity < AcousticThresholds.intensityActive {
            return "动态克制"
        }
        return nil
    }

    /// Exact-match evidence is deliberately limited to creator-visible naming fields. Tags and
    /// model metadata remain eligible for the broader association shelf, but must not receive the
    /// stronger “精确命中” label.
    static func directPathMatch(_ item: SoundItem, query: String) -> Bool {
        directPathMatchScore(item, query: query) > 0
    }

    static func directPathMatchScore(_ item: SoundItem, query: String) -> Int {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return 0 }
        let fileBases = [item.displayName, item.fileName].map {
            normalize(($0 as NSString).deletingPathExtension)
        }
        if fileBases.contains(normalizedQuery) { return 1_000 }
        if fileBases.contains(where: { $0.hasPrefix(normalizedQuery) }) { return 850 }
        if fileBases.contains(where: { $0.contains(normalizedQuery) }) { return 700 }

        // A shared collection folder such as “鸡鸭牛马羊” is contextual evidence, not an
        // exact match for every contained animal. Only the leaf folder can qualify here.
        let leafFolder = item.folderPath
            .split(separator: "/")
            .last
            .map { normalize(String($0)) } ?? ""
        if leafFolder == normalizedQuery { return 500 }
        if leafFolder.hasPrefix(normalizedQuery) { return 420 }
        return 0
    }

    /// Finds exact creator-visible hits without flattening the complete library into a second
    /// array. Callers run this off the main actor while Qwen is understanding the same query.
    static func directPathMatchIDs(in packs: [SoundPack], query: String) throws -> Set<UUID> {
        var result = Set<UUID>()
        var visited = 0
        for pack in packs {
            try Task.checkCancellation()
            for item in pack.items {
                if visited.isMultiple(of: 512) { try Task.checkCancellation() }
                if directPathMatch(item, query: query) { result.insert(item.id) }
                visited += 1
            }
        }
        return result
    }

    static func featuredIDs(
        in items: [SoundItem],
        expandedQuery: String,
        matches: LibrarySearchMatches,
        intelligenceByID: [UUID: AudioIntelligence] = [:],
        vocabulary: LibraryVocabulary? = nil
    ) -> [UUID] {
        let query = SoundSemanticEngine.query(expandedQuery)
        let terms = searchableTerms(in: expandedQuery, vocabulary: vocabulary)
        guard !query.isEmpty || !terms.isEmpty else { return [] }

        // 排除词别名展开，与 LocalLibraryView 的过滤层一致（修复英文文件名被"雨"字面漏检）。
        let excludedAliases = matches.intent.excludedTerms
            .flatMap(AISearchIntentParser.searchAliases)
            .map(normalize)
        let hasExclusion = !excludedAliases.isEmpty

        // 第一遍：计算四个信号的原始值，并按门禁筛选候选。
        var scored: [(item: SoundItem, semantic: Double, directory: Double, metadata: Double, acoustic: Double, excluded: Bool)] = []
        scored.reserveCapacity(items.count)
        for item in items {
            let semantic = min(
                1,
                (matches.semanticRelevanceByID[item.id] ?? 0) / SearchRankingWeights.semanticDenominator
            )
            let directory = directoryEvidence(for: item, query: query, terms: terms)
            let metadata = metadataEvidence(for: item, terms: terms)
            let acoustic = acousticEvidence(
                for: intelligenceByID[item.id]?.acousticFingerprint,
                intent: matches.intent
            )
            // A plain text hit is useful, but is deliberately not called an AI recommendation
            // unless it also has semantic or directory evidence.
            guard semantic >= SearchRankingWeights.semanticGate
                    || directory >= SearchRankingWeights.directoryGate else { continue }
            let haystack = normalize(
                ([item.displayName, item.fileName, item.folderPath] + item.tags).joined(separator: " ")
            )
            let excluded = hasExclusion && excludedAliases.contains(where: { haystack.contains($0) })
            scored.append((item, semantic, directory, metadata, acoustic, excluded))
        }

        // 集合内信号归一化：避免单一信号在结果集内的天然分布无形主导排序。范围过窄时
        // 保留原值，避免把噪声差异放大成决定性差异。
        let normalizedSemantic = normalizedSignal(scored.map(\.semantic))
        let normalizedDirectory = normalizedSignal(scored.map(\.directory))
        let normalizedMetadata = normalizedSignal(scored.map(\.metadata))
        let normalizedAcoustic = normalizedSignal(scored.map(\.acoustic))

        var scoredCombined: [(item: SoundItem, score: Double)] = []
        scoredCombined.reserveCapacity(scored.count)
        for (index, entry) in scored.enumerated() {
            let score = normalizedSemantic[index] * SearchRankingWeights.semanticWeight
                + normalizedDirectory[index] * SearchRankingWeights.directoryWeight
                + normalizedMetadata[index] * SearchRankingWeights.metadataWeight
                + normalizedAcoustic[index] * SearchRankingWeights.acousticWeight
            scoredCombined.append((entry.item, score))
        }

        // 排除词硬过滤：命中排除词的候选不进入推荐货架；仅当全部候选都被排除时
        // 回退到降权保底（× excludedPenalty），避免推荐货架空置。
        var eligible: [(item: SoundItem, score: Double)] = []
        var excludedCandidates: [(item: SoundItem, score: Double)] = []
        for (index, entry) in scoredCombined.enumerated() {
            if scored[index].excluded {
                excludedCandidates.append((entry.item, entry.score * SearchRankingWeights.excludedPenalty))
            } else {
                eligible.append((entry.item, entry.score))
            }
        }
        if eligible.isEmpty { eligible = excludedCandidates }

        // MMR 多样化：同目录/同命名家族的候选最多占推荐货架的指定份额，避免刷屏。
        let diversityLimit = max(1, featuredLimit / 3)
        var selected: [(item: SoundItem, score: Double)] = []
        var remaining = eligible.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.item.displayName.localizedStandardCompare(rhs.item.displayName) == .orderedAscending
        }
        var diversityCounts: [String: Int] = [:]
        while selected.count < featuredLimit, !remaining.isEmpty {
            let next = remaining.removeFirst()
            let key = diversityKey(for: next.item)
            if diversityCounts[key, default: 0] >= diversityLimit { continue }
            diversityCounts[key, default: 0] += 1
            selected.append(next)
        }
        // 若多样性饱和导致货架空置，回退为普通排序填充。
        if selected.isEmpty {
            selected = Array(eligible.sorted { $0.score > $1.score }.prefix(featuredLimit))
        }

        // 精确字面命中的加成（对已入选项）。
        for index in selected.indices where matches.literalIDs.contains(selected[index].item.id) {
            selected[index].score += SearchRankingWeights.literalBoost
        }
        return selected
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.item.displayName.localizedStandardCompare(rhs.item.displayName) == .orderedAscending
            }
            .prefix(featuredLimit)
            .map(\.item.id)
    }

    /// 集合内 min-max 归一化；当范围过窄（< 0.05）时保留原值。
    private static func normalizedSignal(_ values: [Double]) -> [Double] {
        guard let minimum = values.min(), let maximum = values.max(),
              maximum - minimum > 0.05 else { return values }
        let span = maximum - minimum
        return values.map { ($0 - minimum) / span }
    }

    /// MMR 多样化键：命名家族（去编号变体）优先，否则用目录。
    private static func diversityKey(for item: SoundItem) -> String {
        let profile = SoundSemanticEngine.profile(for: item)
        if let familyKey = profile.familyKey {
            return "family:" + familyKey
        }
        return "folder:" + item.folderPath
    }

    private static func acousticEvidence(
        for acoustic: AcousticFingerprint?,
        intent: AISearchIntent
    ) -> Double {
        guard let acoustic else { return SearchRankingWeights.acousticNeutralBaseline }
        let terms = intent.tonalQualities.map(\.term) + intent.dynamics.map(\.term)
        guard !terms.isEmpty else { return SearchRankingWeights.acousticNeutralBaseline }
        var scores: [Double] = []
        for rawTerm in terms {
            let term = rawTerm.lowercased()
            if ["低沉", "低频", "厚", "deep", "low"].contains(term) {
                scores.append(1 - min(1, Double(acoustic.spectralCentroid) / AcousticThresholds.centroidLowDenominator))
            } else if ["明亮", "尖锐", "bright", "sharp", "高频"].contains(term) {
                scores.append(min(1, Double(acoustic.spectralCentroid) / AcousticThresholds.centroidHighDenominator))
            } else if ["柔和", "轻柔", "克制", "soft", "gentle"].contains(term) {
                scores.append(1 - min(1, Double(acoustic.transientDensity) / AcousticThresholds.transientSoftDenominator))
            } else if ["短促", "冲击", "爆发", "short", "impact"].contains(term) {
                scores.append(min(1, Double(acoustic.transientDensity) / AcousticThresholds.transientSharpDenominator))
            }
        }
        if let intensity = intent.intensity {
            if intensity > 1.2 {
                scores.append(min(1, Double(acoustic.transientDensity) / AcousticThresholds.intensityDenominator))
            } else if intensity < 0.7 {
                scores.append(1 - min(1, Double(acoustic.transientDensity) / AcousticThresholds.intensityDenominator))
            }
        }
        return scores.isEmpty
            ? SearchRankingWeights.acousticNeutralBaseline
            : scores.reduce(0, +) / Double(scores.count)
    }

    /// Exposes the deterministic acoustic component to the in-process evaluation suite without
    /// making the ranking implementation or its thresholds part of the UI surface.
    static func acousticScoreForTesting(_ acoustic: AcousticFingerprint, intent: AISearchIntent) -> Double {
        acousticEvidence(for: acoustic, intent: intent)
    }

    private static func directoryEvidence(
        for item: SoundItem,
        query: SoundSemanticQuery,
        terms: [String]
    ) -> Double {
        let folders = item.folderPath
            .split(separator: "/")
            .map(String.init)
            .filter { !isGenericDirectory($0) }
        guard !folders.isEmpty else { return 0 }

        let folderConcepts = SoundSemanticEngine.query(folders.joined(separator: " ")).concepts
        let conceptScore = query.concepts.reduce(0.0) { score, entry in
            let folderWeight = folderConcepts[entry.key] ?? 0
            return score + min(entry.value, folderWeight)
        }
        let semanticEvidence = min(1, conceptScore / 1.25)

        let directEvidence = folders.enumerated().reduce(0.0) { score, entry in
            let normalizedFolder = normalize(entry.element)
            let matchingTerms = terms.filter { normalizedFolder.contains($0) }.count
            guard matchingTerms > 0 else { return score }
            // The leaf folder usually encodes use (for example UI/Risers); parent folders
            // provide context, but should not overwhelm a precise leaf match.
            let depthWeight = entry.offset == folders.count - 1 ? 1.0 : 0.58
            return score + min(1, Double(matchingTerms) * 0.45) * depthWeight
        }
        return min(1, semanticEvidence * 0.72 + min(1, directEvidence) * 0.28)
    }

    private static func metadataEvidence(for item: SoundItem, terms: [String]) -> Double {
        guard !terms.isEmpty else { return 0 }
        let haystack = normalize(([item.displayName, item.fileName] + item.tags).joined(separator: " "))
        let matches = terms.filter { haystack.contains($0) }.count
        return min(1, Double(matches) / 2.0)
    }

    private static func searchableTerms(
        in value: String,
        vocabulary: LibraryVocabulary? = nil
    ) -> [String] {
        let normalized = normalize(value)
        var terms = normalized
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 2 && !ignoredTerms.contains($0) }

        // Chinese directory names are often short semantic units (科技、上升、片头). Add
        // character n-grams so a phrase from Qwen can still recognize those folder names.
        // When the real library vocabulary is available, only n-grams that actually exist in
        // the library are kept — invented splits ("远雷", "处雷") would otherwise dilute the
        // precise results with noise.
        for word in terms where word.unicodeScalars.allSatisfy(isCJK) {
            let characters = Array(word)
            guard characters.count >= 2 else { continue }
            for length in 2...min(4, characters.count) {
                for start in 0...(characters.count - length) {
                    let term = String(characters[start..<(start + length)])
                    guard !ignoredTerms.contains(term) else { continue }
                    if let vocabulary, !vocabulary.isKnown(term) { continue }
                    terms.append(term)
                }
            }
        }

        var seen = Set<String>()
        return terms.filter { seen.insert($0).inserted }
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func isCJK(_ scalar: UnicodeScalar) -> Bool {
        (0x3400...0x4DBF).contains(scalar.value)
            || (0x4E00...0x9FFF).contains(scalar.value)
            || (0xF900...0xFAFF).contains(scalar.value)
    }

    private static func isGenericDirectory(_ value: String) -> Bool {
        ignoredTerms.contains(normalize(value))
    }

    private static let ignoredTerms: Set<String> = [
        "audio", "audios", "sound", "sounds", "sfx", "fx", "files", "file", "export",
        "exports", "new", "folder", "untitled", "素材", "音频", "音效", "文件", "文件夹",
        "导出", "未命名", "全部", "其他"
    ]
}
