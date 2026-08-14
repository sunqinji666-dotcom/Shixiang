import Foundation

/// 从库内音效的目录、文件名与标签提取的"真实词汇表"。
///
/// 语义检索的检索词应该落在库真实存在的话术上，而不是小模型自由改写的词。
/// 本类型在库结构变化后重建（懒加载 + revision 失效），供排序阶段过滤无意义的中文
/// n-gram：只有库内真实出现过的 n-gram 才参与目录/标签证据匹配，避免"远处雷声"被
/// 拆成"远雷""处雷"这类噪声。
struct LibraryVocabulary: Sendable, Equatable {
    private(set) var tokenFrequency: [String: Int]

    init(tokenFrequency: [String: Int] = [:]) {
        self.tokenFrequency = tokenFrequency
    }

    var isEmpty: Bool { tokenFrequency.isEmpty }

    /// 归一化 token 总数（去重前）。
    var totalOccurrences: Int { tokenFrequency.reduce(0) { $0 + $1.value } }

    /// 某归一化 token 是否在库内真实出现过。
    func isKnown(_ token: String) -> Bool {
        tokenFrequency[token] != nil
    }

    func frequency(of token: String) -> Int {
        tokenFrequency[token] ?? 0
    }

    static func build(from packs: [SoundPack]) -> LibraryVocabulary {
        build(from: packs.flatMap(\.items))
    }

    static func build(from items: [SoundItem]) -> LibraryVocabulary {
        var counts: [String: Int] = [:]
        for item in items {
            for token in vocabularyTokens(of: item) {
                counts[token, default: 0] += 1
            }
        }
        return LibraryVocabulary(tokenFrequency: counts)
    }

    /// 单个音效贡献的可检索 token 集合（已归一化、去停止词、过滤纯数字）。
    static func vocabularyTokens(of item: SoundItem) -> Set<String> {
        var tokens = Set<String>()
        let fileNameStem = (item.fileName as NSString).deletingPathExtension
        tokens.formUnion(tokenized(fileNameStem))
        for segment in item.folderPath.split(separator: "/") {
            tokens.formUnion(tokenized(String(segment)))
        }
        for tag in item.tags {
            tokens.formUnion(tokenized(tag))
        }
        return tokens
    }

    private static func tokenized(_ value: String) -> Set<String> {
        var result = Set<String>()
        for token in normalize(value).split(separator: " ").map(String.init) {
            guard token.count >= 2 else { continue }
            guard !stopWords.contains(token) else { continue }
            guard !token.allSatisfy(\.isNumber) else { continue }
            result.insert(token)
        }
        return result
    }

    /// 与 `LocalAISearchRanking.normalize` 相同的归一化：折叠大小写/变音符、只保留
    /// 字母数字（含 CJK）、空白统一为单个空格。
    static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static let stopWords: Set<String> = [
        "audio", "audios", "sound", "sounds", "sfx", "fx", "files", "file", "files",
        "export", "exports", "new", "folder", "untitled", "the", "and", "for", "with",
        "from", "this", "that", "素材", "音频", "音效", "声音", "文件", "文件夹", "导出",
        "未命名", "全部", "其他", "本地", "内容", "默认"
    ]
}
