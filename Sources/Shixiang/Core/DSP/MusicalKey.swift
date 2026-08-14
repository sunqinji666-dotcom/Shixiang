import Foundation

struct MusicalKey: Codable, Hashable, Sendable, CaseIterable {
    enum PitchClass: Int, Codable, CaseIterable, Hashable, Sendable {
        case c = 0
        case cSharp
        case d
        case eFlat
        case e
        case f
        case fSharp
        case g
        case aFlat
        case a
        case bFlat
        case b

        var westernName: String {
            ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"][rawValue]
        }

        var chineseName: String {
            ["C", "升C", "D", "降E", "E", "F", "升F", "G", "降A", "A", "降B", "B"][rawValue]
        }

        func transposed(by semitones: Int) -> PitchClass {
            let normalized = (rawValue + semitones) % 12
            return PitchClass(rawValue: normalized >= 0 ? normalized : normalized + 12) ?? .c
        }
    }

    enum Mode: String, Codable, CaseIterable, Hashable, Sendable {
        case major
        case minor

        var chineseName: String {
            switch self {
            case .major: return "大调"
            case .minor: return "小调"
            }
        }

        var shortName: String {
            switch self {
            case .major: return "Major"
            case .minor: return "Minor"
            }
        }
    }

    let root: PitchClass
    let mode: Mode

    static let allCases: [MusicalKey] = Mode.allCases.flatMap { mode in
        PitchClass.allCases.map { MusicalKey(root: $0, mode: mode) }
    }

    var displayName: String { chineseDisplayName }
    var chineseDisplayName: String { "\(root.chineseName) \(mode.chineseName)" }
    var westernDisplayName: String { "\(root.westernName) \(mode.shortName)" }

    /// Clockwise distance from this tonic to another tonic, in the range 0...11.
    func ascendingSemitones(to target: MusicalKey) -> Int {
        (target.root.rawValue - root.rawValue + 12) % 12
    }

    /// The shortest pitch-shift offset to the target tonic, in the range -5...6.
    /// Mode is intentionally preserved by pitch shifting and does not affect the offset.
    func shortestSemitoneOffset(to target: MusicalKey) -> Int {
        let ascending = ascendingSemitones(to: target)
        return ascending > 6 ? ascending - 12 : ascending
    }

    func semitoneOffset(to target: MusicalKey) -> Int {
        shortestSemitoneOffset(to: target)
    }

    func transposed(by semitones: Int) -> MusicalKey {
        MusicalKey(root: root.transposed(by: semitones), mode: mode)
    }
}

struct KeyAnalysisResult: Codable, Hashable, Sendable {
    enum Status: String, Codable, Hashable, Sendable {
        case stable
        case tooShort
        case insufficientSignal
        case lowConfidence
        case noStableTonalCenter

        var localizedDescription: String {
            switch self {
            case .stable: return "已识别稳定调性"
            case .tooShort: return "音频太短，无法可靠识别"
            case .insufficientSignal: return "有效声音不足"
            case .lowConfidence: return "可能存在调性，但置信度不足"
            case .noStableTonalCenter: return "未发现稳定调性"
            }
        }
    }

    struct Candidate: Codable, Hashable, Sendable, Identifiable {
        let key: MusicalKey
        let confidence: Double

        var id: MusicalKey { key }
    }

    let key: MusicalKey?
    let confidence: Double
    let alternatives: [Candidate]
    let status: Status

    var hasStableKey: Bool { status == .stable && key != nil }
    var isStable: Bool { hasStableKey }

    static func noStableKey(
        status: Status,
        confidence: Double = 0,
        alternatives: [Candidate] = []
    ) -> KeyAnalysisResult {
        KeyAnalysisResult(
            key: nil,
            confidence: min(max(confidence, 0), 1),
            alternatives: alternatives,
            status: status
        )
    }
}
