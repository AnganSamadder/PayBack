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
    func deleteDebugGroups() async throws
    func leaveGroup(_ groupId: UUID) async throws
}

struct NoopGroupCloudService: GroupCloudService {
    func fetchGroups() async throws -> [SpendingGroup] { [] }
    func upsertGroup(_ group: SpendingGroup) async throws {}
    func upsertDebugGroup(_ group: SpendingGroup) async throws {}
    func deleteGroups(_ ids: [UUID]) async throws {}
    func deleteDebugGroups() async throws {}
    func leaveGroup(_ groupId: UUID) async throws {}
}
