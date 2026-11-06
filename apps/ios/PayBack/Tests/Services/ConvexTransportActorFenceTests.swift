import XCTest
@testable import PayBack

#if !PAYBACK_CI_NO_CONVEX
/// The fake replaces only the wire boundary. The account adapter, friend loop,
/// import chunking, retry policy and AppStore publication code remain real.
@MainActor
final class ConvexTransportActorFenceTests: XCTestCase {
    private let emailA = "a@example.test"

    func testSuccessfulFriendSyncPublishesAcknowledgedCache() async throws {
        let transport = AuthSwitchTransport(pause: .none, onPause: {})
        let service = ConvexAccountService(transport: transport)
        let friends = [AccountFriend(memberId: UUID(), name: "Acknowledged")]
        try await service.syncFriends(accountEmail: " A@EXAMPLE.TEST ", friends: friends)
        let cache = await service.cachedFriendSnapshot()
        let state = await transport.snapshot()
        XCTAssertEqual(cache, friends)
        XCTAssertEqual(state.committedActors, ["A"])
    }

    func testSuccessfulImportExecutesAllActualChunks() async {
        let transport = AuthSwitchTransport(pause: .none, onPause: {})
        let service = ConvexAccountService(transport: transport)
        let result = await DataImportService.performBulkImport(from: importFixture(count: 201),
            accountService: service, expectedAccountID: "A", expectedAccountEmail: emailA, isCurrent: { true })
        guard case .success(let summary) = result else { return XCTFail("Expected complete import: \(result)") }
        XCTAssertEqual(summary.expensesAdded, 201)
        let state = await transport.snapshot()
        XCTAssertEqual(state.committedActors, ["A", "A", "A"])
    }

    func testFriendLoopRejectsSecondWriteAfterTransportAuthSwitch() async throws {
        let paused = expectation(description: "First write committed before response")
        let transport = AuthSwitchTransport(pause: .mutation(1), onPause: { paused.fulfill() })
        let service = ConvexAccountService(transport: transport)
        let friends = [AccountFriend(memberId: UUID(), name: "First"), AccountFriend(memberId: UUID(), name: "Second")]
        let task = Task { try await service.syncFriends(accountEmail: emailA, friends: friends) }
        await fulfillment(of: [paused], timeout: 2)
        await transport.resume(as: "B")
        do { try await task.value; XCTFail("Old actor must not write as B") } catch {}

        let state = await transport.snapshot()
        XCTAssertEqual(state.committedActors, ["A"])
        XCTAssertEqual(state.calls.count, 2)
        XCTAssertTrue(state.calls.allSatisfy { $0.arguments["expected_account_email"] == "\"a@example.test\"" })
        XCTAssertTrue(state.calls.allSatisfy { $0.arguments["financial_contract_version"] == "2" })
        let cache = await service.cachedFriendSnapshot()
        XCTAssertTrue(cache.isEmpty)
    }

    func testSwitchBeforeCachePublicationDiscardsCompletedFriendSync() async throws {
        let paused = expectation(description: "Final actor read suspended")
        let transport = AuthSwitchTransport(pause: .query(1), onPause: { paused.fulfill() })
        let service = ConvexAccountService(transport: transport)
        let task = Task { try await service.syncFriends(accountEmail: emailA,
            friends: [AccountFriend(memberId: UUID(), name: "Old account friend")]) }
        await fulfillment(of: [paused], timeout: 2)
        await transport.resume(as: "B")
        do { try await task.value; XCTFail("Stale completion must not publish") }
        catch { XCTAssertTrue(error is CancellationError) }
        let cache = await service.cachedFriendSnapshot()
        XCTAssertTrue(cache.isEmpty)
    }

    func testCancelledFriendSyncStopsAfterInFlightWrite() async throws {
        let paused = expectation(description: "Mutation suspended")
        let transport = AuthSwitchTransport(pause: .mutation(1), onPause: { paused.fulfill() })
        let service = ConvexAccountService(transport: transport)
        let task = Task { try await service.syncFriends(accountEmail: emailA,
            friends: [AccountFriend(memberId: UUID(), name: "First"), AccountFriend(memberId: UUID(), name: "Second")]) }
        await fulfillment(of: [paused], timeout: 2)
        task.cancel()
        await transport.resume(as: "A")
        do { try await task.value; XCTFail("Cancellation is not success") }
        catch { XCTAssertTrue(error is CancellationError) }
        let state = await transport.snapshot()
        let cache = await service.cachedFriendSnapshot()
        XCTAssertEqual(state.calls.count, 1)
        XCTAssertTrue(cache.isEmpty)
    }

    func testRetryAfterAuthSwitchRetainsOriginalExpectedActor() async throws {
        let paused = expectation(description: "Retry delay suspended")
        let transport = AuthSwitchTransport(pause: .none, failFirstMutation: true,
            onPause: { paused.fulfill() })
        let service = ConvexAccountService(transport: transport)
        let policy = RetryPolicy(maxAttempts: 2, sleeper: { _ in await transport.pauseRetry() })
        let task = Task {
            try await policy.execute {
                try await service.syncFriends(accountEmail: "a@example.test",
                    friends: [AccountFriend(memberId: UUID(), name: "Retry")])
            }
        }
        await fulfillment(of: [paused], timeout: 2)
        await transport.resume(as: "B")
        do { try await task.value; XCTFail("Retry must remain bound to A") } catch {}
        let state = await transport.snapshot()
        XCTAssertEqual(state.calls.count, 2)
        XCTAssertTrue(state.committedActors.isEmpty)
        XCTAssertTrue(state.calls.allSatisfy { $0.arguments["expected_account_email"] == "\"a@example.test\"" })
    }

    func testActualImportChunksRejectSwitchedTransportEvenBeforeUIObservesSwitch() async {
        let paused = expectation(description: "First import chunk committed")
        let transport = AuthSwitchTransport(pause: .mutation(1), onPause: { paused.fulfill() })
        let service = ConvexAccountService(transport: transport)
        let parsed = importFixture(count: 201)
        let task = Task {
            await DataImportService.performBulkImport(from: parsed, accountService: service,
                expectedAccountID: "A", expectedAccountEmail: "a@example.test", isCurrent: { true })
        }
        await fulfillment(of: [paused], timeout: 2)
        await transport.resume(as: "B")
        let result = await task.value
        guard case .partialSuccess(let summary, let errors) = result else {
            return XCTFail("Expected acknowledged first chunk plus rejection: \(result)")
        }
        XCTAssertEqual(summary.expensesAdded, 100)
        XCTAssertEqual(errors.count, 1)
        let state = await transport.snapshot()
        XCTAssertEqual(state.committedActors, ["A"])
        XCTAssertEqual(state.calls.count, 2, "Third chunk must not run after rejection")
        XCTAssertTrue(state.calls.allSatisfy { $0.arguments["expected_account_id"] == "\"A\"" })
        XCTAssertTrue(state.calls.allSatisfy { $0.arguments["expected_account_email"] == "\"a@example.test\"" })
        XCTAssertTrue(state.calls.allSatisfy { $0.arguments["financial_contract_version"] == "2" })
    }

    func testActualImportCancellationStopsLaterChunks() async {
        let paused = expectation(description: "Import response suspended")
        let transport = AuthSwitchTransport(pause: .mutation(1), onPause: { paused.fulfill() })
        let service = ConvexAccountService(transport: transport)
        let parsed = importFixture(count: 201)
        let task = Task {
            await DataImportService.performBulkImport(from: parsed, accountService: service,
                expectedAccountID: "A", expectedAccountEmail: "a@example.test", isCurrent: { true })
        }
        await fulfillment(of: [paused], timeout: 2)
        task.cancel()
        await transport.resume(as: "A")
        let result = await task.value
        guard case .incompatibleFormat = result else { return XCTFail("Cancelled import reported success") }
        let state = await transport.snapshot()
        XCTAssertEqual(state.calls.count, 1)
    }

    func testAppStoreDoesNotPublishOldFriendIntoNewSession() async throws {
        let paused = expectation(description: "Real friend adapter response suspended")
        let transport = AuthSwitchTransport(pause: .mutation(1), onPause: { paused.fulfill() })
        let service = ConvexAccountService(transport: transport)
        let store = AppStore(persistence: MockPersistenceService(), accountService: service,
            expenseCloudService: NoopExpenseCloudService(), groupCloudService: NoopGroupCloudService(),
            linkRequestService: MockLinkRequestServiceForAppStore(), inviteLinkService: MockInviteLinkServiceForTests(),
            emailAuthService: MockEmailAuthService(),
            skipClerkInit: true)
        store.session = UserSession(account: UserAccount(id: "A", email: emailA, displayName: "A"))
        let task = Task { try await store.addUnlinkedFriend(GroupMember(name: "A's friend")) }
        await fulfillment(of: [paused], timeout: 2)
        store.session = UserSession(account: UserAccount(id: "B", email: "b@example.test", displayName: "B"))
        let existing = AccountFriend(memberId: UUID(), name: "B's existing friend")
        store.friends = [existing]
        await transport.resume(as: "B")
        do { try await task.value; XCTFail("Old session must not report success") } catch {}
        XCTAssertEqual(store.session?.account.id, "B")
        XCTAssertEqual(store.friends, [existing])
        let cache = await service.cachedFriendSnapshot()
        XCTAssertTrue(cache.isEmpty)
    }

    func testGroupCleanupKeepsExpectedActorAcrossBatches() async throws {
        let paused = expectation(description: "First cleanup batch committed")
        let transport = AuthSwitchTransport(pause: .mutation(1), onPause: { paused.fulfill() })
        let service = ConvexGroupService(transport: transport)
        let task = Task { try await service.clearAllData(expectedAccountId: "A") }
        await fulfillment(of: [paused], timeout: 2)
        await transport.resume(as: "B")
        do { try await task.value; XCTFail("Cleanup must not continue under B") } catch {}
        let state = await transport.snapshot()
        XCTAssertEqual(state.committedActors, ["A"])
        XCTAssertEqual(state.calls.count, 2)
        XCTAssertTrue(state.calls.allSatisfy { $0.arguments["expected_account_id"] == "\"A\"" })
        XCTAssertTrue(state.calls.allSatisfy { $0.arguments["financial_contract_version"] == "2" })
        XCTAssertNil(state.calls.first?.arguments["cutoff"], "Optional number must be omitted on the first batch, not null")
        XCTAssertEqual(state.calls.last?.arguments["cutoff"], "42")
    }

    func testGroupPaginationOmitsAbsentCursorAndUsesConvexNumbers() async throws {
        let transport = AuthSwitchTransport(pause: .none, onPause: {})
        let service = ConvexGroupService(transport: transport)
        _ = try await service.fetchGroupsPaginated()
        _ = try await service.fetchGroupsPaginated(cursor: "next-page", limit: 8)
        let state = await transport.snapshot()
        XCTAssertEqual(state.queries.count, 2)
        XCTAssertNil(state.queries[0].arguments["cursor"])
        XCTAssertEqual(state.queries[0].arguments["limit"], "20")
        XCTAssertEqual(state.queries[0].arguments["financial_contract_version"], "2")
        XCTAssertEqual(state.queries[1].arguments["cursor"], "\"next-page\"")
        XCTAssertEqual(state.queries[1].arguments["limit"], "8")
    }

    func testGroupCreateOmitsAbsentMemberMetadata() async throws {
        let transport = AuthSwitchTransport(pause: .none, onPause: {})
        let service = ConvexGroupService(transport: transport)
        let group = SpendingGroup(name: "Wire contract", members: [GroupMember(name: "Member")])
        try await service.upsertGroup(group, expectedAccountId: "A")
        let state = await transport.snapshot()
        let encoded = try XCTUnwrap(state.calls.first?.arguments["members"])
        let members = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [[String: Any]])
        XCTAssertNil(members[0]["profile_image_url"])
        XCTAssertNil(members[0]["profile_avatar_color"])
        XCTAssertEqual(state.calls.first?.arguments["financial_contract_version"], "2")
        XCTAssertEqual(state.calls.first?.arguments["expected_account_id"], "\"A\"")
    }

    func testLegacyGroupMutationWithoutCapturedActorFailsBeforeTransport() async {
        let transport = AuthSwitchTransport(pause: .none, onPause: {})
        let service = ConvexGroupService(transport: transport)
        do { try await service.deleteGroups([UUID()]); XCTFail("Expected actor is required") }
        catch ConvexServiceTransportError.expectedActorRequired {}
        catch { XCTFail("Unexpected error: \(error)") }
        let state = await transport.snapshot()
        XCTAssertTrue(state.calls.isEmpty)
    }

    func testOlderClearCannotEraseNewerSameAccountFriendCache() async throws {
        try await assertOlderClearPreservesNewerCache(newActor: "A")
    }

    func testOlderClearCannotEraseNewAccountFriendCache() async throws {
        try await assertOlderClearPreservesNewerCache(newActor: "B")
    }

    private func assertOlderClearPreservesNewerCache(newActor: String) async throws {
        let paused = expectation(description: "Final clear response suspended")
        let transport = AuthSwitchTransport(pause: .mutation(1), onPause: { paused.fulfill() })
        let service = ConvexAccountService(transport: transport)
        let clear = Task { try await service.clearFriends(expectedAccountId: "A") }
        await fulfillment(of: [paused], timeout: 2)
        await transport.switchActorWithoutResuming(newActor)
        let newer = [AccountFriend(memberId: UUID(), name: "Newer friend")]
        try await service.syncFriends(accountEmail: newActor.lowercased() + "@example.test", friends: newer)
        await transport.resume(as: newActor)
        do { try await clear.value; XCTFail("Superseded clear must not commit its cache") }
        catch { XCTAssertTrue(error is CancellationError) }
        let cached = await service.cachedFriendSnapshot()
        XCTAssertEqual(cached, newer)
    }

    func testRealFriendUpsertOmitsAbsentOptionalStrings() async throws {
        let transport = FriendUpsertContractTransport()
        let service = ConvexAccountService(transport: transport)
        try await service.syncFriends(accountEmail: "a@example.test", friends: [AccountFriend(memberId: UUID(), name: "New friend")])
        let payloads = await transport.recordedArguments()
        let arguments = try XCTUnwrap(payloads.first)
        XCTAssertNil(arguments["original_name"])
        XCTAssertNil(arguments["original_nickname"])
        XCTAssertEqual(arguments["display_preference"], "null", "This field explicitly permits null to clear a preference")
    }

    func testRealFriendUpsertPreservesPresentOriginalNames() async throws {
        let transport = FriendUpsertContractTransport()
        let service = ConvexAccountService(transport: transport)
        let friend = AccountFriend(memberId: UUID(), name: "Display", originalName: "Original", originalNickname: "Old nickname", preferNickname: true)
        try await service.syncFriends(accountEmail: "a@example.test", friends: [friend])
        let payloads = await transport.recordedArguments()
        let arguments = try XCTUnwrap(payloads.first)
        XCTAssertEqual(arguments["original_name"], "\"Original\"")
        XCTAssertEqual(arguments["original_nickname"], "\"Old nickname\"")
        XCTAssertEqual(arguments["prefer_nickname"], "true")
    }

    func testRealFriendMergeAdapterMatchesBackendV3ValidatorAndDirection() async throws {
        let source = UUID()
        let target = UUID()
        let transport = FriendMergeContractTransport(source: source, target: target)
        let service = ConvexAccountService(transport: transport)

        let result = try await service.beginFriendMerge(source: source, target: target, expectedAccountId: "A")

        XCTAssertEqual(result.operationId, "merge-operation")
        XCTAssertEqual(result.status, "pending")
        let recordedArguments = await transport.recordedArguments()
        let arguments = try XCTUnwrap(recordedArguments)
        XCTAssertEqual(Set(arguments.keys), ["friendId1", "friendId2", "financial_contract_version", "expected_account_id"])
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(try XCTUnwrap(arguments["friendId1"]).utf8)), target.uuidString)
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(try XCTUnwrap(arguments["friendId2"]).utf8)), source.uuidString)
    }

    func testDeletionRecoveryDiscoversLostReceiptBeforeCanonicalRead() async throws {
        let actorID = UUID().uuidString
        let key = "payback.friendDeletion.\(actorID)"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let transport = AccountRecoveryContractTransport(actorID: actorID)
        let service = ConvexAccountService(transport: transport)
        let neutral = try await service.lookupAccount(byEmail: "a@example.test")
        XCTAssertEqual(neutral?.id, actorID)
        XCTAssertNil(neutral?.linkedMemberId, "Pending lookup returns authentication only")
        try await service.resumePendingFriendDeletion(expectedAccountId: actorID)
        let canonical = try await service.lookupAccount(byEmail: "a@example.test")
        XCTAssertNotNil(canonical?.linkedMemberId)
        let endpoints = await transport.recordedEndpoints()
        XCTAssertEqual(endpoints, ["users:viewer", "users:authenticationStatus", "cleanup:pendingFriendDeletion", "cleanup:resumeFriendDeletion", "cleanup:pendingFriendDeletion", "users:viewer"])
        XCTAssertNil(UserDefaults.standard.string(forKey: key))
    }

    func testDeletionRecoveryDrainsMultipleJobsAndSkipsCancelledSavedReceipt() async throws {
        let actorID = UUID().uuidString
        let key = "payback.friendDeletion.\(actorID)"
        UserDefaults.standard.set("cancelled-job", forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let transport = AccountRecoveryContractTransport(actorID: actorID, jobCount: 2)
        let service = ConvexAccountService(transport: transport)
        try await service.resumePendingFriendDeletion(expectedAccountId: actorID)
        let canonical = try await service.lookupAccount(byEmail: "a@example.test")
        XCTAssertNotNil(canonical?.linkedMemberId)
        let payloads = await transport.recordedMutations()
        XCTAssertEqual(payloads.map { $0["operationId"] }, ["\"cancelled-job\"", "\"lost-receipt-job-2\"", "\"lost-receipt-job-1\""])
        XCTAssertTrue(payloads.allSatisfy { $0["expected_account_id"] == "\"\(actorID)\"" })
        XCTAssertNil(UserDefaults.standard.string(forKey: key))
    }

    func testAccountOptionalFieldsAndCleanupCursorMatchWireContract() async throws {
        let transport = AccountRecoveryContractTransport(actorID: "A", pending: false)
        let service = ConvexAccountService(transport: transport)
        _ = try await service.updateProfile(colorHex: "#123456", imageUrl: nil, expectedAccountId: "A")
        _ = try await service.updateProfile(colorHex: nil, imageUrl: "https://example.test/avatar", expectedAccountId: "A")
        try await service.clearFriends(expectedAccountId: "A")
        let payloads = await transport.recordedMutations()
        XCTAssertNil(payloads[0]["profile_image_url"])
        XCTAssertNil(payloads[1]["profile_avatar_color"])
        XCTAssertNil(payloads[2]["cutoff"])
        XCTAssertEqual(payloads[3]["cutoff"], "42")
        XCTAssertTrue(payloads.allSatisfy { $0["expected_account_id"] == "\"A\"" })
    }

    func testLegacySettingsMigrationUsesCapturedAccount() async throws {
        let transport = AccountRecoveryContractTransport(actorID: "A", pending: false)
        let service = ConvexAccountService(transport: transport)
        let store = AppStore(persistence: MockPersistenceService(), accountService: service,
            expenseCloudService: NoopExpenseCloudService(), groupCloudService: NoopGroupCloudService(),
            linkRequestService: MockLinkRequestServiceForAppStore(), inviteLinkService: MockInviteLinkServiceForTests(),
            emailAuthService: MockEmailAuthService(), skipClerkInit: true)
        store.session = UserSession(account: UserAccount(id: "A", email: emailA, displayName: "A"))
        let suite = "migration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "preferNicknames")
        defaults.set(false, forKey: "preferWholeNames")
        store.migrateLegacyDisplaySettingsIfNeeded(defaults: defaults)
        for _ in 0..<100 where defaults.object(forKey: "preferNicknames") != nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let payloads = await transport.recordedMutations()
        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads.first?["expected_account_id"], "\"A\"")
        XCTAssertEqual(payloads.first?["prefer_nicknames"], "true")
        XCTAssertNil(defaults.object(forKey: "preferNicknames"))
    }

    private func importFixture(count: Int) -> ParsedExportData {
        let memberID = UUID()
        let groupID = UUID()
        var parsed = ParsedExportData()
        parsed.currentUserId = memberID
        parsed.currentUserName = "A"
        parsed.expenses = (0..<count).map { index in
            ParsedExpense(id: UUID(), groupId: groupID, description: "Expense \(index)", date: Date(),
                totalAmount: 1, paidByMemberId: memberID, isSettled: false, isDebug: false,
                contextKind: .groupedIndividual, currencyCode: "USD")
        }
        parsed.expenseSplits = parsed.expenses.map {
            ParsedExpenseSplit(expenseId: $0.id, splitId: UUID(), memberId: memberID, amount: 1, isSettled: false)
        }
        parsed.expenseInvolvedMembers = parsed.expenses.map { (expenseId: $0.id, memberId: memberID) }
        return parsed
    }
}

private actor AccountRecoveryContractTransport: ConvexServiceTransport {
    enum Failure: Error { case FRIEND_DELETION_PENDING, invalidContract }
    let actorID: String
    var pending: Bool
    var remainingJobs: Int
    var endpoints: [String] = []
    var mutations: [[String: String]] = []
    var cleanupCalls = 0
    init(actorID: String, pending: Bool = true, jobCount: Int = 1) { self.actorID = actorID; self.pending = pending; self.remainingJobs = pending ? jobCount : 0 }
    func recordedEndpoints() -> [String] { endpoints }
    func recordedMutations() -> [[String: String]] { mutations }
    private func decode<Response: Decodable>(_ json: String, as type: Response.Type) throws -> Response {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
    func query<Response: Decodable & Sendable>(_ name: String, arguments: [String: String], yielding: Response.Type) async throws -> Response {
        endpoints.append(name)
        guard arguments["financial_contract_version"] == "2" else { throw Failure.invalidContract }
        if name == "cleanup:pendingFriendDeletion" {
            guard arguments["expected_account_id"] == "\"\(actorID)\"" else { throw Failure.invalidContract }
            if !pending { return try decode("null", as: yielding) }
            return try decode("{\"operationId\":\"lost-receipt-job-\(remainingJobs)\",\"phase\":\"preflight_groups\",\"complete\":false}", as: yielding)
        }
        guard name == "users:viewer" || name == "users:authenticationStatus" else { throw Failure.invalidContract }
        if name == "users:viewer", pending { throw Failure.FRIEND_DELETION_PENDING }
        let identity = pending ? "" : ",\"member_id\":\"11111111-1111-1111-1111-111111111111\""
        return try decode("{\"id\":\"\(actorID)\",\"email\":\"a@example.test\",\"display_name\":\"A\"\(identity)}", as: yielding)
    }
    func mutation<Response: Decodable & Sendable>(_ name: String, arguments: [String: String], yielding: Response.Type) async throws -> Response {
        endpoints.append(name)
        mutations.append(arguments)
        guard arguments["expected_account_id"] == "\"\(actorID)\"" else { throw Failure.invalidContract }
        if name == "cleanup:resumeFriendDeletion" {
            guard arguments["financial_contract_version"] == "2" else { throw Failure.invalidContract }
            if arguments["operationId"] == "\"cancelled-job\"" {
                return try decode(#"{"operationId":"cancelled-job","phase":"cancelled","complete":false}"#, as: yielding)
            }
            guard arguments["operationId"] == "\"lost-receipt-job-\(remainingJobs)\"" else { throw Failure.invalidContract }
            let completedID = "lost-receipt-job-\(remainingJobs)"
            remainingJobs -= 1
            pending = remainingJobs > 0
            return try decode("{\"operationId\":\"\(completedID)\",\"phase\":\"complete\",\"complete\":true}", as: yielding)
        }
        if name == "friends:clearAllForUserV2" {
            cleanupCalls += 1
            guard arguments["financial_contract_version"] == "2", arguments["cutoff"] != "null" else { throw Failure.invalidContract }
            return try decode("{\"inProgress\":\(cleanupCalls == 1),\"processed\":1,\"cutoff\":42}", as: yielding)
        }
        guard name == "users:updateProfile" || name == "users:updateSettings" else { throw Failure.invalidContract }
        guard arguments["profile_avatar_color"] != "null", arguments["profile_image_url"] != "null" else { throw Failure.invalidContract }
        return try decode("null", as: yielding)
    }
}

private actor FriendUpsertContractTransport: ConvexServiceTransport {
    enum ContractError: Error { case unexpectedEndpoint, optionalStringReceivedNull }
    private var payloads: [[String: String]] = []
    func recordedArguments() -> [[String: String]] { payloads }
    func query<Response: Decodable & Sendable>(_ name: String, arguments: [String: String], yielding: Response.Type) async throws -> Response {
        guard name == "users:viewer" else { throw ContractError.unexpectedEndpoint }
        return try JSONDecoder().decode(Response.self, from: Data(#"{"id":"A","email":"a@example.test","display_name":"A"}"#.utf8))
    }
    func mutation<Response: Decodable & Sendable>(_ name: String, arguments: [String: String], yielding: Response.Type) async throws -> Response {
        guard name == "friends:upsert" else { throw ContractError.unexpectedEndpoint }
        payloads.append(arguments)
        for key in ["nickname", "original_name", "original_nickname", "first_name", "last_name", "linked_account_id", "linked_account_email", "status"] {
            if let encoded = arguments[key] {
                guard encoded != "null", (try? JSONDecoder().decode(String.self, from: Data(encoded.utf8))) != nil else {
                    throw ContractError.optionalStringReceivedNull
                }
            }
        }
        return try JSONDecoder().decode(Response.self, from: Data(#""friend-document""#.utf8))
    }
}

/// Mirrors the exported backend validator and target/source direction at the wire boundary.
private actor FriendMergeContractTransport: ConvexServiceTransport {
    enum ContractError: Error { case unexpectedEndpoint, invalidArgumentNames, invalidDirection, invalidActorOrCapability }
    private let source: UUID
    private let target: UUID
    private var arguments: [String: String]?

    init(source: UUID, target: UUID) { self.source = source; self.target = target }
    func recordedArguments() -> [String: String]? { arguments }

    func query<Response: Decodable & Sendable>(_ name: String, arguments: [String: String], yielding: Response.Type) async throws -> Response {
        throw ContractError.unexpectedEndpoint
    }

    func mutation<Response: Decodable & Sendable>(_ name: String, arguments: [String: String], yielding: Response.Type) async throws -> Response {
        self.arguments = arguments
        guard name == "aliases:mergeUnlinkedFriendsV3" else { throw ContractError.unexpectedEndpoint }
        guard Set(arguments.keys) == ["friendId1", "friendId2", "financial_contract_version", "expected_account_id"] else {
            throw ContractError.invalidArgumentNames
        }
        func string(_ key: String) throws -> String {
            try JSONDecoder().decode(String.self, from: Data(arguments[key]!.utf8))
        }
        guard try string("friendId1") == target.uuidString, try string("friendId2") == source.uuidString else {
            throw ContractError.invalidDirection
        }
        guard try string("expected_account_id") == "A", arguments["financial_contract_version"] == "2" else {
            throw ContractError.invalidActorOrCapability
        }
        return try JSONDecoder().decode(Response.self, from: Data(#"{"contract_version":3,"operation_id":"merge-operation","status":"pending"}"#.utf8))
    }
}

private actor AuthSwitchTransport: ConvexServiceTransport {
    enum Pause: Equatable { case none, mutation(Int), query(Int) }
    struct Call: Sendable { let name: String; let arguments: [String: String] }
    struct Snapshot: Sendable { let calls: [Call]; let queries: [Call]; let committedActors: [String] }
    enum Failure: Error { case expectedActorMismatch, unsupportedQuery }

    private var actorID = "A"
    private let pause: Pause
    private let failFirstMutation: Bool
    private let onPause: @Sendable () -> Void
    private var continuation: CheckedContinuation<Void, Never>?
    private var calls: [Call] = []
    private var queries: [Call] = []
    private var committedActors: [String] = []
    private var queryCount = 0

    init(pause: Pause, failFirstMutation: Bool = false, onPause: @escaping @Sendable () -> Void) {
        self.pause = pause
        self.failFirstMutation = failFirstMutation
        self.onPause = onPause
    }

    func snapshot() -> Snapshot { Snapshot(calls: calls, queries: queries, committedActors: committedActors) }
    func switchActorWithoutResuming(_ actorID: String) { self.actorID = actorID }
    func resume(as actorID: String) {
        self.actorID = actorID
        continuation?.resume()
        continuation = nil
    }
    func pauseRetry() async { await suspend() }
    private func suspend() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            onPause()
        }
    }

    func mutation<Response: Decodable & Sendable>(
        _ name: String, arguments: [String: String], yielding: Response.Type
    ) async throws -> Response {
        calls.append(Call(name: name, arguments: arguments))
        if failFirstMutation && calls.count == 1 { throw URLError(.networkConnectionLost) }
        let email = actorID.lowercased() + "@example.test"
        guard arguments["expected_account_email"] != nil || arguments["expected_account_id"] != nil,
              arguments["expected_account_email"] == nil || arguments["expected_account_email"] == "\"\(email)\"",
              arguments["expected_account_id"] == nil || arguments["expected_account_id"] == "\"\(actorID)\""
        else { throw Failure.expectedActorMismatch }
        committedActors.append(actorID)
        if pause == .mutation(calls.count) { await suspend() }
        let json: String
        if name == "bulkImport:bulkImport" {
            let expenses = try JSONSerialization.jsonObject(with: Data((arguments["expenses"] ?? "[]").utf8)) as? [Any]
            json = "{\"success\":true,\"created\":{\"friends\":0,\"groups\":0,\"expenses\":\(expenses?.count ?? 0)},\"errors\":[]}"
        } else if name == "groups:clearAllForUserV2" {
            json = "{\"inProgress\":true,\"processed\":1,\"cutoff\":42}"
        } else if name == "friends:clearAllForUserV2" {
            json = "{\"inProgress\":false,\"processed\":1,\"cutoff\":42}"
        } else { json = "null" }
        return try JSONDecoder().decode(Response.self, from: Data(json.utf8))
    }

    func query<Response: Decodable & Sendable>(
        _ name: String, arguments: [String: String], yielding: Response.Type
    ) async throws -> Response {
        queryCount += 1
        queries.append(Call(name: name, arguments: arguments))
        if pause == .query(queryCount) { await suspend() }
        if name == "groups:listPaginated" {
            return try JSONDecoder().decode(Response.self, from: Data("{\"items\":[],\"nextCursor\":null}".utf8))
        }
        guard name == "users:viewer" || name == "users:authenticationStatus" else { throw Failure.unsupportedQuery }
        let json = "{\"id\":\"\(actorID)\",\"email\":\"\(actorID.lowercased())@example.test\",\"display_name\":\"\(actorID)\"}"
        return try JSONDecoder().decode(Response.self, from: Data(json.utf8))
    }
}
#endif
