import Foundation
@testable import PayBack

/// Mock group cloud service for testing AppStore
actor MockGroupCloudServiceForAppStore: GroupCloudService {
    private var groups: [UUID: SpendingGroup] = [:]
    private var shouldFail: Bool = false
    private var queuedFetchGroups: [[SpendingGroup]] = []
    private var queuedFetchDelaysNanoseconds: [UInt64] = []
    private var fetchInvocationCount = 0

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
        fetchInvocationCount += 1
        let result = queuedFetchGroups.isEmpty ? Array(groups.values) : queuedFetchGroups.removeFirst()
        let delay = queuedFetchDelaysNanoseconds.isEmpty ? 0 : queuedFetchDelaysNanoseconds.removeFirst()
        if delay > 0 {
            try await Task.sleep(nanoseconds: delay)
        }
        return result
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

    func queueFetches(groups: [[SpendingGroup]], delaysNanoseconds: [UInt64]) {
        queuedFetchGroups = groups
        queuedFetchDelaysNanoseconds = delaysNanoseconds
    }

    func currentFetchInvocationCount() -> Int {
        fetchInvocationCount
    }

    func reset() {
        groups.removeAll()
        shouldFail = false
        queuedFetchGroups.removeAll()
        queuedFetchDelaysNanoseconds.removeAll()
        fetchInvocationCount = 0
    }
}
