import Foundation

struct AISearchEvaluationCase: Sendable, Hashable {
    let query: String
    let category: String
    let requiredTerms: [String]
    let excludedTerms: [String]
}

/// A stable, offline smoke set for the creator language the product promises to understand.
/// It contains no audio, paths, or private project information; tests exercise only parsing.
enum AISearchEvaluationSet {
    private static let baseCases: [AISearchEvaluationCase] = [
        ("木门关上，短促", "对象动作", ["木质", "关门"], []),
        ("金属撞击，明亮一点", "材质听感", ["金属", "明亮"], []),
        ("远处雷声，不要雨", "否定距离", ["远处"], ["雨"]),
        ("咖啡馆约会，轻柔", "场景关系", ["咖啡馆", "约会"], []),
        ("夜晚城市雨声", "环境", ["夜晚", "城市"], []),
        ("产品结尾落版，一秒左右", "剪辑用途", ["落版"], []),
        ("慢镜头布料飘动，三到五秒", "动态时长", ["布料"], []),
        ("机械门关上，不要科幻 UI", "排除风格", ["机械"], ["科幻", "UI"]),
        ("克制科技上升，3 秒内", "科技转场", ["科技", "上升"], []),
        ("远处的海浪，舒缓，10 秒左右", "自然听感", ["远处", "海浪"], [])
    ].map { AISearchEvaluationCase(query: $0.0, category: $0.1, requiredTerms: $0.2, excludedTerms: $0.3) }

    static let cases: [AISearchEvaluationCase] = baseCases + generatedCases

    private static let generatedCases: [AISearchEvaluationCase] = {
        let objects = ["木门", "金属箱", "玻璃杯", "布料", "纸张", "机械按钮", "城市街道", "咖啡馆", "海浪", "雷声"]
        let modifiers = ["短促", "轻柔", "明亮", "低沉", "远处", "室内", "夜晚", "不要雨", "不要科幻", "3 秒左右"]
        return (0..<90).map { index in
            let object = objects[index % objects.count]
            let modifier = modifiers[index % modifiers.count]
            let excluded = modifier.hasPrefix("不要") ? [String(modifier.dropFirst(2))] : []
            return AISearchEvaluationCase(
                query: "(object) (modifier)",
                category: "组合回归 (index + 11)",
                requiredTerms: [object],
                excludedTerms: excluded
            )
        }
    }()
}
