import Foundation

/// Service for reconciling link state between local and remote data
actor LinkStateReconciliation {
    private var lastReconciliationDate: Date?
    private let minimumReconciliationInterval: TimeInterval = 300 // 5 minutes
    
    /// Reconciles link state for all friends
    /// - Parameters:
    ///   - localFriends: Current local friend list
    ///   - remoteFriends: Friend list from Firestore
    /// - Returns: Reconciled friend list with corrected link status
    func reconcile(
        localFriends: [AccountFriend],
        remoteFriends: [AccountFriend]
    ) -> [AccountFriend] {
        var reconciled: [UUID: AccountFriend] = [:]
        
        // Start with local friends
        for friend in localFriends {
            reconciled[friend.memberId] = friend
        }
        
        // Update with remote data (remote is source of truth for link status)
        for remoteFriend in remoteFriends {
            if var localFriend = reconciled[remoteFriend.memberId] {
                // Check for inconsistencies
                let hasInconsistency = 
                    localFriend.hasLinkedAccount != remoteFriend.hasLinkedAccount ||
                    localFriend.linkedAccountId != remoteFriend.linkedAccountId ||
                    localFriend.linkedAccountEmail != remoteFriend.linkedAccountEmail
                
                if hasInconsistency {
                    #if DEBUG
                    print("[Reconciliation] Detected inconsistency for member \(remoteFriend.memberId)")
                    print("  Local: linked=\(localFriend.hasLinkedAccount), id=\(localFriend.linkedAccountId ?? "nil")")
                    print("  Remote: linked=\(remoteFriend.hasLinkedAccount), id=\(remoteFriend.linkedAccountId ?? "nil")")
                    #endif
                    
                    // Remote is source of truth - update local with remote data
                    localFriend.hasLinkedAccount = remoteFriend.hasLinkedAccount
                    localFriend.linkedAccountId = remoteFriend.linkedAccountId
                    localFriend.linkedAccountEmail = remoteFriend.linkedAccountEmail
                    reconciled[remoteFriend.memberId] = localFriend
                }
            } else {
                // Friend exists in remote but not local - add it
                reconciled[remoteFriend.memberId] = remoteFriend
            }
        }
        
        lastReconciliationDate = Date()
        
        return Array(reconciled.values).sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
    
    /// Checks if reconciliation should be performed based on time interval
    func shouldReconcile() -> Bool {
        guard let lastDate = lastReconciliationDate else {
            return true
        }
        
        return Date().timeIntervalSince(lastDate) >= minimumReconciliationInterval
    }
    
    /// Forces reconciliation on next check
    func invalidate() {
        lastReconciliationDate = nil
    }
    
    /// Validates that a linking operation completed successfully
    /// - Parameters:
    ///   - memberId: The member ID that was linked
    ///   - accountId: The account ID it was linked to
    ///   - friends: Current friend list
    /// - Returns: True if the link is properly reflected in the friend list
    func validateLinkCompletion(
        memberId: UUID,
        accountId: String,
        in friends: [AccountFriend]
    ) -> Bool {
        guard let friend = friends.first(where: { $0.memberId == memberId }) else {
            #if DEBUG
            print("[Reconciliation] Validation failed: Friend not found for member \(memberId)")
            #endif
            return false
        }
        
        let isValid = friend.hasLinkedAccount &&
                     friend.linkedAccountId == accountId
        
        #if DEBUG
        if !isValid {
            print("[Reconciliation] Validation failed for member \(memberId)")
            print("  Expected: linked=true, accountId=\(accountId)")
            print("  Actual: linked=\(friend.hasLinkedAccount), accountId=\(friend.linkedAccountId ?? "nil")")
        }
        #endif
        
        return isValid
    }
}

/// Tracks partial link failures for recovery
actor LinkFailureTracker {
    private var failedOperations: [UUID: LinkFailureRecord] = [:]
    private let maxRetentionTime: TimeInterval = 3600 // 1 hour
    
    struct LinkFailureRecord {
        let memberId: UUID
        let accountId: String
        let accountEmail: String
        let failureDate: Date
        let failureReason: String
        var retryCount: Int
    }
    
    /// Records a partial link failure
    func recordFailure(
        memberId: UUID,
        accountId: String,
        accountEmail: String,
        reason: String
    ) {
        if var existing = failedOperations[memberId] {
            existing.retryCount += 1
            failedOperations[memberId] = existing
        } else {
            failedOperations[memberId] = LinkFailureRecord(
                memberId: memberId,
                accountId: accountId,
                accountEmail: accountEmail,
                failureDate: Date(),
                failureReason: reason,
                retryCount: 1
            )
        }
        
        #if DEBUG
        print("[LinkFailure] Recorded failure for member \(memberId): \(reason)")
        #endif
    }
    
    /// Retrieves pending failed operations
    func getPendingFailures() -> [LinkFailureRecord] {
        // Clean up old records
        let cutoffDate = Date().addingTimeInterval(-maxRetentionTime)
        failedOperations = failedOperations.filter { $0.value.failureDate > cutoffDate }
        
        return Array(failedOperations.values)
    }
    
    /// Marks a failure as resolved
    func markResolved(memberId: UUID) {
        failedOperations.removeValue(forKey: memberId)
        
        #if DEBUG
        print("[LinkFailure] Marked failure as resolved for member \(memberId)")
        #endif
    }
    
    /// Clears all failure records
    func clearAll() {
        failedOperations.removeAll()
    }
}
