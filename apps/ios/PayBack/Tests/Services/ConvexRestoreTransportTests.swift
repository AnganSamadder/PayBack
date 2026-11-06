import XCTest
@testable import PayBack

#if !PAYBACK_CI_NO_CONVEX
import ConvexMobile

@MainActor
final class ConvexRestoreTransportTests: XCTestCase {
    func testRealAdapterDecodesOnlyExactStructuredBudgetFailures() async throws {
        for scope in ["request", "identity", "group", "expense", "references", "revisions"] {
            let transport = RestoreWireTransport(failure: .structured("{\"code\":\"IMPORT_BUDGET_EXCEEDED\",\"scope\":\"\(scope)\"}"))
            do {
                _ = try await ConvexAccountService(transport: transport).bulkImport(request: emptyRequest())
                XCTFail("Expected exact budget classification")
            } catch { XCTAssertEqual(error as? ImportTransportError, .budgetExceeded(scope: scope)) }
        }
        for failure in [RestoreWireTransport.Failure.structured("not JSON IMPORT_BUDGET_EXCEEDED"),
                        .structured(#"{"code":"IMPORT_BUDGET_EXCEEDED","scope":"unknown"}"#),
                        .structured(#"{"code":"OTHER_IMPORT_BUDGET_EXCEEDED","scope":"request"}"#),
                        .server("IMPORT_BUDGET_EXCEEDED: request")] {
            do {
                _ = try await ConvexAccountService(transport: RestoreWireTransport(failure: failure)).bulkImport(request: emptyRequest())
                XCTFail("Expected deterministic rejection")
            } catch {
                guard let typed = error as? ImportTransportError, case .rejected = typed else { return XCTFail("Misclassified: \(error)") }
            }
        }
    }

    func testRealAdapterPreservesHistoryRecoveryPayloadAndUncertainFailures() async throws {
        let payload = #"{"code":"HISTORY_RECONCILIATION_FAILED","retryable":false,"job_id":"job","group_id":"group","visible_expense_id":"visible-expense"}"#
        do {
            _ = try await ConvexAccountService(transport: RestoreWireTransport(failure: .structured(payload))).bulkImport(request: emptyRequest())
            XCTFail("Expected recovery")
        } catch {
            let recovery = try XCTUnwrap(error as? GroupHistoryRecoveryError)
            XCTAssertEqual(recovery.jobId, "job")
            XCTAssertEqual(recovery.groupId, "group")
            XCTAssertEqual(recovery.visibleExpenseId, "visible-expense")
            XCTAssertFalse(recovery.retryable)
        }
        do {
            _ = try await ConvexAccountService(transport: RestoreWireTransport(failure: .internalFailure)).bulkImport(request: emptyRequest())
            XCTFail("Expected uncertain outcome")
        } catch { XCTAssertEqual(error as? ImportTransportError, .uncertainOutcome) }
        do {
            _ = try await ConvexAccountService(transport: RestoreWireTransport(failure: .cancelled)).bulkImport(request: emptyRequest())
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testParserRemappingImporterRealAdapterPreserves64Member100ExpenseHistory() async throws {
        let owner = GroupMember(name: "Owner")
        let historical = GroupMember(name: "Historical B")
        let members = [owner] + (1..<64).map { GroupMember(name: "Raw member \($0)") }
        let group = SpendingGroup(name: "64 current members", members: members)
        let expenses = (0..<100).map { index in
            Expense(groupId: group.id, description: "Expense \(index)", date: Date(timeIntervalSince1970: 1_700_000_000),
                totalAmount: 3.0004, paidByMemberId: owner.id, involvedMemberIds: [owner.id, historical.id],
                splits: [ExpenseSplit(memberId: owner.id, amount: 1.0004, isSettled: true),
                         ExpenseSplit(memberId: historical.id, amount: 2, isSettled: false)],
                participantNames: [owner.id: owner.name, historical.id: historical.name],
                subexpenses: [Subexpense(amount: 1.0004), Subexpense(amount: 2)], notes: "Original note", currencyCode: nil)
        }
        let backup = DataExportService.exportAllData(groups: [group], expenses: expenses, friends: [], currentUser: owner, accountEmail: "a@example.test")
        let parsed = try DataImportService.parseExport(backup)
        let remappedMember = UUID(), remappedGroup = UUID()
        let transport = RestoreWireTransport(adaptiveBudgets: true)
        let result = await DataImportService.performBulkImport(from: parsed,
            memberIdMapping: [historical.id: remappedMember], groupIdMapping: [group.id: remappedGroup],
            accountService: ConvexAccountService(transport: transport), expectedAccountID: "A",
            expectedAccountEmail: "a@example.test", isCurrent: { true }, sleeper: { _ in })
        guard case .success(let summary) = result else { return XCTFail("Expected complete wire import: \(result)") }
        XCTAssertEqual(summary.groupsAdded, 1)
        XCTAssertEqual(summary.expensesAdded, 100)
        XCTAssertEqual(summary.processedItems, 101)
        let calls = await transport.calls()
        let groupCalls = try calls.filter { try $0.array("groups").count > 0 }
        let emittedGroup = try XCTUnwrap(try groupCalls.first?.array("groups").first)
        XCTAssertEqual((emittedGroup["members"] as? [[String: Any]])?.count, 64)
        XCTAssertEqual(emittedGroup["id"] as? String, remappedGroup.uuidString)
        let committed = await transport.committedExpensePayloads()
        XCTAssertEqual(committed.count, 100)
        for original in expenses {
            let payload = try XCTUnwrap(committed[original.id.uuidString.lowercased()])
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
            XCTAssertEqual(object["group_id"] as? String, remappedGroup.uuidString)
            XCTAssertEqual(object["total_amount"] as? Double, original.totalAmount)
            XCTAssertEqual(object["notes"] as? String, original.notes)
            XCTAssertNil(object["currency_code"])
            let splits = try XCTUnwrap(object["splits"] as? [[String: Any]])
            XCTAssertEqual(splits.compactMap { $0["id"] as? String }, original.splits.map { $0.id.uuidString })
            XCTAssertEqual(splits.compactMap { $0["amount"] as? Double }, original.splits.map(\.amount))
            XCTAssertEqual(splits.compactMap { $0["is_settled"] as? Bool }, original.splits.map(\.isSettled))
        }
        let expenseCalls = try calls.filter { try !$0.array("expenses").isEmpty }
        XCTAssertTrue(expenseCalls.contains { (try? $0.array("expenses").count) == 8 })
        XCTAssertTrue(expenseCalls.contains { (try? $0.array("expenses").count) == 4 })
        for call in expenseCalls {
            XCTAssertEqual(try call.array("groups").count, 0)
            XCTAssertEqual(call.arguments["financial_contract_version"], "2")
            XCTAssertEqual(call.arguments["expected_account_id"], "\"A\"")
            let entries = try call.array("history_manifest")
            XCTAssertEqual(entries.count, try call.array("expenses").count)
            for entry in entries {
                XCTAssertEqual(entry["group_id"] as? String, remappedGroup.uuidString)
                XCTAssertEqual(Set(entry["historical_member_ids"] as? [String] ?? []), Set([owner.id.uuidString, remappedMember.uuidString]))
            }
        }
    }

    func testParserImporterRealAdapterSubdivides24FreshGroupHeadersAndFriends() async throws {
        let owner = GroupMember(name: "Owner")
        let groups = (0..<24).map { index in
            SpendingGroup(name: "Group \(index)", members: [owner] + (1..<64).map { GroupMember(name: "Member \($0)") })
        }
        let friends = (0..<20).map { AccountFriend(memberId: UUID(), name: "Friend \($0)") }
        let parsed = try DataImportService.parseExport(DataExportService.exportAllData(
            groups: groups, expenses: [], friends: friends, currentUser: owner, accountEmail: "a@example.test"))
        let transport = RestoreWireTransport(adaptiveBudgets: true)
        let result = await DataImportService.performBulkImport(from: parsed, accountService: ConvexAccountService(transport: transport),
            expectedAccountID: "A", expectedAccountEmail: "a@example.test", isCurrent: { true }, sleeper: { _ in })
        guard case .success(let summary) = result else { return XCTFail("Expected complete headers: \(result)") }
        XCTAssertEqual(summary.groupsAdded, 24)
        XCTAssertEqual(summary.friendsAdded, 20)
        let calls = await transport.calls()
        var groupPhaseStarted = false
        for call in calls {
            let incomingGroups = try call.array("groups"), incomingFriends = try call.array("friends")
            XCTAssertLessThanOrEqual(incomingGroups.count, 4)
            XCTAssertLessThanOrEqual(incomingFriends.count, 16)
            XCTAssertTrue(try call.array("expenses").isEmpty)
            XCTAssertNil(call.arguments["history_manifest"])
            if !incomingGroups.isEmpty { groupPhaseStarted = true }
            if groupPhaseStarted { XCTAssertTrue(incomingFriends.isEmpty) }
            for group in incomingGroups { XCTAssertEqual((group["members"] as? [Any])?.count, 64) }
        }
    }

    func testTwo64MemberRestoreCyclesRefreshRawAndCanonicalHistoryWithoutImportingRelinkAuthority() async throws {
        Dependencies.reset()
        defer { Dependencies.reset() }
        let owner = GroupMember(name: "Owner"), raw = GroupMember(name: "Original X")
        let canonicalB = UUID(), canonicalC = UUID()
        let members = [owner, raw] + (2..<64).map { GroupMember(name: "Raw member \($0)") }
        let group = SpendingGroup(name: "Portable raw roster", members: members,
            memberIdentityMap: [raw.id: canonicalB])
        let originals = (0..<100).map { index in
            let historicalID = index.isMultiple(of: 2) ? raw.id : canonicalB
            return Expense(groupId: group.id, description: "Historical \(index)",
                date: Date(timeIntervalSince1970: 1_700_000_000), totalAmount: 3.0004,
                paidByMemberId: owner.id, involvedMemberIds: [owner.id, historicalID],
                splits: [ExpenseSplit(memberId: owner.id, amount: 1.0004, isSettled: true),
                    ExpenseSplit(memberId: historicalID, amount: 2, isSettled: false)],
                participantNames: [owner.id: "Original owner", historicalID: "Historical name \(index)"],
                subexpenses: [Subexpense(amount: 1.0004), Subexpense(amount: 2)], notes: "Keep \(index)",
                currencyCode: index.isMultiple(of: 2) ? nil : "USD",
                financialIdentityMap: [raw.id: canonicalB])
        }
        let account = MockAccountServiceForAppStore()
        let groups = MockGroupCloudServiceForAppStore(), expenses = MockExpenseCloudServiceForAppStore()
        let user = UserAccount(id: "A", email: "a@example.test", displayName: "Owner", linkedMemberId: owner.id)
        await account.addAccount(user)
        let store = AppStore(persistence: MockPersistenceService(), accountService: account,
            expenseCloudService: expenses, groupCloudService: groups, skipClerkInit: true)
        store.currentUser = owner
        store.session = UserSession(account: user)
        store.groups = [group]
        store.expenses = originals
        store.friends = [AccountFriend(memberId: raw.id, name: raw.name, hasLinkedAccount: true,
            linkedAccountId: "B", linkedAccountEmail: "b@example.test")]
        let transport = RestoreWireTransport(adaptiveBudgets: true)
        let importer = ConvexAccountService(transport: transport)

        for cycle in 0..<2 {
            let exported = DataExportService.exportAllData(groups: store.groups, expenses: store.expenses,
                friends: store.friends, currentUser: store.currentUser, accountEmail: user.email)
            let parsed = try DataImportService.parseExport(exported)
            store.groups = []; store.expenses = []; store.friends = []
            try await groups.clearAllData()
            try await expenses.clearAllData()
            try await account.clearFriends()
            await transport.clearImportedState()
            let callOffset = await transport.calls().count
            XCTAssertTrue(store.groups.isEmpty && store.expenses.isEmpty && store.friends.isEmpty)

            let result = await DataImportService.performBulkImport(from: parsed, accountService: importer,
                expectedAccountID: "A", expectedAccountEmail: user.email, isCurrent: { true }, sleeper: { _ in })
            guard case .success(let summary) = result else { return XCTFail("Cycle \(cycle) failed: \(result)") }
            XCTAssertEqual(summary.groupsAdded, 1)
            XCTAssertEqual(summary.expensesAdded, 100)
            XCTAssertEqual(summary.friendsAdded, 1)
            // Acknowledgement alone cannot publish the backed-up source arrays.
            XCTAssertTrue(store.groups.isEmpty && store.expenses.isEmpty && store.friends.isEmpty)
            let cycleCalls = Array(await transport.calls().dropFirst(callOffset))
            for call in cycleCalls {
                for header in try call.array("groups") {
                    let roster = try XCTUnwrap(header["members"] as? [[String: Any]])
                    XCTAssertEqual(roster.count, 64)
                    XCTAssertEqual(Set(roster.compactMap { $0["id"] as? String }), Set(members.map { $0.id.uuidString }))
                    XCTAssertNil(header["member_identity_map"])
                }
                for friend in try call.array("friends") {
                    XCTAssertNil(friend["has_linked_account"])
                    XCTAssertNil(friend["linked_account_id"])
                    XCTAssertNil(friend["linked_account_email"])
                }
                let rows = try call.array("expenses"), manifest = try call.array("history_manifest")
                XCTAssertEqual(rows.count, manifest.count)
                for row in rows {
                    XCTAssertNil(row["financial_identity_map"])
                    let entry = try XCTUnwrap(manifest.first { ($0["expense_id"] as? String) == (row["id"] as? String) })
                    let ids = Set(row["involved_member_ids"] as? [String] ?? [])
                    XCTAssertEqual(Set(entry["historical_member_ids"] as? [String] ?? []), ids)
                    XCTAssertEqual(entry["group_id"] as? String, group.id.uuidString)
                    for participant in row["participants"] as? [[String: Any]] ?? [] {
                        XCTAssertNil(participant["linked_account_id"])
                        XCTAssertNil(participant["linked_account_email"])
                    }
                }
            }

            // The recording server supplies a later relink projection on cycle 2.
            // These are authoritative response DTOs, never imported alias claims.
            let target = cycle == 0 ? canonicalB : canonicalC
            let snapshots = try await transport.authoritativeSnapshots(identityMap: [raw.id.uuidString: target.uuidString])
            for snapshot in snapshots.groups { await groups.addGroup(snapshot) }
            for snapshot in snapshots.expenses { await expenses.addExpense(snapshot) }
            try await account.syncFriends(accountEmail: user.email, friends: [AccountFriend(memberId: raw.id, name: raw.name)])
            let refresh = await store.refreshAfterImport(expectedAccountID: "A", expectedDataEpoch: store.dataEpoch)
            guard case .complete = refresh else { return XCTFail("Cycle \(cycle) did not hydrate: \(refresh)") }
            let refreshedGroup = try XCTUnwrap(store.groups.first)
            XCTAssertEqual(store.groups.count, 1)
            XCTAssertEqual(refreshedGroup.members.map(\.id), members.map(\.id))
            XCTAssertEqual(refreshedGroup.memberIdentityMap, [raw.id: target])
            XCTAssertEqual(store.expenses.count, originals.count)
            XCTAssertEqual(Set(store.expenses.map(\.id)), Set(originals.map(\.id)))
            XCTAssertEqual(store.friends.map(\.memberId), [raw.id])
            XCTAssertFalse(try XCTUnwrap(store.friends.first).hasLinkedAccount)
            for original in originals {
                let refreshed = try XCTUnwrap(store.expenses.first { $0.id == original.id })
                XCTAssertEqual(refreshed.groupId, original.groupId)
                XCTAssertEqual(refreshed.description, original.description)
                XCTAssertEqual(refreshed.date, original.date)
                XCTAssertEqual(refreshed.totalAmount, original.totalAmount)
                XCTAssertEqual(refreshed.paidByMemberId, original.paidByMemberId)
                XCTAssertEqual(refreshed.involvedMemberIds, original.involvedMemberIds)
                XCTAssertEqual(refreshed.splits, original.splits)
                XCTAssertEqual(refreshed.isSettled, original.isSettled)
                XCTAssertEqual(refreshed.participantNames, original.participantNames)
                XCTAssertEqual(refreshed.subexpenses, original.subexpenses)
                XCTAssertEqual(refreshed.notes, original.notes)
                XCTAssertEqual(refreshed.currencyCode, original.currencyCode)
                XCTAssertEqual(refreshed.financialIdentityMap, [raw.id: target])
            }
        }
    }

    func testLostCommittedResponseReplaysSameIDsAndReportsPresentInsteadOfInventedCreationCount() async throws {
        let transport = RestoreWireTransport(loseFirstCommittedResponse: true)
        var parsed = ParsedExportData()
        parsed.friends = [ParsedFriend(memberId: UUID(), name: "Preserved")]
        let result = await DataImportService.performBulkImport(from: parsed, accountService: ConvexAccountService(transport: transport),
            expectedAccountID: "A", expectedAccountEmail: "a@example.test", isCurrent: { true }, sleeper: { _ in })
        guard case .success(let summary) = result else { return XCTFail("Expected acknowledged replay") }
        XCTAssertEqual(summary.processedItems, 1)
        XCTAssertEqual(summary.friendsAdded, 0)
        XCTAssertEqual(summary.alreadyPresentItems, 1)
        let calls = await transport.calls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].name, calls[1].name)
        XCTAssertEqual(try calls[0].canonicalArguments(), try calls[1].canonicalArguments())
    }

    func testActorChangeDuringRetryDelayStopsRealImporterBeforeReplay() async throws {
        let transport = RestoreWireTransport(loseFirstCommittedResponse: true)
        var parsed = ParsedExportData()
        parsed.friends = [ParsedFriend(memberId: UUID(), name: "A only")]
        var isCurrent = true
        let result = await DataImportService.performBulkImport(from: parsed, accountService: ConvexAccountService(transport: transport),
            expectedAccountID: "A", expectedAccountEmail: "a@example.test", isCurrent: { isCurrent },
            sleeper: { _ in isCurrent = false; await transport.switchActor("B") })
        guard case .partialSuccess(let summary, _) = result else { return XCTFail("Expected incomplete result") }
        XCTAssertEqual(summary.processedItems, 0)
        XCTAssertNotNil(summary.incompletePhase)
        let calls = await transport.calls()
        XCTAssertEqual(calls.count, 1)
    }

    func testHistoryStatusAndResumeUseExactActorCapabilityAndOmitAbsentExpenseHint() async throws {
        let transport = RestoreWireTransport()
        let service = ConvexAccountService(transport: transport)
        let jobs = try await service.pendingGroupHistory(expectedAccountId: "A")
        XCTAssertEqual(jobs.map(\.jobId), ["job"])
        let status = try await service.groupHistoryStatus(jobId: "job", visibleExpenseId: nil, expectedAccountId: "A")
        XCTAssertEqual(status.phase, "pending")
        _ = try await service.resumeGroupHistory(jobId: "job", visibleExpenseId: "expense", expectedAccountId: "A")
        let calls = await transport.calls()
        XCTAssertEqual(calls.map(\.name), ["groupHistory:pending", "groupHistory:status", "groupHistory:resume"])
        XCTAssertTrue(calls.allSatisfy { $0.arguments["expected_account_id"] == "\"A\"" && $0.arguments["financial_contract_version"] == "2" })
        XCTAssertNil(calls[1].arguments["visible_expense_id"])
        XCTAssertEqual(calls[2].arguments["visible_expense_id"], "\"expense\"")
        await transport.switchActor("B")
        do { _ = try await service.resumeGroupHistory(jobId: "job", visibleExpenseId: nil, expectedAccountId: "A"); XCTFail("Expected stale actor rejection") }
        catch {}
    }

    func testBlockedSnapshotsPreserveTypedHistoryAndNeutralAuthentication() async throws {
        let transport = HistorySnapshotTransport()
        let service = ConvexAccountService(transport: transport)
        let account = try await service.lookupAccount(byEmail: "a@example.test")
        XCTAssertEqual(account?.id, "A")
        XCTAssertNil(account?.linkedMemberId)
        do {
            _ = try await service.snapshotGeneration()
            XCTFail("Blocked generation must remain typed")
        } catch { XCTAssertEqual((error as? GroupHistoryRecoveryError)?.jobId, "job") }
        do {
            _ = try await ConvexGroupService(transport: transport).fetchGroups()
            XCTFail("Blocked group snapshot must remain typed")
        } catch { XCTAssertEqual((error as? GroupHistoryRecoveryError)?.jobId, "job") }
        let names = await transport.names()
        XCTAssertFalse(names.contains("groups:listLegacyPage"))
        XCTAssertFalse(names.contains("groups:list"))
    }

    func testExpenseMutationPreservesTypedHistoryRecoveryWithoutRewritingItAsValidation() async {
        let service = ConvexExpenseService(transport: HistorySnapshotTransport())
        do {
            try await service.deleteExpense(UUID(), expectedAccountId: "A")
            XCTFail("Pending history must keep the expense fenced")
        } catch {
            XCTAssertEqual((error as? GroupHistoryRecoveryError)?.code, "HISTORY_RECONCILIATION_PENDING")
            XCTAssertEqual((error as? GroupHistoryRecoveryError)?.jobId, "job")
        }
    }

    func testFriendClearResumesHistoryOnceAndReportsIncompleteWithoutSpinning() async {
        let transport = FriendClearHistoryTransport()
        let service = ConvexAccountService(transport: transport)
        do {
            try await service.clearFriends(expectedAccountId: "A")
            XCTFail("Pending history cannot acknowledge a completed clear")
        } catch {
            guard let paybackError = error as? PayBackError, case .underlying(let message) = paybackError else { return XCTFail("Expected recoverable clear error: \(error)") }
            XCTAssertTrue(message.contains("still reconciling"))
        }
        let names = await transport.names()
        XCTAssertEqual(names, ["friends:clearAllForUserV2", "users:authenticationStatus", "identityOperations:pending", "identityOperations:resume"])
    }

    private func emptyRequest() -> BulkImportRequest {
        var request = BulkImportRequest(friends: [], groups: [], expenses: [])
        request.expected_account_id = "A"; request.expected_account_email = "a@example.test"
        return request
    }
}

private actor FriendClearHistoryTransport: ConvexServiceTransport {
    private var operations: [String] = []
    func names() -> [String] { operations }
    func query<Response: Decodable & Sendable>(_ name: String, arguments: [String: String], yielding: Response.Type) async throws -> Response {
        operations.append(name)
        let json = name == "users:authenticationStatus"
            ? #"{"id":"A","email":"a@example.test","display_name":"A"}"#
            : #"{"operation_id":"operation","status":"pending"}"#
        return try JSONDecoder().decode(Response.self, from: Data(json.utf8))
    }
    func mutation<Response: Decodable & Sendable>(_ name: String, arguments: [String: String], yielding: Response.Type) async throws -> Response {
        operations.append(name)
        guard arguments["expected_account_id"] == "\"A\"" else { throw ClientError.ServerError(msg: "Actor changed") }
        let json = name == "friends:clearAllForUserV2"
            ? #"{"inProgress":true,"processed":0,"cutoff":42}"#
            : #"{"operation_id":"operation","status":"pending"}"#
        return try JSONDecoder().decode(Response.self, from: Data(json.utf8))
    }
}

private actor HistorySnapshotTransport: ConvexServiceTransport {
    private var queries: [String] = []
    func names() -> [String] { queries }
    func query<Response: Decodable & Sendable>(_ name: String, arguments: [String: String], yielding: Response.Type) async throws -> Response {
        queries.append(name)
        if name == "users:authenticationStatus" {
            return try JSONDecoder().decode(Response.self, from: Data(#"{"id":"A","email":"a@example.test","display_name":"A"}"#.utf8))
        }
        throw ClientError.ConvexError(data: #"{"code":"HISTORY_RECONCILIATION_PENDING","retryable":true,"job_id":"job","group_id":"group"}"#)
    }
    func mutation<Response: Decodable & Sendable>(_ name: String, arguments: [String: String], yielding: Response.Type) async throws -> Response {
        throw ClientError.ConvexError(data: #"{"code":"HISTORY_RECONCILIATION_PENDING","retryable":true,"job_id":"job","group_id":"group"}"#)
    }
}

private actor RestoreWireTransport: ConvexServiceTransport {
    enum Failure: Sendable { case structured(String), server(String), internalFailure, cancelled }
    struct Call: Sendable {
        let name: String
        let arguments: [String: String]
        func array(_ key: String) throws -> [[String: Any]] {
            try JSONSerialization.jsonObject(with: Data((arguments[key] ?? "[]").utf8)) as? [[String: Any]] ?? []
        }
        func canonicalArguments() throws -> [String: Data] {
            try arguments.mapValues { encoded in
                let value = try JSONSerialization.jsonObject(with: Data(encoded.utf8), options: .fragmentsAllowed)
                // Object key order is irrelevant; array order, values and Convex
                // numeric wrapper objects remain part of the exact comparison.
                return try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
            }
        }
    }
    private let failure: Failure?
    private let adaptiveBudgets: Bool
    private let loseFirstCommittedResponse: Bool
    private var recorded: [Call] = []
    private var present = Set<String>()
    private var expensePayloads: [String: String] = [:]
    private var groupPayloads: [String: String] = [:]
    private var actorID = "A"

    init(failure: Failure? = nil, adaptiveBudgets: Bool = false, loseFirstCommittedResponse: Bool = false) {
        self.failure = failure; self.adaptiveBudgets = adaptiveBudgets; self.loseFirstCommittedResponse = loseFirstCommittedResponse
    }
    func calls() -> [Call] { recorded }
    func committedExpensePayloads() -> [String: String] { expensePayloads }
    func clearImportedState() {
        present.removeAll(); expensePayloads.removeAll(); groupPayloads.removeAll()
    }
    func authoritativeSnapshots(identityMap: [String: String]) throws -> (groups: [SpendingGroup], expenses: [Expense]) {
        let decoder = JSONDecoder()
        let groups = try groupPayloads.values.map { payload in
            var object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as! [String: Any]
            object["created_at"] = 1_700_000_000_000.0
            object["member_identity_map"] = identityMap
            return try decoder.decode(ConvexGroupDTO.self, from: JSONSerialization.data(withJSONObject: object)).validatedSpendingGroup()
        }
        let expenses = try expensePayloads.values.map { payload in
            var object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as! [String: Any]
            object["financial_identity_map"] = identityMap
            return try decoder.decode(ConvexExpenseDTO.self, from: JSONSerialization.data(withJSONObject: object)).validatedExpense()
        }
        return (groups, expenses)
    }
    func switchActor(_ id: String) { actorID = id }
    private func checkActor(_ args: [String: String]) throws {
        guard args["expected_account_id"] == "\"\(actorID)\"" else { throw ClientError.ServerError(msg: "Authenticated actor changed") }
    }
    private func failIfRequested() throws {
        switch failure {
        case .structured(let data): throw ClientError.ConvexError(data: data)
        case .server(let message): throw ClientError.ServerError(msg: message)
        case .internalFailure: throw ClientError.InternalError(msg: "Response lost")
        case .cancelled: throw CancellationError()
        case nil: break
        }
    }
    func mutation<Response: Decodable & Sendable>(_ name: String, arguments: [String: String], yielding: Response.Type) async throws -> Response {
        let call = Call(name: name, arguments: arguments)
        recorded.append(call)
        try checkActor(arguments)
        try failIfRequested()
        if name == "groupHistory:resume" { return try historyResult(Response.self) }
        let kinds = [("friend", "friends", 8), ("group", "groups", 2), ("expense", "expenses", 4)]
        if adaptiveBudgets {
            for (kind, key, limit) in kinds where try call.array(key).count > limit {
                let scope = kind == "friend" ? "identity" : kind
                throw ClientError.ConvexError(data: "{\"code\":\"IMPORT_BUDGET_EXCEEDED\",\"scope\":\"\(scope)\"}")
            }
        }
        var outcomes: [[String: Any]] = []
        var counts = ["friends": 0, "groups": 0, "expenses": 0]
        for (kind, key, _) in kinds {
            for item in try call.array(key) {
                let id = (item[kind == "friend" ? "member_id" : "id"] as! String).lowercased()
                let inserted = present.insert(kind + ":" + id).inserted
                outcomes.append(["kind": kind, "id": id, "status": inserted ? "created" : "already_present"])
                if inserted { counts[key, default: 0] += 1 }
                if kind == "expense" {
                    expensePayloads[id] = String(decoding: try JSONSerialization.data(withJSONObject: item, options: .sortedKeys), as: UTF8.self)
                }
                if kind == "group" {
                    groupPayloads[id] = String(decoding: try JSONSerialization.data(withJSONObject: item, options: .sortedKeys), as: UTF8.self)
                }
            }
        }
        if loseFirstCommittedResponse && recorded.count == 1 { throw ClientError.InternalError(msg: "Lost after commit") }
        let data = try JSONSerialization.data(withJSONObject: ["success": true, "created": counts, "errors": [], "outcomes": outcomes])
        return try JSONDecoder().decode(Response.self, from: data)
    }
    func query<Response: Decodable & Sendable>(_ name: String, arguments: [String: String], yielding: Response.Type) async throws -> Response {
        recorded.append(Call(name: name, arguments: arguments))
        try checkActor(arguments)
        try failIfRequested()
        if name == "groupHistory:pending" {
            return try JSONDecoder().decode(Response.self, from: Data(#"{"page":[{"job_id":"job","group_id":"group","phase":"pending","retryable":true}],"isDone":true,"continueCursor":""}"#.utf8))
        }
        return try historyResult(Response.self)
    }
    private func historyResult<Response: Decodable>(_ response: Response.Type) throws -> Response {
        try JSONDecoder().decode(response, from: Data(#"{"job_id":"job","group_id":"group","phase":"pending","retryable":true}"#.utf8))
    }
}
#endif
