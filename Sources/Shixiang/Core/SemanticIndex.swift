import Foundation

enum LibrarySearchMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case hybrid
    case literal

    var id: String { rawValue }
    var title: String { self == .hybrid ? "语义 + 原名" : "仅匹配原文" }
    var systemImage: String { self == .hybrid ? "sparkles" : "text.magnifyingglass" }
}

struct SemanticIndexProgress: Equatable, Sendable {
    let completed: Int
    let total: Int

    var fraction: Double? {
        guard total > 0 else { return nil }
        return min(max(Double(completed) / Double(total), 0), 1)
    }
}

struct LibrarySearchMatches: Sendable {
    let ids: Set<UUID>
    /// IDs found by a direct file name, tag, or directory-path match. These remain the
    /// transparent "文字命中" tail when local AI search surfaces its curated top results.
    let literalIDs: Set<UUID>
    let relevanceByID: [UUID: Double]
    /// Semantic evidence before the literal-match boost is applied. The local AI ranking uses
    /// this to distinguish genuinely understood matches from coincidental text hits.
    let semanticRelevanceByID: [UUID: Double]
    let semanticMatchCount: Int
    let conceptTitles: [String]
    let creatorIntent: CreatorSearchIntent
    let intent: AISearchIntent

    init(
        ids: Set<UUID>,
        literalIDs: Set<UUID> = [],
        relevanceByID: [UUID: Double],
        semanticRelevanceByID: [UUID: Double] = [:],
        semanticMatchCount: Int,
        conceptTitles: [String],
        creatorIntent: CreatorSearchIntent = .empty,
        intent: AISearchIntent = .empty
    ) {
        self.ids = ids
        self.literalIDs = literalIDs
        self.relevanceByID = relevanceByID
        self.semanticRelevanceByID = semanticRelevanceByID
        self.semanticMatchCount = semanticMatchCount
        self.conceptTitles = conceptTitles
        self.creatorIntent = creatorIntent
        self.intent = intent
    }

    static let empty = LibrarySearchMatches(
        ids: [],
        literalIDs: [],
        relevanceByID: [:],
        semanticRelevanceByID: [:],
        semanticMatchCount: 0,
        conceptTitles: [],
        intent: .empty
    )
}

struct CreatorSearchIntent: Equatable, Sendable {
    let minimumDuration: TimeInterval?
    let maximumDuration: TimeInterval?
    let contextTitles: [String]

    static let empty = CreatorSearchIntent(
        minimumDuration: nil,
        maximumDuration: nil,
        contextTitles: []
    )

    var hasExplicitDuration: Bool { minimumDuration != nil || maximumDuration != nil }
}

struct SoundSimilarityIndexCandidate: Sendable {
    let soundID: UUID
    let semanticScore: Double
    let sharedConceptIDs: [String]
    let isSameFamily: Bool
}

struct SoundSimilarityMatch: Identifiable, Sendable {
    let item: SoundItem
    let score: Double
    let reasons: [String]
    let isSameFamily: Bool

    var id: UUID { item.id }
}

struct MetadataSuggestionCandidate: Identifiable, Sendable {
    let item: SoundItem
    let suggestion: SoundMetadataSuggestion

    var id: UUID { item.id }
    var changesName: Bool {
        item.customName?.trimmingCharacters(in: .whitespacesAndNewlines)
            != suggestion.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var changesTags: Bool {
        SoundItem.normalizedTags(item.tags + suggestion.tags) != item.tags
    }
    var hasChanges: Bool { changesName || changesTags }
}

struct MetadataUndoChange: Codable, Hashable, Sendable {
    let soundID: UUID
    let previousName: String?
    let previousTags: [String]
    let appliedName: String?
    let appliedTags: [String]
}

struct MetadataUndoBatch: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let createdAt: Date
    let changes: [MetadataUndoChange]

    init(id: UUID = UUID(), createdAt: Date = Date(), changes: [MetadataUndoChange]) {
        self.id = id
        self.createdAt = createdAt
        self.changes = changes
    }
}

struct SoundSemanticProfile: Sendable {
    let concepts: [String: Double]
    let familyKey: String?
    let familyTitle: String?
}

struct SoundSemanticQuery: Sendable {
    let concepts: [String: Double]
    let conceptTitles: [String]
    let creatorIntent: CreatorSearchIntent
    let intent: AISearchIntent
    var isEmpty: Bool { concepts.isEmpty }
}

enum SoundSemanticEngine {
    static let indexVersion = 3

    static func profile(for item: SoundItem) -> SoundSemanticProfile {
        let normalized = normalize(item.searchableText)
        var concepts = taxonomyConcepts(in: normalized)
        for qualifier in qualifiers where qualifier.matches(normalized) {
            concepts[qualifier.id] = max(concepts[qualifier.id] ?? 0, qualifier.weight)
        }
        if item.duration > 0, item.duration < 5 {
            concepts["q:short"] = max(concepts["q:short"] ?? 0, 0.42)
        } else if item.duration >= 20 {
            concepts["q:long"] = max(concepts["q:long"] ?? 0, 0.42)
        }
        let family = familyIdentity(for: item)
        return SoundSemanticProfile(
            concepts: concepts,
            familyKey: family?.key,
            familyTitle: family?.title
        )
    }

    static func query(_ value: String) -> SoundSemanticQuery {
        let normalized = normalize(value)
        guard !normalized.trimmingCharacters(in: .whitespaces).isEmpty else {
            return SoundSemanticQuery(concepts: [:], conceptTitles: [], creatorIntent: .empty, intent: .empty)
        }
        var concepts = taxonomyConcepts(in: normalized)
        for qualifier in qualifiers where qualifier.matches(normalized) {
            concepts[qualifier.id] = max(concepts[qualifier.id] ?? 0, qualifier.queryWeight)
        }
        let creator = creatorIntent(for: value, normalized: normalized)
        let intent = AISearchIntentParser.parse(value)
        for (concept, weight) in creator.concepts {
            concepts[concept] = max(concepts[concept] ?? 0, weight)
        }
        let titles = (concepts.keys
            .compactMap(conceptTitle)
            + creator.intent.contextTitles)
            + intent.displayTitles
            .uniqued()
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return SoundSemanticQuery(
            concepts: concepts,
            conceptTitles: titles,
            creatorIntent: creator.intent,
            intent: intent
        )
    }

    static func metadataSuggestion(
        for item: SoundItem,
        namingProfile: JacksunNamingProfile = .default
    ) -> SoundMetadataSuggestion {
        let stem = (item.fileName as NSString).deletingPathExtension
        let cleanedName = cleanDisplayName(stem)
        let normalized = normalize(item.searchableText)
        let classification = SmartTaxonomy.classify(normalizedText: normalized)
        let detail = SmartCollection.categorizedCases
            .compactMap { classification.details[$0] }
            .first { !$0.isFallback }
        let matchedQualifiers = qualifiers.filter {
            $0.includeInName && $0.matches(normalized)
        }

        let chineseName = chineseDisplayName(from: cleanedName)
        let containsChinese = !chineseName.isEmpty
        let sequence = trailingSequence(in: stem)
        let generatedCore = detail?.semanticAliasName
        let qualifierTitles = matchedQualifiers
            .map(\.title)
            .filter { generatedCore?.contains($0) != true }
            .uniqued()
            .prefix(2)
        let generatedName = (
            [String](qualifierTitles)
                + [generatedCore].compactMap { $0 }
                + [sequence].compactMap { $0 }
        ).joined(separator: " ")
        let looksGenerated = UUID(uuidString: stem) != nil || cleanedName.count > 70

        let displayName: String
        if containsChinese, !looksGenerated, !isGenericChineseName(chineseName) {
            // A bilingual production filename already contains a useful Chinese identity.
            // Keep that identity, but remove the duplicated English tail and stock number.
            displayName = chineseName
        } else if !generatedName.isEmpty {
            displayName = generatedName
        } else if looksGenerated {
            let folder = item.folderPath.split(separator: "/").last.map(String.init)
            displayName = folder.map { "\($0) · 音效" } ?? "未命名音效"
        } else {
            displayName = cleanedName.isEmpty ? item.fileName : cleanedName
        }

        var tags: [String] = []
        if let detail {
            tags.append(detail.parent.shortTag)
            tags.append(detail.semanticAliasName)
        } else {
            tags.append(contentsOf: classification.parents.map(\.shortTag))
        }
        tags.append(contentsOf: matchedQualifiers.map(\.title))
        tags.append(contentsOf: item.folderPath.split(separator: "/").suffix(2).compactMap {
            let value = String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty || value.count > 18 ? nil : value
        })

        let confidence: Double
        if detail != nil, !matchedQualifiers.isEmpty {
            confidence = 0.92
        } else if detail != nil {
            confidence = 0.80
        } else if !classification.parents.isEmpty {
            confidence = 0.62
        } else {
            confidence = 0.36
        }

        var reasons: [String] = []
        if let detail { reasons.append("识别为\(detail.title)") }
        if !matchedQualifiers.isEmpty {
            reasons.append("识别到\(matchedQualifiers.map(\.title).joined(separator: "、"))")
        }
        if reasons.isEmpty { reasons.append("清理原文件名与目录信息") }

        return SoundMetadataSuggestion(
            displayName: namingProfile.personalizedName(
                baseName: displayName,
                searchableText: item.searchableText
            ),
            tags: SoundItem.normalizedTags(tags),
            confidence: confidence,
            reasons: reasons
        )
    }

    static func conceptTitle(_ id: String) -> String? {
        if id.hasPrefix("parent:"),
           let value = SmartCollection(rawValue: String(id.dropFirst("parent:".count))) {
            return value.shortTag
        }
        if id.hasPrefix("detail:"),
           let value = SmartSubcollection(rawValue: String(id.dropFirst("detail:".count))) {
            return value.semanticAliasName
        }
        return qualifiers.first(where: { $0.id == id })?.title
    }

    private static func creatorIntent(
        for original: String,
        normalized: String
    ) -> (concepts: [String: Double], intent: CreatorSearchIntent) {
        struct SceneMapping {
            let terms: [String]
            let title: String
            let concepts: [String]
        }
        let mappings: [SceneMapping] = [
            .init(
                terms: ["推进镜头", "推镜头", "镜头推进", "push in", "dolly in", "reveal", "揭晓"],
                title: "推进 / 揭晓",
                concepts: ["detail:\(SmartSubcollection.transitionRiser.rawValue)", "detail:\(SmartSubcollection.impactCinematic.rawValue)"]
            ),
            .init(
                terms: ["拉远镜头", "拉镜头", "镜头拉远", "pull out", "dolly out"],
                title: "镜头拉远",
                concepts: ["detail:\(SmartSubcollection.transitionDowner.rawValue)"]
            ),
            .init(
                terms: ["切镜", "切换画面", "快速切换", "hard cut", "match cut"],
                title: "切镜",
                concepts: ["detail:\(SmartSubcollection.transitionWhoosh.rawValue)", "detail:\(SmartSubcollection.impactHit.rawValue)"]
            ),
            .init(
                terms: ["落版", "产品结尾", "品牌结尾", "片尾定格", "end card", "logo reveal"],
                title: "结尾落版",
                concepts: ["detail:\(SmartSubcollection.musicStinger.rawValue)", "detail:\(SmartSubcollection.technologyNotification.rawValue)"]
            ),
            .init(
                terms: ["慢镜头", "升格", "slow motion"],
                title: "慢镜头",
                concepts: ["q:long", "q:slow"]
            ),
            .init(
                terms: ["悬疑", "疑云", "suspense", "thriller"],
                title: "悬疑",
                concepts: ["q:dark", "detail:\(SmartSubcollection.ambienceDark.rawValue)"]
            ),
            .init(
                terms: ["史诗", "恢弘", "epic", "heroic"],
                title: "史诗",
                concepts: ["q:epic", "detail:\(SmartSubcollection.musicCinematic.rawValue)"]
            ),
            .init(
                terms: ["紧张", "压迫", "tense", "urgent"],
                title: "紧张",
                concepts: ["q:tense", "q:hard"]
            ),
            .init(
                terms: ["温暖", "治愈", "warm", "heartwarming"],
                title: "温暖",
                concepts: ["q:warm", "q:soft"]
            ),
            .init(
                terms: ["咖啡馆约会", "咖啡店约会", "cafe date", "coffee date"],
                title: "咖啡馆约会",
                concepts: ["detail:\(SmartSubcollection.ambienceCrowd.rawValue)", "q:cafe", "q:romantic", "q:soft"]
            ),
            .init(
                terms: ["约会", "date", "dating", "情侣", "两个人聊天", "两人聊天"],
                title: "约会氛围",
                concepts: ["q:romantic", "q:soft"]
            ),
            .init(
                terms: ["浪漫", "爱情", "romantic", "love"],
                title: "浪漫",
                concepts: ["q:romantic", "q:soft"]
            ),
            .init(
                terms: ["空灵", "梦境", "ethereal", "dreamy"],
                title: "空灵",
                concepts: ["q:airy", "detail:\(SmartSubcollection.musicAmbient.rawValue)"]
            )
        ]

        var concepts: [String: Double] = [:]
        var contextTitles: [String] = []
        for mapping in mappings where mapping.terms.contains(where: {
            normalized.contains(normalize($0).trimmingCharacters(in: .whitespaces))
        }) {
            contextTitles.append(mapping.title)
            for concept in mapping.concepts { concepts[concept] = max(concepts[concept] ?? 0, 1.12) }
        }
        let duration = explicitDurationIntent(in: original)
        if let title = duration.title { contextTitles.append(title) }
        return (
            concepts,
            CreatorSearchIntent(
                minimumDuration: duration.minimum,
                maximumDuration: duration.maximum,
                contextTitles: contextTitles.uniqued()
            )
        )
    }

    private static func explicitDurationIntent(
        in value: String
    ) -> (minimum: TimeInterval?, maximum: TimeInterval?, title: String?) {
        let number = #"([0-9]+(?:\.[0-9]+)?|一|二|两|三|四|五|六|七|八|九|十)"#
        if let captures = captures(pattern: number + #"\s*(?:到|至|[-–—])\s*"# + number + #"\s*秒"#, in: value),
           let minimum = durationNumber(captures[0]),
           let maximum = durationNumber(captures[1]) {
            return (min(minimum, maximum), max(minimum, maximum), "\(minimum.formatted())–\(maximum.formatted()) 秒")
        }
        if let captures = captures(pattern: #"(?:至少|不短于)\s*"# + number + #"\s*秒|"# + number + #"\s*秒\s*(?:以上|起)"#, in: value),
           let raw = captures.first(where: { !$0.isEmpty }),
           let minimum = durationNumber(raw) {
            return (minimum, nil, "≥ \(minimum.formatted()) 秒")
        }
        if let captures = captures(pattern: #"(?:不超过|少于|短于)\s*"# + number + #"\s*秒|"# + number + #"\s*秒\s*(?:以内|以下|内)"#, in: value),
           let raw = captures.first(where: { !$0.isEmpty }),
           let maximum = durationNumber(raw) {
            return (nil, maximum, "≤ \(maximum.formatted()) 秒")
        }
        return (nil, nil, nil)
    }

    private static func captures(pattern: String, in value: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = expression.firstMatch(in: value, range: range) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            let capture = match.range(at: index)
            guard capture.location != NSNotFound, let range = Range(capture, in: value) else { return "" }
            return String(value[range])
        }
    }

    private static func durationNumber(_ value: String) -> Double? {
        if let number = Double(value) { return number }
        return ["一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
                "六": 6, "七": 7, "八": 8, "九": 9, "十": 10][value].map(Double.init)
    }

    private static func taxonomyConcepts(in normalized: String) -> [String: Double] {
        let classification = SmartTaxonomy.classify(normalizedText: normalized)
        var result: [String: Double] = [:]
        for parent in classification.parents where parent != .untagged {
            result["parent:\(parent.rawValue)"] = 0.58
            if let detail = classification.details[parent], !detail.isFallback {
                result["detail:\(detail.rawValue)"] = 1
            }
        }
        return result
    }

    private static func familyIdentity(for item: SoundItem) -> (key: String, title: String)? {
        let stem = (item.fileName as NSString).deletingPathExtension
        let normalizedStem = normalize(stem).trimmingCharacters(in: .whitespaces)
        guard !normalizedStem.isEmpty else { return nil }

        let removableLatin = Set([
            "v", "ver", "version", "take", "tk", "alt", "alternate", "variation", "var",
            "far", "near", "close", "soft", "hard", "light", "heavy", "short", "long",
            "fast", "slow", "low", "high", "up", "down", "mono", "stereo", "dry", "wet"
        ])
        let removableChinese = [
            "远处", "远景", "近处", "近景", "轻柔", "强烈", "短促", "悠长", "快速", "缓慢",
            "低沉", "高频", "单声道", "立体声", "干声", "湿声", "版本", "变体", "备用"
        ]

        var didRemoveVariant = false
        var baseTokens: [String] = []
        for rawToken in normalizedStem.split(separator: " ").map(String.init) {
            var token = rawToken
            if isVariantSequenceToken(token) || removableLatin.contains(token) {
                didRemoveVariant = true
                continue
            }
            for word in removableChinese where token.contains(word) {
                token = token.replacingOccurrences(of: word, with: "")
                didRemoveVariant = true
            }
            let withoutNumbers = String(token.filter { !$0.isNumber })
            if withoutNumbers != token { didRemoveVariant = true }
            token = withoutNumbers.trimmingCharacters(in: .whitespaces)
            if !token.isEmpty { baseTokens.append(token) }
        }

        guard didRemoveVariant else { return nil }
        let base = baseTokens.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard base.count >= 2 else { return nil }
        let folder = normalize(item.folderPath).trimmingCharacters(in: .whitespaces)
        return (
            "\(item.packageID.uuidString)|\(folder)|\(base)",
            cleanDisplayName(base)
        )
    }

    private static func cleanDisplayName(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        var lastWasSpace = true
        for character in value {
            if character == "_" || character == "-" || character.isWhitespace {
                if !lastWasSpace {
                    result.append(" ")
                    lastWasSpace = true
                }
            } else {
                result.append(character)
                lastWasSpace = false
            }
        }
        if result.last == " " { result.removeLast() }
        return result
    }

    private static func chineseDisplayName(from value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        var lastWasSpace = true
        for character in value {
            let isChinese = character.unicodeScalars.contains {
                (0x3400...0x4DBF).contains($0.value)
                    || (0x4E00...0x9FFF).contains($0.value)
                    || (0xF900...0xFAFF).contains($0.value)
            }
            if isChinese {
                result.append(character)
                lastWasSpace = false
            } else if !lastWasSpace {
                result.append(" ")
                lastWasSpace = true
            }
        }
        if result.last == " " { result.removeLast() }
        return result
    }

    private static func isGenericChineseName(_ value: String) -> Bool {
        let compact = value.replacingOccurrences(of: " ", with: "")
        return ["氛围", "音效", "声音", "环境", "汽车", "音乐", "科技", "拟音"].contains(compact)
    }

    private static func trailingSequence(in value: String) -> String? {
        guard let rawToken = value.split(whereSeparator: {
            $0 == "_" || $0 == "-" || $0.isWhitespace
        }).last else { return nil }
        var token = String(rawToken).lowercased()
        for prefix in ["version", "take", "ver", "alt", "var", "tk", "v"]
        where token.hasPrefix(prefix) {
            token.removeFirst(prefix.count)
            break
        }
        guard (1...3).contains(token.count), token.allSatisfy(\.isNumber) else { return nil }
        return token
    }

    private static func isVariantSequenceToken(_ value: String) -> Bool {
        var token = value
        for prefix in ["version", "take", "ver", "alt", "var", "tk", "v"]
        where token.hasPrefix(prefix) {
            token.removeFirst(prefix.count)
            break
        }
        return (1...4).contains(token.count) && token.allSatisfy(\.isNumber)
    }

    private static func normalize(_ value: String) -> String {
        let folded = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        var result = " "
        var lastWasSpace = true
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                result.append(" ")
                lastWasSpace = true
            }
        }
        if !lastWasSpace { result.append(" ") }
        return result
    }

    private static let qualifiers: [SemanticQualifier] = [
        .init(id: "q:far", title: "远处", terms: ["far", "distant", "distance", "远处", "远景", "远距离"]),
        .init(id: "q:near", title: "近处", terms: ["near", "close", "closeup", "近处", "近景", "贴近"]),
            .init(id: "q:indoor", title: "室内", terms: ["indoor", "interior", "room", "室内", "房间"]),
        .init(
            id: "q:cafe",
            title: "咖啡馆",
            terms: ["cafe", "coffee shop", "coffeehouse", "coffee room", "咖啡馆", "咖啡店"],
            queryWeight: 1.18
        ),
        .init(id: "q:outdoor", title: "室外", terms: ["outdoor", "exterior", "outside", "室外", "户外"]),
        .init(id: "q:night", title: "夜晚", terms: ["night", "midnight", "evening", "夜晚", "夜间", "深夜"]),
        .init(id: "q:day", title: "白天", terms: ["day", "daytime", "morning", "白天", "日间", "清晨"]),
        .init(id: "q:soft", title: "轻柔", terms: ["soft", "gentle", "subtle", "quiet", "轻柔", "轻微", "安静"]),
        .init(id: "q:hard", title: "强烈", terms: ["hard", "strong", "aggressive", "intense", "强烈", "猛烈", "有力"]),
        .init(id: "q:dark", title: "暗黑", terms: ["dark", "eerie", "horror", "暗黑", "阴暗", "恐怖"]),
        .init(id: "q:bright", title: "明亮", terms: ["bright", "shiny", "sparkle", "明亮", "清脆", "闪耀"]),
        .init(id: "q:fast", title: "快速", terms: ["fast", "quick", "rapid", "speed", "快速", "急促", "高速"]),
        .init(id: "q:slow", title: "缓慢", terms: ["slow", "gentle pace", "缓慢", "慢速"]),
        .init(id: "q:low", title: "低沉", terms: ["low", "deep", "bass", "sub", "低沉", "低频", "低音"]),
        .init(id: "q:high", title: "高频", terms: ["high", "treble", "sharp", "高频", "高音", "尖锐"]),
        .init(id: "q:short", title: "短促", terms: ["short", "one shot", "oneshot", "instant", "短促", "瞬时", "极短"]),
        .init(id: "q:long", title: "悠长", terms: ["long", "sustain", "extended", "悠长", "延伸", "持续"]),
        .init(id: "q:metal", title: "金属", terms: ["metal", "metallic", "steel", "金属", "钢铁"]),
        .init(id: "q:wood", title: "木质", terms: ["wood", "wooden", "timber", "木质", "木头", "木板"]),
        .init(id: "q:glass", title: "玻璃", terms: ["glass", "crystal", "玻璃", "水晶"]),
        .init(id: "q:wet", title: "潮湿", terms: ["wet", "moist", "潮湿", "湿润"]),
        .init(id: "q:dry", title: "干燥", terms: ["dry", "clean", "干燥", "干声"]),
        .init(id: "q:heavy", title: "厚重", terms: ["heavy", "massive", "huge", "厚重", "巨大", "沉重"]),
        .init(id: "q:light", title: "轻盈", terms: ["light", "tiny", "delicate", "轻盈", "细小", "轻巧"]),
        .init(id: "q:retro", title: "复古", terms: ["retro", "vintage", "old", "analog", "复古", "老式", "模拟"]),
        .init(id: "q:warm", title: "温暖", terms: ["warm", "heartwarming", "温暖", "治愈", "暖意"]),
        .init(id: "q:romantic", title: "浪漫", terms: ["romantic", "love", "浪漫", "爱情"]),
        .init(id: "q:tense", title: "紧张", terms: ["tense", "urgent", "tension", "紧张", "压迫", "急迫"]),
        .init(id: "q:epic", title: "史诗", terms: ["epic", "heroic", "史诗", "恢弘", "宏大"]),
        .init(id: "q:airy", title: "空灵", terms: ["ethereal", "airy", "dreamy", "空灵", "梦境", "漂浮"]),
        .init(
            id: "q:traditionalChinese",
            title: "古风",
            terms: [
                "古风", "古筝", "古琴", "古韵", "古意", "古色", "东方", "国风",
                "guzheng", "guqin", "traditional chinese", "chinese traditional", "oriental"
            ],
            weight: 0.86,
            queryWeight: 1.12
        )
    ]
}

private struct SemanticQualifier: Sendable {
    let id: String
    let title: String
    let terms: [String]
    var weight: Double = 0.72
    var queryWeight: Double = 1
    var includeInName: Bool = true

    func matches(_ normalized: String) -> Bool {
        terms.contains {
            let value = $0.lowercased()
            let shortLatin = value.utf8.count <= 3
                && value.unicodeScalars.allSatisfy {
                    $0.isASCII && CharacterSet.letters.contains($0)
                }
            return normalized.contains(shortLatin ? " \(value) " : value)
        }
    }
}

extension SmartSubcollection {
    var semanticAliasName: String {
        switch self {
        case .transitionRiser: return "上升转场"
        case .transitionDowner: return "下降转场"
        case .transitionPassBy: return "掠过"
        case .transitionReverse: return "反转回吸"
        case .transitionSweep: return "扫频切换"
        case .transitionWhoosh: return "呼啸转场"
        case .transitionOther: return "转场音效"
        case .ambienceWeather: return "天气环境"
        case .ambienceWind: return "风声"
        case .ambienceWater: return "水流环境"
        case .ambienceNature: return "自然环境"
        case .ambienceCity: return "城市环境"
        case .ambienceInterior: return "室内环境"
        case .ambienceCrowd: return "人群环境"
        case .ambienceDark: return "暗氛围"
        case .ambienceOther: return "环境音"
        case .impactExplosion: return "爆炸"
        case .impactBoom: return "低频轰鸣"
        case .impactMetal: return "金属撞击"
        case .impactBreak: return "破碎"
        case .impactPunch: return "猛击"
        case .impactCinematic: return "电影重击"
        case .impactHit: return "冲击"
        case .impactOther: return "冲击音效"
        case .foleyFootsteps: return "脚步"
        case .foleyDoors: return "门窗"
        case .foleyCloth: return "衣物摩擦"
        case .foleyHands: return "手部动作"
        case .foleyObjects: return "道具拟音"
        case .foleyKitchen: return "厨房餐具"
        case .foleyVehicles: return "车辆引擎"
        case .foleyWeapons: return "武器"
        case .foleyMovement: return "动作移动"
        case .foleyOther: return "拟音"
        case .voiceDialogue: return "对白"
        case .voiceShout: return "喊叫"
        case .voiceReaction: return "人物反应"
        case .voiceCrowd: return "人群欢呼"
        case .voiceCreature: return "生物声音"
        case .voiceChoir: return "吟唱合唱"
        case .voiceChild: return "儿童声音"
        case .voiceMale: return "男声"
        case .voiceFemale: return "女声"
        case .voiceOther: return "人声"
        case .musicLoop: return "音乐循环"
        case .musicStinger: return "片头短乐句"
        case .musicPiano: return "钢琴"
        case .musicStrings: return "弦乐"
        case .musicGuitar: return "吉他贝斯"
        case .musicPercussion: return "鼓与打击乐"
        case .musicElectronic: return "电子合成器"
        case .musicCinematic: return "电影配乐"
        case .musicAmbient: return "氛围音乐"
        case .musicOther: return "音乐"
        case .technologyClick: return "界面点击"
        case .technologyNotification: return "通知提示"
        case .technologyGlitch: return "数字故障"
        case .technologyComputer: return "电脑键盘"
        case .technologySciFi: return "未来科技"
        case .technologyGame: return "游戏界面"
        case .technologyScan: return "扫描雷达"
        case .technologyPower: return "启动电源"
        case .technologyOther: return "科技音效"
        }
    }
}

private extension Array where Element == String {
    func uniqued() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
