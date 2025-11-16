import Foundation
@testable import PayBack

/// Mock group cloud service for testing AppStore
actor MockGroupCloudServiceForAppStore: GroupCloudService {
    private var groups: [UUID: SpendingGroup] = [:]
    private var shouldFail: Bool = false
    
    func upsertGroup(_ group: SpendingGroup) async throws {
        if shouldFail {
            throw GroupCloudServiceError.userNotAuthenticated
        }
        groups[group.id] = group
    }
    
    func fetchGroups() async throws -> [SpendingGroup] {
        if shouldFail {
            throw GroupCloudServiceError.userNotAuthenticated
        }
        return Array(groups.values)
    }
    
    func deleteGroups(_ groupIds: [UUID]) async throws {
        if shouldFail {
            throw GroupCloudServiceError.userNotAuthenticated
        }
        for id in groupIds {
            groups.removeValue(forKey: id)
        }
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
