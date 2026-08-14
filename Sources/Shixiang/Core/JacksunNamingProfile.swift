import Foundation

struct NamingDictionaryEntry: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var sourceTerm: String
    var preferredName: String
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        sourceTerm: String,
        preferredName: String,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.sourceTerm = sourceTerm
        self.preferredName = preferredName
        self.isEnabled = isEnabled
    }
}

/// Jacksun-owned naming behavior. It only influences aliases stored in Shixiang's database;
/// no rule is ever applied to a source filename or audio metadata.
struct JacksunNamingProfile: Codable, Hashable, Sendable {
    var entries: [NamingDictionaryEntry]
    var namePrefix: String
    var separator: String
    var keepsSourceSequence: Bool
    var numbersConflicts: Bool

    static let `default` = JacksunNamingProfile(
        entries: [
            .init(sourceTerm: "whoosh", preferredName: "呼啸"),
            .init(sourceTerm: "riser", preferredName: "上升"),
            .init(sourceTerm: "downer", preferredName: "下降"),
            .init(sourceTerm: "impact", preferredName: "冲击"),
            .init(sourceTerm: "braam", preferredName: "深沉号角"),
            .init(sourceTerm: "stinger", preferredName: "短乐句"),
            .init(sourceTerm: "glitch", preferredName: "数字故障"),
            .init(sourceTerm: "foley", preferredName: "拟音")
        ],
        namePrefix: "",
        separator: " · ",
        keepsSourceSequence: true,
        numbersConflicts: true
    )

    func personalizedName(baseName: String, searchableText: String) -> String {
        var result = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = searchableText.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        ).lowercased()

        var supplemental: [String] = []
        for entry in entries where entry.isEnabled {
            let term = entry.sourceTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            let preferred = entry.preferredName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, !preferred.isEmpty else { continue }
            let foldedTerm = term.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            ).lowercased()
            guard source.contains(foldedTerm) else { continue }

            if let range = result.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
                result.replaceSubrange(range, with: preferred)
            } else if !result.localizedCaseInsensitiveContains(preferred) {
                supplemental.append(preferred)
            }
        }
        if !supplemental.isEmpty {
            result = (supplemental.uniqued() + [result]).joined(separator: effectiveSeparator)
        }
        if !keepsSourceSequence {
            result = result.replacingOccurrences(
                of: #"(?:[\s·_\-]+)\d{1,4}$"#,
                with: "",
                options: .regularExpression
            )
        }
        let prefix = namePrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prefix.isEmpty, !result.hasPrefix(prefix) {
            result = prefix + effectiveSeparator + result
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var effectiveSeparator: String {
        let value = separator.trimmingCharacters(in: .newlines)
        return value.isEmpty ? " · " : String(value.prefix(8))
    }
}

private extension Array where Element == String {
    func uniqued() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
