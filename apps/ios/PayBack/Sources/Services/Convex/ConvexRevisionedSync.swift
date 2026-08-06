import Foundation

#if !PAYBACK_CI_NO_CONVEX
@preconcurrency import ConvexMobile

enum ConvexRevisionedSyncError: Error, Equatable {
    case streamEndedWithoutValue
    case invalidExpense(field: String)
    case invalidGroup(field: String)
    case duplicateGroupID(String)
}

struct ConvexPreparedGroups {
    let groups: [SpendingGroup]
    let documentIDs: [UUID: String]
}

struct ConvexSyncGeneration {
    private(set) var current: UInt64 = 0

    @discardableResult
    mutating func advance() -> UInt64 {
        current &+= 1
        return current
    }

    func isCurrent(_ candidate: UInt64) -> Bool {
        current == candidate
    }
}

enum ConvexSyncChannel: Hashable {
    case groups
    case expenses
    case friends
    case incomingLinkRequests
    case outgoingLinkRequests
    case inviteTokens
}

struct ConvexSyncChannelErrorState {
    private var errors: [ConvexSyncChannel: Error] = [:]
    private var recency: [ConvexSyncChannel] = []

    var current: Error? {
        recency.last.flatMap { errors[$0] }
    }

    mutating func record(_ error: Error, for channel: ConvexSyncChannel) {
        errors[channel] = error
        recency.removeAll { $0 == channel }
        recency.append(channel)
    }

    mutating func clear(_ channel: ConvexSyncChannel) {
        errors[channel] = nil
        recency.removeAll { $0 == channel }
    }

    mutating func clearAll() {
        errors.removeAll()
        recency.removeAll()
    }
}

enum ConvexLegacyFallbackOutcome: Equatable {
    case legacyEnded
    case reprobeV2
}

enum ConvexLegacyFallbackProbe {
    typealias Sleep = @Sendable (UInt64) async throws -> Void

    static func run(
        delayNanoseconds: UInt64,
        sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: $0) },
        consumeLegacy: @escaping @Sendable () async throws -> Void
    ) async throws -> ConvexLegacyFallbackOutcome {
        try await withThrowingTaskGroup(of: ConvexLegacyFallbackOutcome.self) { group in
            group.addTask {
                try await consumeLegacy()
                return .legacyEnded
            }
            group.addTask {
                try await sleep(delayNanoseconds)
                return .reprobeV2
            }

            guard let outcome = try await group.next() else {
                throw ConvexRevisionedSyncError.streamEndedWithoutValue
            }
            group.cancelAll()
            return outcome
        }
    }
}

struct ConvexRevisionedGroupsPageDTO: Decodable, Sendable {
    let page: [ConvexGroupDTO]
    let continueCursor: String
    let isDone: Bool
    let revision: Int
}

struct ConvexRevisionedExpensesPageDTO: Decodable, Sendable {
    let page: [ConvexExpenseDTO]
    let continueCursor: String
    let isDone: Bool
    let revision: Int
}

enum ConvexSyncErrorClassifier {
    static func isRevisionMismatch(_ error: Error) -> Bool {
        convexErrorData(error)?.contains("SYNC_REVISION_CHANGED") == true
    }

    static func isV2Unavailable(_ error: Error) -> Bool {
        if convexErrorData(error)?.contains("SYNC_V2_NOT_READY") == true {
            return true
        }
        guard let clientError = error as? ClientError else { return false }
        guard case .ServerError(let message) = clientError else { return false }
        let normalized = message.lowercased()
        return normalized.contains("could not find public function")
            || normalized.contains("no such function")
            || normalized.contains("no such export")
    }

    private static func convexErrorData(_ error: Error) -> String? {
        guard let clientError = error as? ClientError else { return nil }
        guard case .ConvexError(let data) = clientError else { return nil }
        return data
    }
}

enum ConvexSyncRetryPolicy {
    static let legacyV2ReprobeDelayNanoseconds: UInt64 = 30_000_000_000

    static func delayNanoseconds(afterFailureCount failureCount: Int) -> UInt64 {
        let cappedExponent = min(max(failureCount - 1, 0), 4)
        return UInt64(1 << cappedExponent) * 1_000_000_000
    }
}

enum ConvexRevisionedSync {
    static let pageSize = 8

    static func fetchGroupDTOs(client: ConvexClient) async throws -> [ConvexGroupDTO] {
        let paginator = RevisionedSnapshotPaginator<ConvexGroupDTO, Int, String>(
            fetchPage: { cursor, expectedRevision in
                let response: ConvexRevisionedGroupsPageDTO = try await fetchPage(
                    client: client,
                    query: "groups:listV2",
                    cursor: cursor,
                    expectedRevision: expectedRevision
                )
                return RevisionedSnapshotPage(
                    items: response.page,
                    revision: response.revision,
                    continueCursor: response.isDone ? nil : response.continueCursor,
                    isDone: response.isDone
                )
            },
            isRevisionMismatch: { error in
                ConvexSyncErrorClassifier.isRevisionMismatch(error)
            },
            stableID: \ConvexGroupDTO.id
        )
        return try await paginator.fetchSnapshot()
    }

    static func fetchExpenseDTOs(client: ConvexClient) async throws -> [ConvexExpenseDTO] {
        let paginator = RevisionedSnapshotPaginator<ConvexExpenseDTO, Int, String>(
            fetchPage: { cursor, expectedRevision in
                let response: ConvexRevisionedExpensesPageDTO = try await fetchPage(
                    client: client,
                    query: "expenses:listV2",
                    cursor: cursor,
                    expectedRevision: expectedRevision
                )
                return RevisionedSnapshotPage(
                    items: response.page,
                    revision: response.revision,
                    continueCursor: response.isDone ? nil : response.continueCursor,
                    isDone: response.isDone
                )
            },
            isRevisionMismatch: { error in
                ConvexSyncErrorClassifier.isRevisionMismatch(error)
            },
            stableID: \ConvexExpenseDTO.id
        )
        return try await paginator.fetchSnapshot()
    }

    static func prepareGroups(_ dtos: [ConvexGroupDTO]) throws -> ConvexPreparedGroups {
        var seenGroupIDs = Set<UUID>()
        var groups: [SpendingGroup] = []
        var documentIDs: [UUID: String] = [:]
        groups.reserveCapacity(dtos.count)
        documentIDs.reserveCapacity(dtos.count)

        for dto in dtos {
            let group = try dto.validatedSpendingGroup()
            guard seenGroupIDs.insert(group.id).inserted else {
                throw ConvexRevisionedSyncError.duplicateGroupID(group.id.uuidString)
            }
            groups.append(group)
            if let documentID = dto._id {
                documentIDs[group.id] = documentID
            }
        }

        return ConvexPreparedGroups(groups: groups, documentIDs: documentIDs)
    }

    static func groupArguments(
        cursor: String?,
        expectedRevision: Int?
    ) -> [String: ConvexEncodable?] {
        arguments(cursor: cursor, expectedRevision: expectedRevision)
    }

    static func expenseArguments(
        cursor: String?,
        expectedRevision: Int?
    ) -> [String: ConvexEncodable?] {
        arguments(cursor: cursor, expectedRevision: expectedRevision)
    }

    private static func arguments(
        cursor: String?,
        expectedRevision: Int?
    ) -> [String: ConvexEncodable?] {
        let paginationOptions: [String: ConvexEncodable?] = [
            "cursor": cursor,
            "numItems": pageSize
        ]
        var arguments: [String: ConvexEncodable?] = ["paginationOpts": paginationOptions]
        if let expectedRevision {
            arguments["expectedRevision"] = expectedRevision
        }
        return arguments
    }

    private static func fetchPage<Response: Decodable>(
        client: ConvexClient,
        query: String,
        cursor: String?,
        expectedRevision: Int?
    ) async throws -> Response {
        let args = arguments(cursor: cursor, expectedRevision: expectedRevision)
        for try await response in client.subscribe(
            to: query,
            with: args,
            yielding: Response.self
        ).values {
            return response
        }
        throw ConvexRevisionedSyncError.streamEndedWithoutValue
    }
}

extension ConvexGroupDTO {
    func validatedSpendingGroup() throws -> SpendingGroup {
        guard let groupID = UUID(uuidString: id) else {
            throw ConvexRevisionedSyncError.invalidGroup(field: "id")
        }
        let validatedMembers = try members.map { member -> GroupMember in
            guard let memberID = UUID(uuidString: member.id) else {
                throw ConvexRevisionedSyncError.invalidGroup(field: "members.id")
            }
            return GroupMember(
                id: memberID,
                name: member.name,
                profileImageUrl: member.profile_image_url,
                profileColorHex: member.profile_avatar_color,
                isCurrentUser: member.is_current_user
            )
        }
        return SpendingGroup(
            id: groupID,
            name: name,
            members: validatedMembers,
            createdAt: Date(timeIntervalSince1970: created_at / 1_000),
            isDirect: is_direct ?? false,
            isDebug: is_payback_generated_mock_data ?? false
        )
    }
}

extension ConvexExpenseDTO {
    func validatedExpense() throws -> Expense {
        guard let expenseID = UUID(uuidString: id) else {
            throw ConvexRevisionedSyncError.invalidExpense(field: "id")
        }
        guard let groupID = UUID(uuidString: group_id) else {
            throw ConvexRevisionedSyncError.invalidExpense(field: "group_id")
        }
        guard let paidByMemberID = UUID(uuidString: paid_by_member_id) else {
            throw ConvexRevisionedSyncError.invalidExpense(field: "paid_by_member_id")
        }
        let involvedMemberIDs = try involved_member_ids.map { value -> UUID in
            guard let id = UUID(uuidString: value) else {
                throw ConvexRevisionedSyncError.invalidExpense(field: "involved_member_ids")
            }
            return id
        }
        let validatedSplits = try splits.map { split -> ExpenseSplit in
            guard let id = UUID(uuidString: split.id) else {
                throw ConvexRevisionedSyncError.invalidExpense(field: "splits.id")
            }
            guard let memberID = UUID(uuidString: split.member_id) else {
                throw ConvexRevisionedSyncError.invalidExpense(field: "splits.member_id")
            }
            return ExpenseSplit(
                id: id,
                memberId: memberID,
                amount: split.amount,
                isSettled: split.is_settled
            )
        }
        let participantNames = try validatedParticipantNames()
        let validatedSubexpenses = try subexpenses?.map { subexpense -> Subexpense in
            guard let id = UUID(uuidString: subexpense.id) else {
                throw ConvexRevisionedSyncError.invalidExpense(field: "subexpenses.id")
            }
            return Subexpense(id: id, amount: subexpense.amount)
        }
        let contextKind: ExpenseContextKind
        if let rawContextKind = context_kind {
            guard let parsedContextKind = ExpenseContextKind(rawValue: rawContextKind) else {
                throw ConvexRevisionedSyncError.invalidExpense(field: "context_kind")
            }
            contextKind = parsedContextKind
        } else {
            contextKind = .group
        }

        return Expense(
            id: expenseID,
            groupId: groupID,
            description: description,
            date: Date(timeIntervalSince1970: date / 1_000),
            totalAmount: total_amount,
            paidByMemberId: paidByMemberID,
            involvedMemberIds: involvedMemberIDs,
            splits: validatedSplits,
            isSettled: is_settled,
            contextKind: contextKind,
            participantNames: participantNames,
            subexpenses: validatedSubexpenses,
            notes: notes,
            ownerEmail: owner_email,
            ownerAccountId: owner_account_id
        )
    }

    private func validatedParticipantNames() throws -> [UUID: String]? {
        guard let participants, !participants.isEmpty else { return nil }
        var names: [UUID: String] = [:]
        for participant in participants {
            guard let memberID = UUID(uuidString: participant.member_id) else {
                throw ConvexRevisionedSyncError.invalidExpense(field: "participants.member_id")
            }
            let name = participant.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                names[memberID] = name
            }
        }
        return names.isEmpty ? nil : names
    }
}
#endif
