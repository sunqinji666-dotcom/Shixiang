import SwiftUI

/// A compressed selection model for creator-scale result sets. "Select all" is represented by
/// one Boolean plus exceptions instead of copying 36k UUIDs through SwiftUI's view tree.
@MainActor
final class SoundBatchSelection: ObservableObject {
    @Published private(set) var selectsAll = false
    @Published private(set) var selectedIDs: Set<UUID> = []
    @Published private(set) var excludedIDs: Set<UUID> = []

    func contains(_ soundID: UUID) -> Bool {
        selectsAll ? !excludedIDs.contains(soundID) : selectedIDs.contains(soundID)
    }

    func toggle(_ soundID: UUID) {
        if selectsAll {
            if excludedIDs.contains(soundID) {
                excludedIDs.remove(soundID)
            } else {
                excludedIDs.insert(soundID)
            }
        } else if selectedIDs.contains(soundID) {
            selectedIDs.remove(soundID)
        } else {
            selectedIDs.insert(soundID)
        }
    }

    func selectOnly(_ soundID: UUID?) {
        selectsAll = false
        excludedIDs.removeAll(keepingCapacity: true)
        selectedIDs = soundID.map { [$0] } ?? []
    }

    func selectAll() {
        selectsAll = true
        selectedIDs.removeAll(keepingCapacity: true)
        excludedIDs.removeAll(keepingCapacity: true)
    }

    func clear() {
        selectsAll = false
        selectedIDs.removeAll(keepingCapacity: true)
        excludedIDs.removeAll(keepingCapacity: true)
    }

    func selectedCount(total: Int) -> Int {
        selectsAll ? max(0, total - excludedIDs.count) : selectedIDs.count
    }

    func retain(availableIDs: Set<UUID>) {
        if selectsAll {
            excludedIDs.formIntersection(availableIDs)
        } else {
            selectedIDs.formIntersection(availableIDs)
        }
    }

    func resolvedIDs(from items: [SoundItem]) -> Set<UUID> {
        if selectsAll {
            return Set(items.lazy.map(\.id).filter { !self.excludedIDs.contains($0) })
        }
        let availableIDs = Set(items.lazy.map(\.id))
        return selectedIDs.intersection(availableIDs)
    }
}
