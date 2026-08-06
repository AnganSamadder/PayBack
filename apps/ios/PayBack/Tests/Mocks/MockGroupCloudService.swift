import Foundation
@testable import PayBack

/// Mock group cloud service for testing AppStore
actor MockGroupCloudServiceForAppStore: GroupCloudService {
    private var groups: [UUID: SpendingGroup] = [:]
    private var shouldFail: Bool = false
    private var queuedFetchGroups: [[SpendingGroup]] = []
    private var queuedFetchDelaysNanoseconds: [UInt64] = []
    private var fetchInvocationCount = 0
    private var clearAllInvocationCount = 0
    private var shouldSuspendClearAll = false
    private var clearAllContinuation: CheckedContinuation<Void, Never>?
    private var upsertDelayNanoseconds: UInt64 = 0
    private var deleteDelayNanoseconds: UInt64 = 0
    private var leaveDelayNanoseconds: UInt64 = 0
    private var removeMemberDelayNanoseconds: UInt64 = 0
    private var memberRemovalSuspensionBudget = 0
    private var memberRemovalContinuations: [CheckedContinuation<Void, Never>] = []
    private var upsertInvocationCount = 0
    private var deleteInvocationCount = 0
    private var deletedGroupIDBatches: [[UUID]] = []
    private var leaveInvocationCount = 0
    private var removeMemberInvocationCount = 0

    func upsertGroup(_ group: SpendingGroup) async throws {
        upsertInvocationCount += 1
        if upsertDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: upsertDelayNanoseconds)
        }
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
        deleteInvocationCount += 1
        deletedGroupIDBatches.append(groupIds)
        if deleteDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: deleteDelayNanoseconds)
        }
        if shouldFail {
            throw PayBackError.authSessionMissing
        }
        for id in groupIds {
            groups.removeValue(forKey: id)
        }
    }

    func removeMemberFromGroup(_ groupId: UUID, memberId: UUID) async throws {
        removeMemberInvocationCount += 1
        if memberRemovalSuspensionBudget > 0 {
            memberRemovalSuspensionBudget -= 1
            await withCheckedContinuation { continuation in
                memberRemovalContinuations.append(continuation)
            }
        }
        if removeMemberDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: removeMemberDelayNanoseconds)
        }
        if shouldFail {
            throw PayBackError.authSessionMissing
        }
        guard var group = groups[groupId] else { return }
        group.members.removeAll { $0.id == memberId }
        groups[groupId] = group
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
        leaveInvocationCount += 1
        if leaveDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: leaveDelayNanoseconds)
        }
        if shouldFail {
            throw PayBackError.authSessionMissing
        }
        groups.removeValue(forKey: groupId)
    }

    func clearAllData() async throws {
        clearAllInvocationCount += 1
        if shouldSuspendClearAll {
            await withCheckedContinuation { continuation in
                clearAllContinuation = continuation
            }
        }
        if shouldFail {
            throw PayBackError.networkUnavailable
        }
        groups.removeAll()
    }

    // Test helpers
    func addGroup(_ group: SpendingGroup) {
        groups[group.id] = group
    }

    func setShouldFail(_ fail: Bool) {
        shouldFail = fail
    }

    func setOperationDelays(
        upsert: UInt64 = 0,
        delete: UInt64 = 0,
        leave: UInt64 = 0,
        removeMember: UInt64 = 0
    ) {
        upsertDelayNanoseconds = upsert
        deleteDelayNanoseconds = delete
        leaveDelayNanoseconds = leave
        removeMemberDelayNanoseconds = removeMember
    }

    func currentUpsertInvocationCount() -> Int {
        upsertInvocationCount
    }

    func currentDeleteInvocationCount() -> Int {
        deleteInvocationCount
    }

    func deletedGroupIDs() -> [UUID] {
        deletedGroupIDBatches.flatMap { $0 }
    }

    func currentLeaveInvocationCount() -> Int {
        leaveInvocationCount
    }

    func currentRemoveMemberInvocationCount() -> Int {
        removeMemberInvocationCount
    }

    func suspendNextMemberRemovals(_ count: Int) {
        memberRemovalSuspensionBudget = count
    }

    func resumeNextMemberRemoval() {
        guard !memberRemovalContinuations.isEmpty else { return }
        memberRemovalContinuations.removeFirst().resume()
    }

    func queueFetches(groups: [[SpendingGroup]], delaysNanoseconds: [UInt64]) {
        queuedFetchGroups = groups
        queuedFetchDelaysNanoseconds = delaysNanoseconds
    }

    func currentFetchInvocationCount() -> Int {
        fetchInvocationCount
    }

    func currentClearAllInvocationCount() -> Int {
        clearAllInvocationCount
    }

    func suspendNextClearAll() {
        shouldSuspendClearAll = true
    }

    func resumeClearAll() {
        shouldSuspendClearAll = false
        clearAllContinuation?.resume()
        clearAllContinuation = nil
    }

    func reset() {
        groups.removeAll()
        shouldFail = false
        queuedFetchGroups.removeAll()
        queuedFetchDelaysNanoseconds.removeAll()
        fetchInvocationCount = 0
        clearAllInvocationCount = 0
        shouldSuspendClearAll = false
        clearAllContinuation?.resume()
        clearAllContinuation = nil
        upsertDelayNanoseconds = 0
        deleteDelayNanoseconds = 0
        leaveDelayNanoseconds = 0
        removeMemberDelayNanoseconds = 0
        memberRemovalSuspensionBudget = 0
        memberRemovalContinuations.forEach { $0.resume() }
        memberRemovalContinuations.removeAll()
        upsertInvocationCount = 0
        deleteInvocationCount = 0
        deletedGroupIDBatches.removeAll()
        leaveInvocationCount = 0
        removeMemberInvocationCount = 0
    }
}
