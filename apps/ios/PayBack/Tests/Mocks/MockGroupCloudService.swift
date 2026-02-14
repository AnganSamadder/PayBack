import Foundation
@testable import PayBack

/// Mock group cloud service for testing AppStore
actor MockGroupCloudServiceForAppStore: GroupCloudService {
    private var groups: [UUID: SpendingGroup] = [:]
    private var shouldFail: Bool = false

    func upsertGroup(_ group: SpendingGroup) async throws {
        if shouldFail {
            throw PayBackError.authSessionMissing
        }
        groups[group.id] = group
    }

    func fetchGroups() async throws -> [SpendingGroup] {
        if shouldFail {
            throw PayBackError.authSessionMissing
        }
        return Array(groups.values)
    }

    func deleteGroups(_ groupIds: [UUID]) async throws {
        if shouldFail {
            throw PayBackError.authSessionMissing
        }
        for id in groupIds {
            groups.removeValue(forKey: id)
        }
    }

    func upsertDebugGroup(_ group: SpendingGroup) async throws {
        if shouldFail {
            throw PayBackError.authSessionMissing
        }
        groups[group.id] = group
    }

    func deleteDebugGroups() async throws {
        // No-op for mock - just clear groups flagged as debug
    }

    func leaveGroup(_ groupId: UUID) async throws {
        if shouldFail {
            throw PayBackError.authSessionMissing
        }
        groups.removeValue(forKey: groupId)
    }

    // Test helpers
    func addGroup(_ group: SpendingGroup) {
        groups[group.id] = group
    }

    func setShouldFail(_ fail: Bool) {
        shouldFail = fail
    }

    func reset() {
        groups.removeAll()
        shouldFail = false
    }
}
