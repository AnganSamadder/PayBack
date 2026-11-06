//
//  GroupCloudService.swift
//  PayBack
//
//  Adapted for Clerk/Convex migration.
//

import Foundation

protocol GroupCloudService: Sendable {
    func fetchGroups() async throws -> [SpendingGroup]
    func upsertGroup(_ group: SpendingGroup) async throws
    func upsertDebugGroup(_ group: SpendingGroup) async throws
    func deleteGroups(_ ids: [UUID]) async throws
    func removeMemberFromGroup(_ groupId: UUID, memberId: UUID) async throws
    func deleteDebugGroups() async throws
    func leaveGroup(_ groupId: UUID) async throws
    func clearAllData() async throws
    func upsertGroup(_ group: SpendingGroup, expectedAccountId: String) async throws
    func upsertDebugGroup(_ group: SpendingGroup, expectedAccountId: String) async throws
    func deleteGroups(_ ids: [UUID], expectedAccountId: String) async throws
    func removeMemberFromGroup(_ groupId: UUID, memberId: UUID, expectedAccountId: String) async throws
    func deleteDebugGroups(expectedAccountId: String) async throws
    func leaveGroup(_ groupId: UUID, expectedAccountId: String) async throws
    func clearAllData(expectedAccountId: String) async throws
}

extension GroupCloudService {
    func upsertGroup(_ group: SpendingGroup, expectedAccountId: String) async throws {
        try await upsertGroup(group)
    }
    func upsertDebugGroup(_ group: SpendingGroup, expectedAccountId: String) async throws {
        try await upsertDebugGroup(group)
    }
    func deleteGroups(_ ids: [UUID], expectedAccountId: String) async throws {
        try await deleteGroups(ids)
    }
    func removeMemberFromGroup(_ groupId: UUID, memberId: UUID, expectedAccountId: String) async throws {
        try await removeMemberFromGroup(groupId, memberId: memberId)
    }
    func deleteDebugGroups(expectedAccountId: String) async throws {
        try await deleteDebugGroups()
    }
    func leaveGroup(_ groupId: UUID, expectedAccountId: String) async throws {
        try await leaveGroup(groupId)
    }
    func clearAllData(expectedAccountId: String) async throws {
        try await clearAllData()
    }

    func clearAllData() async throws {}
}

struct NoopGroupCloudService: GroupCloudService {
    func fetchGroups() async throws -> [SpendingGroup] { [] }
    func upsertGroup(_ group: SpendingGroup) async throws {}
    func upsertDebugGroup(_ group: SpendingGroup) async throws {}
    func deleteGroups(_ ids: [UUID]) async throws {}
    func removeMemberFromGroup(_ groupId: UUID, memberId: UUID) async throws {}
    func deleteDebugGroups() async throws {}
    func leaveGroup(_ groupId: UUID) async throws {}
}
