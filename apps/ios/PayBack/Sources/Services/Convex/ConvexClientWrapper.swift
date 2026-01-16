import Foundation
@preconcurrency import ConvexMobile

// MARK: - ConvexClient Protocol Wrapper

/// Protocol abstracting ConvexClient for dependency injection and testing
/// Based on Firebase SDK mocking patterns from iOS community research
public protocol ConvexClientWrapper: Sendable {
    /// Subscribe to a query and get streaming values
    func subscribe<T: Decodable>(to query: String, yielding type: T.Type) -> AsyncThrowingStream<T, Error>
    
    /// Execute a mutation
    func mutation(_ name: String, with args: [String: ConvexEncodable?]) async throws
}

// MARK: - Real ConvexClient Implementation

/// Production wrapper that uses the actual ConvexClient
public final class RealConvexClientWrapper: ConvexClientWrapper, @unchecked Sendable {
    private let client: ConvexClient
    
    public init(client: ConvexClient) {
        self.client = client
    }
    
    public func subscribe<T: Decodable>(to query: String, yielding type: T.Type) -> AsyncThrowingStream<T, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await value in self.client.subscribe(to: query, yielding: type).values {
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    public func mutation(_ name: String, with args: [String: ConvexEncodable?]) async throws {
        _ = try await client.mutation(name, with: args) as Any
    }
}

// MARK: - Mock ConvexClient for Testing

#if DEBUG
/// Mock implementation for unit testing
public final class MockConvexClientWrapper: ConvexClientWrapper, @unchecked Sendable {
    
    // MARK: - Configurable Responses
    
    /// Subscription responses keyed by query name
    public var subscriptionResponses: [String: Any] = [:]
    
    /// Errors to throw for subscriptions
    public var subscriptionErrors: [String: Error] = [:]
    
    /// Errors to throw for mutations
    public var mutationErrors: [String: Error] = [:]
    
    /// Record of mutation calls for verification
    public private(set) var mutationCalls: [(name: String, args: [String: ConvexEncodable?])] = []
    
    /// Record of subscription calls
    public private(set) var subscriptionCalls: [(query: String, type: String)] = []
    
    public init() {}
    
    public func subscribe<T: Decodable>(to query: String, yielding type: T.Type) -> AsyncThrowingStream<T, Error> {
        subscriptionCalls.append((query, String(describing: type)))
        
        return AsyncThrowingStream { continuation in
            if let error = self.subscriptionErrors[query] {
                continuation.finish(throwing: error)
                return
            }
            
            if let response = self.subscriptionResponses[query] as? T {
                continuation.yield(response)
            }
            continuation.finish()
        }
    }
    
    public func mutation(_ name: String, with args: [String: ConvexEncodable?]) async throws {
        mutationCalls.append((name, args))
        
        if let error = mutationErrors[name] {
            throw error
        }
    }
    
    /// Reset all recorded calls
    public func reset() {
        mutationCalls.removeAll()
        subscriptionCalls.removeAll()
    }
}
#endif

// MARK: - Expense Argument Builders (Pure Functions)

/// Pure functions for building Convex mutation arguments
/// Extracted for testability - no SDK dependencies
enum ExpenseArgumentBuilder {
    
    /// Build split arguments from ExpenseSplits
    static func buildSplitArgs(from splits: [ExpenseSplit]) -> [[String: Any]] {
        splits.map { split in
            [
                "id": split.id.uuidString,
                "member_id": split.memberId.uuidString,
                "amount": split.amount,
                "is_settled": split.isSettled
            ]
        }
    }
    
    /// Build participant arguments from ExpenseParticipants
    static func buildParticipantArgs(from participants: [ExpenseParticipant]) -> [[String: Any?]] {
        participants.map { p in
            [
                "member_id": p.memberId.uuidString,
                "name": p.name,
                "linked_account_id": p.linkedAccountId,
                "linked_account_email": p.linkedAccountEmail
            ]
        }
    }
    
    /// Build subexpense arguments
    static func buildSubexpenseArgs(from subexpenses: [Subexpense]?) -> [[String: Any]]? {
        subexpenses?.map { sub in
            [
                "id": sub.id.uuidString,
                "amount": sub.amount
            ]
        }
    }
    
    /// Build complete expense mutation arguments
    static func buildExpenseArgs(
        expense: Expense,
        participants: [ExpenseParticipant]
    ) -> [String: Any?] {
        var args: [String: Any?] = [
            "id": expense.id.uuidString,
            "group_id": expense.groupId.uuidString,
            "description": expense.description,
            "date": expense.date.timeIntervalSince1970 * 1000,
            "total_amount": expense.totalAmount,
            "paid_by_member_id": expense.paidByMemberId.uuidString,
            "involved_member_ids": expense.involvedMemberIds.map { $0.uuidString },
            "splits": buildSplitArgs(from: expense.splits),
            "is_settled": expense.isSettled,
            "participant_member_ids": participants.map { $0.memberId.uuidString },
            "participants": buildParticipantArgs(from: participants)
        ]
        
        if let subArgs = buildSubexpenseArgs(from: expense.subexpenses) {
            args["subexpenses"] = subArgs
        }
        
        return args
    }
    
    /// Validate expense arguments before sending
    static func validateExpenseArgs(_ args: [String: Any?]) -> [String] {
        var errors: [String] = []
        
        if args["id"] == nil {
            errors.append("Missing expense ID")
        }
        if args["group_id"] == nil {
            errors.append("Missing group ID")
        }
        if args["description"] == nil {
            errors.append("Missing description")
        }
        if let amount = args["total_amount"] as? Double, amount < 0 {
            errors.append("Negative total amount")
        }
        
        return errors
    }
}

// MARK: - Group Argument Builders

/// Pure functions for building group mutation arguments
enum GroupArgumentBuilder {
    
    /// Build member arguments from GroupMembers
    static func buildMemberArgs(from members: [GroupMember]) -> [[String: String]] {
        members.map { member in
            [
                "id": member.id.uuidString,
                "name": member.name
            ]
        }
    }
    
    /// Build complete group mutation arguments
    static func buildGroupArgs(group: SpendingGroup) -> [String: Any?] {
        [
            "id": group.id.uuidString,
            "name": group.name,
            "created_at": group.createdAt.timeIntervalSince1970 * 1000,
            "members": buildMemberArgs(from: group.members),
            "is_direct": group.isDirect,
            "is_payback_generated_mock_data": group.isDebug
        ]
    }
}

// MARK: - Account Argument Builders

/// Pure functions for building account mutation arguments
enum AccountArgumentBuilder {
    
    /// Build friend arguments
    static func buildFriendArgs(from friend: AccountFriend) -> [String: Any?] {
        [
            "member_id": friend.memberId.uuidString,
            "name": friend.name,
            "nickname": friend.nickname,
            "has_linked_account": friend.hasLinkedAccount,
            "linked_account_id": friend.linkedAccountId,
            "linked_account_email": friend.linkedAccountEmail
        ]
    }
    
    /// Build bulk friend update arguments
    static func buildBulkFriendArgs(from friends: [AccountFriend]) -> [[String: Any?]] {
        friends.map { buildFriendArgs(from: $0) }
    }
}
