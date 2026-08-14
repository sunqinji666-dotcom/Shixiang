import Foundation

/// A bounded, local-only representation of what a creator asked for. The model may suggest
/// words, but this value is normalized and validated by deterministic Swift code before it can
/// influence retrieval or filtering.
struct AISearchWeightedTerm: Codable, Equatable, Sendable, Hashable {
    let term: String
    let weight: Double

    init(term: String, weight: Double = 1) {
        self.term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        self.weight = min(1.5, max(0.1, weight.isFinite ? weight : 1))
    }
}

struct AISearchIntent: Codable, Equatable, Sendable {
    var soundTypes: [AISearchWeightedTerm] = []
    var useCases: [AISearchWeightedTerm] = []
    var emotions: [AISearchWeightedTerm] = []
    var materials: [AISearchWeightedTerm] = []
    var spaces: [AISearchWeightedTerm] = []
    var distances: [AISearchWeightedTerm] = []
    var dynamics: [AISearchWeightedTerm] = []
    var tonalQualities: [AISearchWeightedTerm] = []
    var requiredTerms: [String] = []
    var preferredTerms: [String] = []
    var excludedTerms: [String] = []
    var minimumDuration: TimeInterval?
    var maximumDuration: TimeInterval?
    var targetDuration: TimeInterval?
    /// 0 is restrained, 1 is neutral, 2 is forceful. It is a ranking hint, never a hard gate.
    var intensity: Double?
    var confidence: Double = 0
    /// Human-readable diagnostics for mutually incompatible creator constraints. These are
    /// local parser evidence, never model-generated claims, and are intentionally bounded.
    var conflicts: [String] = []

    static let empty = AISearchIntent()

    var positiveTerms: [String] {
        (soundTypes + useCases + emotions + materials + spaces + distances + dynamics + tonalQualities)
            .map(\.term) + requiredTerms + preferredTerms
    }

    var displayTitles: [String] {
        let negativeKeys = Set(excludedTerms.map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased() })
        let values = positiveTerms.filter { !$0.isEmpty }
        var seen = Set<String>()
        let positive = values.filter {
            let key = $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
            return !negativeKeys.contains(key) && seen.insert(key).inserted
        }
        let negative = excludedTerms.map { "不要\($0)" }
        return Array((positive + negative).prefix(6))
    }

    var hasConflicts: Bool { !conflicts.isEmpty }
}

enum AISearchIntentParser {
    static func searchAliases(for term: String) -> [String] {
        let key = term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
        switch key {
        case "雨": return ["雨", "rain", "drizzle", "storm", "shower"]
        case "雷声": return ["雷声", "thunder", "thunderstorm"]
        case "咖啡馆": return ["咖啡馆", "咖啡店", "cafe", "coffee shop", "coffeehouse"]
        case "人群": return ["人群", "crowd", "ambience", "public"]
        case "掌声": return ["掌声", "applause", "clap", "clapping"]
        case "脚步": return ["脚步", "footstep", "footsteps", "walk", "walking"]
        case "开门", "推开": return ["开门", "推开", "door open", "door_open", "opening door"]
        case "关门": return ["关门", "door close", "door_close", "closing door", "slam door"]
        case "冲击": return ["冲击", "impact", "hit", "slam"]
        case "上升": return ["上升", "riser", "rise", "uplifter", "whoosh up"]
        case "科技": return ["科技", "技术", "technology", "tech", "电子", "electronic", "electronics", "interface", "sci-fi", "sci fi"]
        case "金属": return ["金属", "metal", "metallic", "steel"]
        case "木质", "木头": return ["木质", "木头", "wood", "wooden", "timber"]
        default: return [term]
        }
    }

    static func parse(_ value: String) -> AISearchIntent {
        let original = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return .empty }
        let normalized = normalize(original)
        var intent = AISearchIntent()

        func terms(_ values: [String]) -> [AISearchWeightedTerm] {
            values.filter { normalized.contains(normalize($0)) }.map { AISearchWeightedTerm(term: $0) }
        }

        intent.soundTypes = terms([
            "环境", "氛围", "转场", "呼啸", "上升", "下降", "冲击", "爆炸", "脚步", "开门",
            "关门", "推开", "科技", "对白", "聊天", "人群", "掌声", "雷声", "雨", "提示音", "通知", "UI", "音乐", "rain", "cafe"
        ])
        intent.useCases = terms([
            "产品结尾落版", "落版", "Logo", "推镜", "拉镜", "切镜", "慢镜头", "空镜", "预告", "约会", "date"
        ])
        intent.emotions = terms([
            "紧张", "治愈", "压迫", "浪漫", "神秘", "史诗", "轻松", "危险", "克制", "温暖", "romantic", "tense"
        ])
        intent.materials = terms(["金属", "木质", "木头", "玻璃", "纸张", "布料", "液体", "机械", "电子", "metal", "wood"])
        intent.spaces = terms(["室内", "室外", "走廊", "地下", "城市", "自然", "空旷", "狭窄", "咖啡馆", "cafe", "city"])
        intent.distances = terms(["贴耳", "近处", "中景", "远处", "由远及近", "由近及远", "far", "near", "distant"])
        intent.dynamics = terms(["上升", "下降", "推进", "爆发", "渐弱", "突然停止", "持续", "脉冲", "短促", "riser"])
        intent.tonalQualities = terms(["明亮", "低沉", "厚", "薄", "干净", "粗糙", "柔和", "尖锐", "bright", "deep", "soft", "sharp"])

        let negativeMarkers = ["不要", "别", "排除", "不要有", "不能有", "无", "非", "not", "without", "no"]
        let softNegativeMarkers = ["不要太", "没那么", "不要过于", "not too", "less"]
        let allTerms = intent.positiveTerms
        for term in allTerms {
            let token = normalize(term)
            if softNegativeMarkers.contains(where: { normalized.contains(normalize($0) + token) }) {
                intent.excludedTerms.append(term)
                continue
            }
            if negativeMarkers.contains(where: { marker in
                normalized.range(of: normalize(marker) + token) != nil
                    || normalized.range(of: normalize(marker) + " " + token) != nil
            }) {
                intent.excludedTerms.append(term)
            }
        }
        intent.excludedTerms = unique(intent.excludedTerms)
        // Preserve explicit negative nouns even when they are not part of the positive
        // whitelist (for example “雷声，不要雨”). This remains bounded to the short clause
        // immediately following a negation marker.
        let negativePattern = #"(?:不要|别|排除|without|no)\s*([\p{Han}\p{Latin}]{1,12})"#
        if let expression = try? NSRegularExpression(pattern: negativePattern, options: [.caseInsensitive]) {
            let range = NSRange(original.startIndex..<original.endIndex, in: original)
            for match in expression.matches(in: original, range: range) {
                guard match.numberOfRanges > 1, let captureRange = Range(match.range(at: 1), in: original) else { continue }
                let noun = String(original[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !noun.isEmpty { intent.excludedTerms.append(noun) }
            }
        }
        intent.excludedTerms = unique(intent.excludedTerms)
        let excluded = Set(intent.excludedTerms.map(normalize))
        intent.requiredTerms = unique(intent.soundTypes.map(\.term) + intent.materials.map(\.term) + intent.dynamics.map(\.term))
            .filter { !excluded.contains(normalize($0)) }
        intent.preferredTerms = unique(intent.emotions.map(\.term) + intent.spaces.map(\.term) + intent.tonalQualities.map(\.term))
            .filter { !excluded.contains(normalize($0)) }

        let restrainedWords = ["不要太", "克制", "轻柔", "柔和"]
        let forcefulWords = ["非常", "极强", "强烈", "猛烈"]
        let softWords = ["稍微", "有一点"]

        // 强度用"就近原则"收敛：多个强度词同时出现时，以最后出现的词为准
        // （转折词"但"之后的通常是最终诉求：克制但强烈 → 强烈）。这是确定性的
        // 就近规则，避免把歧义留给排序层自行纠结。
        var intensityCandidates: [(word: String, value: Double)] = []
        for word in restrainedWords { intensityCandidates.append((word, 0.45)) }
        for word in forcefulWords { intensityCandidates.append((word, 1.8)) }
        for word in softWords { intensityCandidates.append((word, 0.75)) }

        var latestIntensityValue: Double?
        var latestIntensityIndex = normalized.startIndex
        for entry in intensityCandidates where normalized.contains(entry.word) {
            guard let range = normalized.range(of: entry.word) else { continue }
            if latestIntensityValue == nil || range.lowerBound > latestIntensityIndex {
                latestIntensityValue = entry.value
                latestIntensityIndex = range.lowerBound
            }
        }
        intent.intensity = latestIntensityValue

        let hasRestrained = restrainedWords.contains { normalized.contains($0) }
        let hasForceful = forcefulWords.contains { normalized.contains($0) }
        if hasRestrained && hasForceful {
            intent.conflicts.append("同时包含克制与强烈")
        }

        // Surface an actual contradiction only when a term is requested before a negation
        // marker and then explicitly excluded later ("雷声，不要雷声").
        let negativeMarkerPattern = #"(?:不要|别|排除|不要有|不能有|without|no)"#
        if let marker = try? NSRegularExpression(pattern: negativeMarkerPattern, options: [.caseInsensitive]) {
            let originalRange = NSRange(original.startIndex..<original.endIndex, in: original)
            let markerRanges = marker.matches(in: original, range: originalRange)
            if let firstMarker = markerRanges.first,
               let markerIndex = Range(firstMarker.range, in: original)?.lowerBound {
                let positiveClause = String(original[..<markerIndex])
                let positiveNormalized = normalize(positiveClause)
                let repeated = intent.excludedTerms.filter { positiveNormalized.contains(normalize($0)) }
                intent.conflicts.append(contentsOf: repeated.map { "同时要求与排除“\($0)”" })
            }
        }

        // Explicit lower/upper duration bounds can conflict even when no single target duration
        // was expressed ("至少 5 秒，不超过 3 秒").
        let durationBounds = durationBounds(in: original)
        if let minimum = durationBounds.minimum { intent.minimumDuration = minimum }
        if let maximum = durationBounds.maximum { intent.maximumDuration = maximum }
        if let minimum = intent.minimumDuration,
           let maximum = intent.maximumDuration,
           minimum > maximum {
            intent.conflicts.append("时长条件互相冲突")
        }
        intent.conflicts = unique(intent.conflicts)
        if let target = targetDuration(in: original) {
            intent.targetDuration = target
            intent.minimumDuration = max(0, target - 0.5)
            intent.maximumDuration = target + 0.5
        }
        let hasSignals = !intent.positiveTerms.isEmpty || !intent.excludedTerms.isEmpty || intent.intensity != nil
        intent.confidence = hasSignals ? 0.82 : 0.25
        return intent
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert(normalize($0)).inserted }
    }

    private static func targetDuration(in value: String) -> TimeInterval? {
        let pattern = #"([0-9]+(?:\.[0-9]+)?|一|二|两|三|四|五|六|七|八|九|十)\s*秒\s*(?:左右|大约|约)"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = expression.firstMatch(in: value, range: range), match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: value) else { return nil }
        let raw = String(value[captureRange])
        if let number = Double(raw) { return number }
        return ["一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
                "六": 6, "七": 7, "八": 8, "九": 9, "十": 10][raw].map(Double.init)
    }

    private static func durationBounds(in value: String) -> (minimum: TimeInterval?, maximum: TimeInterval?) {
        let number = #"([0-9]+(?:\.[0-9]+)?|一|二|两|三|四|五|六|七|八|九|十)"#
        let minimum = captures(pattern: #"(?:至少|不短于)\s*"# + number + #"\s*秒|"# + number + #"\s*秒\s*(?:以上|起)"#, in: value)
            .compactMap(durationNumber)
            .first
        let maximum = captures(pattern: #"(?:不超过|少于|短于)\s*"# + number + #"\s*秒|"# + number + #"\s*秒\s*(?:以内|以下|内)"#, in: value)
            .compactMap(durationNumber)
            .first
        return (minimum, maximum)
    }

    private static func captures(pattern: String, in value: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = expression.firstMatch(in: value, range: range) else { return [] }
        return (1..<match.numberOfRanges).compactMap { index in
            let capture = match.range(at: index)
            guard capture.location != NSNotFound, let captureRange = Range(capture, in: value) else { return nil }
            return String(value[captureRange])
        }
    }

    private static func durationNumber(_ raw: String) -> TimeInterval? {
        if let value = Double(raw) { return value }
        return ["一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
                "六": 6, "七": 7, "八": 8, "九": 9, "十": 10][raw].map(Double.init)
    }
}
