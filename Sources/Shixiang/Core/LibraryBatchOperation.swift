import Foundation

struct LibraryBatchOperationProgress: Identifiable, Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case preparing
        case saving
        case applying
        case cancelling

        var canCancel: Bool {
            self == .preparing || self == .saving
        }
    }

    let id: UUID
    let actionTitle: String
    let phase: Phase
    let completed: Int
    let total: Int

    var fraction: Double? {
        guard total > 0 else { return nil }
        return min(max(Double(completed) / Double(total), 0), 1)
    }

    var statusTitle: String {
        switch phase {
        case .preparing: return "正在准备\(actionTitle)"
        case .saving: return "正在保存\(actionTitle)"
        case .applying: return "正在更新界面"
        case .cancelling: return "正在安全取消"
        }
    }
}

struct LibraryBatchOperationResult: Identifiable, Equatable, Sendable {
    let id = UUID()
    let message: String
}
