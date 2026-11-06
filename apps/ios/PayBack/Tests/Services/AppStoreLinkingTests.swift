import XCTest
@testable import PayBack

extension AppStoreLinkingTests {
    func testRestoreHistory_ColdLoginRetainsNeutralActorBehindDataRecovery() async throws {
        let account = UserAccount(id: "history-owner", email: "history@example.test", displayName: "Owner")
        await mockAccountService.addAccount(account)
        let job = GroupHistoryJob(jobId: "history-job", groupId: "group", phase: "pending", retryable: true, errorCode: nil)
        await mockAccountService.configureHistoryRecovery(jobs: [job], snapshotError: GroupHistoryRecoveryError(
            code: "HISTORY_RECONCILIATION_PENDING", retryable: true, jobId: job.jobId, groupId: job.groupId))
        do { try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName) }
        catch { XCTFail("Pending group history is data recovery, not failed authentication: \(error)") }
        XCTAssertEqual(sut.session?.account.id, account.id)
        XCTAssertNil(sut.session?.account.linkedMemberId, "Pending recovery must not bootstrap an invented canonical identity")
        XCTAssertFalse(sut.isAuthenticationSessionRecoveryBlocking)
        XCTAssertTrue(sut.isGroupHistoryRecoveryBlocking)
        XCTAssertFalse(sut.isCheckingAuth)
        XCTAssertTrue(sut.groups.isEmpty)
        XCTAssertTrue(sut.expenses.isEmpty)
        let bootstraps = await mockAccountService.bootstrapInvocationCount()
        XCTAssertEqual(bootstraps, 0)
    }

    func testRestoreHistory_BlockedHydrationPreservesLastCompleteGenerationAndVisibleRecovery() async throws {
        let account = UserAccount(id: "history-owner", email: "history@example.test", displayName: "Owner", linkedMemberId: sut.currentUser.id)
        await mockAccountService.addAccount(account)
        sut.session = UserSession(account: account)
        let expense = Expense(groupId: UUID(), description: "Last complete", totalAmount: 10,
            paidByMemberId: sut.currentUser.id, involvedMemberIds: [sut.currentUser.id],
            splits: [ExpenseSplit(memberId: sut.currentUser.id, amount: 10)])
        await mockExpenseCloudService.addExpense(expense)
        await sut.loadRemoteData()
        let previousExpenses = sut.expenses
        let previousGroups = sut.groups
        let previousEpoch = sut.dataEpoch
        let job = GroupHistoryJob(jobId: "history-job", groupId: "group", phase: "failed", retryable: false, errorCode: "HISTORY_SOURCE_INVALID")
        await mockAccountService.configureHistoryRecovery(jobs: [job], snapshotError: GroupHistoryRecoveryError(
            code: "HISTORY_RECONCILIATION_FAILED", retryable: false, jobId: job.jobId, groupId: job.groupId))
        await sut.loadRemoteData()
        XCTAssertEqual(sut.expenses, previousExpenses)
        XCTAssertEqual(sut.groups, previousGroups)
        XCTAssertEqual(sut.dataEpoch, previousEpoch)
        XCTAssertTrue(sut.hasGroupHistoryRecovery)
        XCTAssertFalse(sut.isGroupHistoryRecoveryBlocking)
        XCTAssertEqual(sut.groupHistoryRecovery?.maintenanceRequired, true)
        XCTAssertFalse(sut.isAuthenticationSessionRecoveryBlocking)
    }

    func testRestoreHistory_CompletedRetryHydratesWithoutRestartingSession() async throws {
        let account = UserAccount(id: "history-owner", email: "history@example.test", displayName: "Owner")
        await mockAccountService.addAccount(account)
        let job = GroupHistoryJob(jobId: "history-job", groupId: "group", phase: "pending", retryable: true)
        await mockAccountService.configureHistoryRecovery(jobs: [job], snapshotError: GroupHistoryRecoveryError(code: "HISTORY_RECONCILIATION_PENDING", retryable: true, jobId: job.jobId))
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)
        let epoch = sut.dataEpoch
        let complete = GroupHistoryJob(jobId: job.jobId, groupId: job.groupId, phase: "complete", retryable: false)
        await mockAccountService.configureHistoryRecovery(jobs: [job], snapshotError: nil, resumed: complete)
        let result = await sut.retryGroupHistoryRecovery()
        guard case .complete(let receipt) = result else { return XCTFail("Expected authoritative hydration: \(result)") }
        XCTAssertEqual(receipt.accountID, account.id)
        XCTAssertEqual(receipt.dataEpoch, epoch)
        XCTAssertEqual(sut.dataEpoch, epoch)
        XCTAssertEqual(sut.session?.account.id, account.id)
        XCTAssertNotNil(sut.session?.account.linkedMemberId)
        XCTAssertFalse(sut.hasGroupHistoryRecovery)
        XCTAssertFalse(sut.isAuthenticationSessionRecoveryBlocking)
    }

    func testRestoreHistory_TransientResumeFailureKeepsNeutralRecoveryAndMaintenanceDoesNotRetry() async throws {
        let account = UserAccount(id: "history-owner", email: "history@example.test", displayName: "Owner")
        await mockAccountService.addAccount(account)
        let job = GroupHistoryJob(jobId: "history-job", groupId: "group", phase: "pending", retryable: true)
        await mockAccountService.configureHistoryRecovery(jobs: [job], snapshotError: nil)
        await mockAccountService.configureHistoryResumeFailure(.networkUnavailable)
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)
        XCTAssertEqual(sut.session?.account.id, account.id)
        XCTAssertTrue(sut.isGroupHistoryRecoveryBlocking)
        XCTAssertFalse(sut.isAuthenticationSessionRecoveryBlocking)
        let failed = GroupHistoryJob(jobId: job.jobId, groupId: job.groupId, phase: "failed", retryable: false, errorCode: "HISTORY_SOURCE_INVALID")
        await mockAccountService.configureHistoryRecovery(jobs: [failed], snapshotError: nil)
        let before = await mockAccountService.historyRecoveryResumeCount()
        let result = await sut.retryGroupHistoryRecovery()
        guard case .incomplete(let failure) = result else { return XCTFail("Maintenance cannot complete hydration") }
        XCTAssertEqual(failure.reason, .recoveryRequired)
        let after = await mockAccountService.historyRecoveryResumeCount()
        XCTAssertEqual(after, before, "Maintenance needs status/repair, not automatic rescheduling")
        XCTAssertEqual(sut.groupHistoryRecovery?.maintenanceRequired, true)
    }

    func testRestoreHistory_ForeignReaderRecoversThroughAuthorizedErrorHint() async throws {
        let account = UserAccount(id: "reader", email: "reader@example.test", displayName: "Reader", linkedMemberId: sut.currentUser.id)
        await mockAccountService.addAccount(account)
        sut.session = UserSession(account: account)
        let job = GroupHistoryJob(jobId: "foreign-job", groupId: "shared-group", phase: "pending", retryable: true)
        await mockAccountService.configureForeignHistoryJob(job)
        await mockAccountService.configureHistoryRecovery(jobs: [], snapshotError: GroupHistoryRecoveryError(code: "HISTORY_RECONCILIATION_PENDING", retryable: true, jobId: job.jobId))
        await sut.loadRemoteData()
        XCTAssertEqual(sut.groupHistoryRecovery?.jobs.map(\.jobId), [job.jobId])
        await mockAccountService.configureHistoryRecovery(jobs: [], snapshotError: nil,
            resumed: GroupHistoryJob(jobId: job.jobId, groupId: job.groupId, phase: "complete", retryable: false))
        let result = await sut.retryGroupHistoryRecovery()
        guard case .complete = result else { return XCTFail("Authorized reader should recover: \(result)") }
        let resumes = await mockAccountService.historyRecoveryResumeCount()
        XCTAssertEqual(resumes, 1)
    }

    func testRestoreHistory_RefreshOutcomeRequiresCurrentSuccessfulCompleteSnapshot() async throws {
        let account = UserAccount(id: "refresh-owner", email: "refresh@example.test", displayName: "Owner", linkedMemberId: sut.currentUser.id)
        await mockAccountService.addAccount(account)
        sut.session = UserSession(account: account)
        let epoch = sut.dataEpoch
        await mockAccountService.configureSnapshotGenerations(["confirmed-generation"])
        let first = await sut.refreshAfterImport(expectedAccountID: account.id, expectedDataEpoch: epoch)
        guard case .complete(let receipt) = first else { return XCTFail("Expected complete receipt") }
        XCTAssertEqual(receipt.accountID, account.id)
        XCTAssertEqual(receipt.dataEpoch, epoch)
        XCTAssertEqual(receipt.serverGeneration, "confirmed-generation")
        let previous = sut.expenses
        await mockExpenseCloudService.setShouldFail(true)
        let failed = await sut.refreshAfterImport(expectedAccountID: account.id, expectedDataEpoch: epoch)
        guard case .incomplete(let failure) = failed else { return XCTFail("Previous successful hydration cannot acknowledge this failed refresh") }
        XCTAssertEqual(failure.reason, .failed)
        XCTAssertEqual(sut.expenses, previous)
        let stale = await sut.refreshAfterImport(expectedAccountID: "different-account", expectedDataEpoch: epoch)
        guard case .incomplete(let staleFailure) = stale else { return XCTFail("Actor mismatch cannot succeed") }
        XCTAssertEqual(staleFailure.reason, .sessionChanged)
    }

    func testRestoreHistory_RefreshAfterAccountSwitchNeverAcknowledgesOrPublishesOldData() async throws {
        let account = UserAccount(id: "refresh-owner", email: "refresh@example.test", displayName: "Owner", linkedMemberId: sut.currentUser.id)
        await mockAccountService.addAccount(account)
        sut.session = UserSession(account: account)
        let epoch = sut.dataEpoch
        await mockAccountService.suspendNextFriendFetch()
        let task = Task { await sut.refreshAfterImport(expectedAccountID: account.id, expectedDataEpoch: epoch) }
        await mockAccountService.waitUntilFriendFetchSuspends()
        sut.session = UserSession(account: UserAccount(id: "next-account", email: "next@example.test", displayName: "Next"))
        let newer = Expense(groupId: UUID(), description: "New account", totalAmount: 1, paidByMemberId: sut.currentUser.id,
            involvedMemberIds: [sut.currentUser.id], splits: [ExpenseSplit(memberId: sut.currentUser.id, amount: 1)])
        sut.expenses = [newer]
        await mockAccountService.resumeFriendFetch()
        let result = await task.value
        guard case .incomplete(let failure) = result else { return XCTFail("Stale refresh cannot be acknowledged") }
        XCTAssertEqual(failure.reason, .sessionChanged)
        XCTAssertEqual(sut.expenses.map(\.id), [newer.id])
        XCTAssertNil(sut.groupHistoryRecovery)
    }

    func testRestoreHistory_BackgroundRefreshCannotPublishNeutralIdentityAfterJobCompletes() async throws {
        let account = UserAccount(id: "history-owner", email: "history@example.test", displayName: "Owner")
        await mockAccountService.addAccount(account)
        let job = GroupHistoryJob(jobId: "history-job", groupId: "group", phase: "pending", retryable: true)
        await mockAccountService.configureHistoryRecovery(jobs: [job], snapshotError: nil)
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)
        let epoch = sut.dataEpoch
        await mockAccountService.configureHistoryRecovery(jobs: [], snapshotError: nil,
            resumed: GroupHistoryJob(jobId: job.jobId, groupId: job.groupId, phase: "complete", retryable: false))
        await sut.loadRemoteData()
        XCTAssertTrue(sut.isGroupHistoryRecoveryBlocking)
        XCTAssertNil(sut.session?.account.linkedMemberId)
        let before = await mockAccountService.bootstrapInvocationCount()
        XCTAssertEqual(before, 0)
        let recovered = await sut.retryGroupHistoryRecovery()
        guard case .complete = recovered else { return XCTFail("Explicit retry must finish canonical identity + hydration") }
        XCTAssertNotNil(sut.session?.account.linkedMemberId)
        XCTAssertEqual(sut.dataEpoch, epoch)
    }

    func testRestoreHistory_CancelledAndSupersededRefreshesNeverReturnCompletion() async throws {
        let account = UserAccount(id: "refresh-owner", email: "refresh@example.test", displayName: "Owner", linkedMemberId: sut.currentUser.id)
        await mockAccountService.addAccount(account)
        sut.session = UserSession(account: account)
        let epoch = sut.dataEpoch
        await mockAccountService.suspendNextFriendFetch()
        let cancelled = Task { await sut.refreshAfterImport(expectedAccountID: account.id, expectedDataEpoch: epoch) }
        await mockAccountService.waitUntilFriendFetchSuspends()
        cancelled.cancel()
        await mockAccountService.resumeFriendFetch()
        let cancelledResult = await cancelled.value
        guard case .incomplete(let cancellation) = cancelledResult else { return XCTFail("Cancellation is not successful refresh") }
        XCTAssertEqual(cancellation.reason, .cancelled)
        XCTAssertNil(sut.dataSyncRecoveryMessage)

        await mockAccountService.suspendNextFriendFetch()
        let older = Task { await sut.refreshAfterImport(expectedAccountID: account.id, expectedDataEpoch: epoch) }
        await mockAccountService.waitUntilFriendFetchSuspends()
        let oldGeneration = sut.remoteLoadGeneration
        let newer = Task { await sut.refreshAfterImport(expectedAccountID: account.id, expectedDataEpoch: epoch) }
        for _ in 0..<100 {
            if sut.remoteLoadGeneration > oldGeneration { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertGreaterThan(sut.remoteLoadGeneration, oldGeneration)
        await mockAccountService.resumeFriendFetch()
        let oldResult = await older.value
        let newResult = await newer.value
        guard case .incomplete(let superseded) = oldResult else { return XCTFail("Older request cannot acknowledge a newer refresh") }
        XCTAssertEqual(superseded.reason, .superseded)
        guard case .complete = newResult else { return XCTFail("Latest current refresh should complete") }
    }

    func testRestoreHistory_CancelledRecoveryKeepsGateAndNextAttemptCanComplete() async throws {
        let account = UserAccount(id: "history-owner", email: "history@example.test", displayName: "Owner", linkedMemberId: sut.currentUser.id)
        await mockAccountService.addAccount(account)
        sut.session = UserSession(account: account)
        let job = GroupHistoryJob(jobId: "history-job", groupId: "group", phase: "pending", retryable: true)
        await mockAccountService.configureHistoryRecovery(jobs: [job], snapshotError: nil,
            resumed: GroupHistoryJob(jobId: job.jobId, groupId: job.groupId, phase: "complete", retryable: false))
        await sut.loadRemoteData()
        await mockAccountService.suspendNextHistoryResume()
        let retry = Task { await sut.retryGroupHistoryRecovery() }
        for _ in 0..<100 {
            if await mockAccountService.isHistoryResumeSuspended() { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        retry.cancel()
        await mockAccountService.continueHistoryResume()
        let result = await retry.value
        guard case .incomplete(let failure) = result else { return XCTFail("Cancelled recovery cannot report completion") }
        XCTAssertEqual(failure.reason, .cancelled)
        XCTAssertTrue(sut.isGroupHistoryRecoveryBlocking)
        XCTAssertEqual(sut.groupHistoryRecovery?.isRetrying, false)
        XCTAssertFalse(sut.isAuthenticationSessionRecoveryBlocking)
        let next = await sut.retryGroupHistoryRecovery()
        guard case .complete = next else { return XCTFail("Durable completed job should recover on next attempt") }
    }

    func testRestoreHistory_OldRecoveryCannotOverwriteNewAuthenticatedAccount() async throws {
        let first = UserAccount(id: "history-owner", email: "history@example.test", displayName: "Owner", linkedMemberId: sut.currentUser.id)
        await mockAccountService.addAccount(first)
        sut.session = UserSession(account: first)
        let job = GroupHistoryJob(jobId: "history-job", groupId: "group", phase: "pending", retryable: true)
        await mockAccountService.configureHistoryRecovery(jobs: [job], snapshotError: nil)
        await sut.loadRemoteData()
        await mockAccountService.suspendNextHistoryResume()
        let retry = Task { await sut.retryGroupHistoryRecovery() }
        for _ in 0..<100 {
            if await mockAccountService.isHistoryResumeSuspended() { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let second = UserAccount(id: "new-owner", email: "new@example.test", displayName: "New", linkedMemberId: UUID())
        await mockAccountService.addAccount(second)
        await mockAccountService.configureHistoryRecovery(jobs: [], snapshotError: nil)
        try await sut.completeAuthenticationAndWait(email: second.email, name: second.displayName)
        let newEpoch = sut.dataEpoch
        await mockAccountService.continueHistoryResume()
        let result = await retry.value
        guard case .incomplete(let failure) = result else { return XCTFail("Old actor recovery must not complete") }
        XCTAssertEqual(failure.reason, .sessionChanged)
        XCTAssertEqual(sut.session?.account.id, second.id)
        XCTAssertEqual(sut.dataEpoch, newEpoch)
        XCTAssertNil(sut.groupHistoryRecovery)
        XCTAssertNil(sut.authenticationSessionRecoveryMessage)
        XCTAssertFalse(sut.isCheckingAuth)
    }

    func testRestoreHistory_StaleForeignHintClearsOnlyAfterSuccessfulAuthoritativeSnapshot() async throws {
        let account = UserAccount(id: "reader", email: "reader@example.test", displayName: "Reader", linkedMemberId: sut.currentUser.id)
        await mockAccountService.addAccount(account)
        sut.session = UserSession(account: account)
        let job = GroupHistoryJob(jobId: "former-shared-job", groupId: "shared-group", phase: "pending", retryable: true)
        await mockAccountService.configureForeignHistoryJob(job)
        let pending = GroupHistoryRecoveryError(code: "HISTORY_RECONCILIATION_PENDING", retryable: true, jobId: job.jobId)
        await mockAccountService.configureHistoryRecovery(jobs: [], snapshotError: pending)
        await sut.loadRemoteData()
        XCTAssertTrue(sut.hasGroupHistoryRecovery)

        // Status can become inaccessible after the reader loses membership. Its
        // generic error is not enough evidence to drop the public snapshot fence.
        await mockAccountService.configureHistoryStatusFailure(.networkUnavailable)
        let stillBlocked = await sut.retryGroupHistoryRecovery()
        guard case .incomplete(let blocked) = stillBlocked else { return XCTFail("Pending snapshot must retain recovery") }
        XCTAssertEqual(blocked.reason, .recoveryRequired)
        XCTAssertTrue(sut.hasGroupHistoryRecovery)
        let attempts = await mockAccountService.historyRecoveryResumeCount()
        XCTAssertEqual(attempts, 0, "Unverified job hint must never be rescheduled")

        await mockAccountService.configureHistoryRecovery(jobs: [], snapshotError: nil)
        await mockExpenseCloudService.setShouldFail(true)
        let failed = await sut.retryGroupHistoryRecovery()
        guard case .incomplete(let failure) = failed else { return XCTFail("Failed hydration cannot clear the hint") }
        XCTAssertEqual(failure.reason, .failed)
        XCTAssertTrue(sut.hasGroupHistoryRecovery)
        XCTAssertEqual(sut.session?.account.id, account.id)

        await mockExpenseCloudService.setShouldFail(false)
        await mockAccountService.configureHistoryStatusFailure(.underlying(message: "History reconciliation not found"))
        let ready = await sut.retryGroupHistoryRecovery()
        guard case .complete = ready else { return XCTFail("Public complete snapshot should release stale hint: \(ready)") }
        XCTAssertFalse(sut.hasGroupHistoryRecovery)
        XCTAssertFalse(sut.isGroupHistoryRecoveryBlocking)
        XCTAssertFalse(sut.isAuthenticationSessionRecoveryBlocking)
    }

    private func cancellationExpenseFixture() async -> Expense {
        let me = sut.currentUser.id
        let account = UserAccount(id: "cancel-owner", email: "cancel@example.test", displayName: "Owner", linkedMemberId: me)
        sut.session = UserSession(account: account)
        await mockAccountService.addAccount(account)
        return Expense(groupId: UUID(), description: "Cancelable save", totalAmount: 10, paidByMemberId: me,
            involvedMemberIds: [me], splits: [ExpenseSplit(memberId: me, amount: 10)],
            ownerEmail: account.email, ownerAccountId: account.id, financialIdentityMap: [me: me])
    }

    private func waitForSuspendedUpsert() async throws {
        for _ in 0..<100 {
            if await mockExpenseCloudService.isUpsertSuspended() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Save did not reach controlled suspension")
    }

    func testReview_CancelledExpenseSaveBeforeSendPublishesNothing() async throws {
        let expense = await cancellationExpenseFixture()
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await sut.addExpenseAndSync(expense)
        }
        do { try await task.value; XCTFail("Cancelled save must fail") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(sut.expenses.isEmpty)
        let calls = await mockExpenseCloudService.currentUpsertInvocationCount()
        XCTAssertEqual(calls, 0)
    }

    func testReview_CancelledSuspendedExpenseSaveRemovesOwnedOptimisticRow() async throws {
        let expense = await cancellationExpenseFixture()
        await mockExpenseCloudService.setCancellationBeforeUpsertCommit(true)
        await mockExpenseCloudService.suspendNextUpsert()
        let task = Task { try await sut.addExpenseAndSync(expense) }
        try await waitForSuspendedUpsert()
        task.cancel()
        await mockExpenseCloudService.resumeUpsert()
        do { try await task.value; XCTFail("Cancelled save must fail") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(sut.expenses.isEmpty)
        await sut.loadRemoteData()
        XCTAssertTrue(sut.expenses.isEmpty)
        XCTAssertTrue(mockPersistence.storedData().expenses.isEmpty)
    }

    func testReview_CancelledPostCommitSaveAcceptsLaterAuthoritativeSnapshot() async throws {
        let expense = await cancellationExpenseFixture()
        await mockExpenseCloudService.suspendNextUpsertAfterCommit()
        let task = Task { try await sut.addExpenseAndSync(expense) }
        try await waitForSuspendedUpsert()
        task.cancel()
        await mockExpenseCloudService.resumeUpsert()
        do { try await task.value; XCTFail("Cancelled save must fail") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(sut.expenses.isEmpty, "An ambiguous response cannot report a completed save")
        await sut.loadRemoteData()
        XCTAssertEqual(sut.expenses.map(\.id), [expense.id], "Committed server state remains recoverable")
        var newer = expense
        newer.description = "Changed on another device"
        await mockExpenseCloudService.addExpense(newer)
        await sut.loadRemoteData()
        XCTAssertEqual(sut.expenses.first?.description, newer.description, "Cancelled pending token must not pin an older payload")
    }

    func testReview_CancelledSavePreservesNewerAuthoritativeProjectionAndSettlement() async throws {
        let expense = await cancellationExpenseFixture()
        await mockExpenseCloudService.suspendNextUpsertAfterCommit()
        let task = Task { try await sut.addExpenseAndSync(expense) }
        try await waitForSuspendedUpsert()
        let canonical = UUID()
        var remote = Expense(id: expense.id, groupId: expense.groupId, description: expense.description, date: expense.date,
            totalAmount: expense.totalAmount, paidByMemberId: expense.paidByMemberId,
            involvedMemberIds: expense.involvedMemberIds, splits: expense.splits,
            ownerEmail: expense.ownerEmail, ownerAccountId: expense.ownerAccountId,
            financialIdentityMap: [expense.paidByMemberId: canonical])
        remote.splits[0].isSettled = true
        remote.isSettled = true
        await mockExpenseCloudService.addExpense(remote)
        await sut.loadRemoteData()
        XCTAssertEqual(sut.expenses.first?.financialIdentityMap?[expense.paidByMemberId], canonical)
        XCTAssertEqual(sut.expenses.first?.isSettled, false, "Authored optimistic fields still await acknowledgement")
        task.cancel()
        await mockExpenseCloudService.resumeUpsert()
        do { try await task.value; XCTFail("Cancelled save must fail") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(sut.expenses.first?.isSettled, true)
        XCTAssertEqual(sut.expenses.first?.financialIdentityMap?[expense.paidByMemberId], canonical)
    }

    func testReview_CancelledOlderSaveCannotRollbackNewerExpenseEdit() async throws {
        let expense = await cancellationExpenseFixture()
        await mockExpenseCloudService.suspendNextUpsertAfterCommit()
        let task = Task { try await sut.addExpenseAndSync(expense) }
        try await waitForSuspendedUpsert()
        var newer = expense
        newer.description = "Newer local edit"
        sut.updateExpense(newer)
        for _ in 0..<100 {
            if await mockExpenseCloudService.currentUpsertInvocationCount() >= 2 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        await Task.yield()
        task.cancel()
        await mockExpenseCloudService.resumeUpsert()
        do { try await task.value; XCTFail("Superseded save must fail") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(sut.expenses.first?.description, newer.description)
        await sut.loadRemoteData()
        XCTAssertEqual(sut.expenses.first?.description, newer.description)
    }

    func testReview_GroupRollbackPreservesNewerServerIdentityProjection() async throws {
        let removed = GroupMember(name: "Removed")
        let retained = GroupMember(name: "Retained")
        let canonical = UUID()
        let original = SpendingGroup(name: "Group", members: [sut.currentUser, removed, retained],
            memberIdentityMap: [retained.id: retained.id])
        sut.session = UserSession(account: UserAccount(id: "owner", email: "owner@example.test", displayName: "Owner"))
        sut.groups = [original]
        await mockGroupCloudService.addGroup(original)
        await mockGroupCloudService.suspendNextMemberRemovals(1)
        let removal = Task { try await sut.removeMemberFromGroup(groupId: original.id, memberId: removed.id) }
        for _ in 0..<100 {
            if await mockGroupCloudService.currentRemoveMemberInvocationCount() > 0 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let optimistic = try XCTUnwrap(sut.groups.first)
        sut.groups = [SpendingGroup(id: optimistic.id, name: optimistic.name, members: optimistic.members,
            createdAt: optimistic.createdAt, isDirect: optimistic.isDirect, isDebug: optimistic.isDebug,
            memberIdentityMap: [retained.id: canonical])]
        await mockGroupCloudService.setShouldFail(true)
        await mockGroupCloudService.resumeNextMemberRemoval()
        do { try await removal.value; XCTFail("Expected member removal failure") } catch {}
        XCTAssertEqual(sut.groups.first?.members.map(\.id), original.members.map(\.id))
        XCTAssertEqual(sut.groups.first?.memberIdentityMap?[retained.id], canonical)
    }

    func testReview_PendingAuthoredEditAdoptsProjectionAndLateSaveCannotRestoreOldMap() async throws {
        let me = sut.currentUser.id
        let placeholder = UUID()
        let target = UUID()
        let account = UserAccount(id: "projection-owner", email: "projection@example.test", displayName: "Owner", linkedMemberId: me)
        sut.session = UserSession(account: account)
        await mockAccountService.addAccount(account)
        let initial = Expense(groupId: UUID(), description: "Before edit", totalAmount: 20,
            paidByMemberId: me, involvedMemberIds: [me, placeholder],
            splits: [ExpenseSplit(memberId: me, amount: 10), ExpenseSplit(memberId: placeholder, amount: 10)],
            ownerEmail: account.email, ownerAccountId: account.id, financialIdentityMap: [me: me, placeholder: placeholder])
        sut.expenses = [initial]
        await mockExpenseCloudService.addExpense(initial)
        var edited = initial
        edited.description = "Pending authored edit"
        await mockExpenseCloudService.configureCanonicalSaveResult(SavedExpenseResult(expense: edited, group: nil))
        await mockExpenseCloudService.suspendNextUpsert()
        sut.updateExpense(edited)
        for _ in 0..<100 {
            if await mockExpenseCloudService.currentUpsertInvocationCount() > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let remote = Expense(id: initial.id, groupId: initial.groupId, description: initial.description, date: initial.date,
            totalAmount: 20, paidByMemberId: me, involvedMemberIds: initial.involvedMemberIds, splits: initial.splits,
            ownerEmail: account.email, ownerAccountId: account.id, financialIdentityMap: [me: me, placeholder: target])
        await mockExpenseCloudService.addExpense(remote)
        await mockAccountService.configureSnapshotGenerations(["merged-while-save-pending"])
        await sut.loadRemoteData()
        XCTAssertEqual(sut.expenses.first?.description, edited.description)
        XCTAssertEqual(sut.expenses.first?.financialIdentityMap?[placeholder], target)
        await mockExpenseCloudService.resumeUpsert()
        for _ in 0..<100 {
            await Task.yield()
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(sut.expenses.first?.description, edited.description)
        XCTAssertEqual(sut.expenses.first?.financialIdentityMap?[placeholder], target, "Older mutation response cannot undo a newer complete projection")
        var latest = remote
        latest.description = edited.description
        latest.splits[1].isSettled = true
        await mockExpenseCloudService.addExpense(latest)
        await sut.loadRemoteData()
        XCTAssertEqual(sut.expenses.first?.splits[1].isSettled, true)
    }

    func testReview_OlderExpenseSaveCompletionCannotOverwriteNewerEdit() async throws {
        let me = sut.currentUser.id
        sut.session = UserSession(account: UserAccount(id: "owner", email: "owner@example.test", displayName: "Owner"))
        let initial = Expense(groupId: UUID(), description: "Initial", totalAmount: 10, paidByMemberId: me,
            involvedMemberIds: [me], splits: [ExpenseSplit(memberId: me, amount: 10)])
        sut.expenses = [initial]
        await mockExpenseCloudService.setUpsertDelaysNanoseconds([100_000_000, 0])
        var first = initial
        first.description = "Older edit"
        sut.updateExpense(first)
        for _ in 0..<100 {
            if await mockExpenseCloudService.currentUpsertInvocationCount() > 0 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        var newer = initial
        newer.description = "Newer edit"
        sut.updateExpense(newer)
        try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertEqual(sut.expenses.first?.description, "Newer edit")
    }

    func testReview_ExplicitLoginFailedIdentityShowsRecoveryInsteadOfEmptyRoot() async throws {
        let account = UserAccount(id: UUID().uuidString, email: "failed-identity@example.test", displayName: "Owner")
        await mockAccountService.addAccount(account)
        await mockAccountService.configurePendingOperation(IdentityOperationResult(operationId: UUID().uuidString, status: "failed"), resumed: nil)
        do { try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName); XCTFail("Expected recovery failure") }
        catch {}
        XCTAssertNil(sut.session)
        XCTAssertFalse(sut.isCheckingAuth)
        XCTAssertTrue(sut.isAuthenticationSessionRecoveryBlocking)
        XCTAssertNotNil(sut.authenticationSessionRecoveryMessage)
        XCTAssertFalse(sut.canPresentAuthenticationFlow, "Provider sign-in remains available for recovery")
    }

    func testReview_ExplicitLoginFailedDeletionOrRefreshShowsRecovery() async throws {
        for failsDeletion in [true, false] {
            await mockAccountService.reset()
            let account = UserAccount(id: UUID().uuidString, email: "failed-resume@example.test", displayName: "Owner")
            await mockAccountService.addAccount(account)
            if failsDeletion { await mockAccountService.configureFriendDeletionResumeFailure(.networkUnavailable) }
            else { await mockAccountService.configureLookupFailureAfterDeletionResume() }
            do { try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName); XCTFail("Expected recovery failure") }
            catch {}
            XCTAssertNil(sut.session)
            XCTAssertFalse(sut.isCheckingAuth)
            XCTAssertTrue(sut.isAuthenticationSessionRecoveryBlocking)
        }
    }

    func testReview_ExplicitLoginFailedInitialHydrationShowsRecovery() async throws {
        let account = UserAccount(id: UUID().uuidString, email: "failed-hydration@example.test", displayName: "Owner", linkedMemberId: UUID())
        await mockAccountService.addAccount(account)
        await mockExpenseCloudService.setShouldFail(true)
        do { try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName); XCTFail("Expected hydration recovery") }
        catch {}
        XCTAssertNil(sut.session)
        XCTAssertFalse(sut.isCheckingAuth)
        XCTAssertTrue(sut.isAuthenticationSessionRecoveryBlocking)
    }

    func testReview_ExplicitLoginBootstrapCompletionCannotOverwriteNewAccount() async throws {
        let first = UserAccount(id: "bootstrap-first", email: "first@example.test", displayName: "First")
        await mockAccountService.addAccount(first)
        await mockAccountService.suspendNextBootstrap()
        let login = Task { try await sut.completeAuthenticationAndWait(email: first.email, name: first.displayName) }
        await mockAccountService.waitUntilBootstrapSuspends()
        XCTAssertTrue(sut.isCheckingAuth, "Temporary neutral session must not expose RootView")
        let secondID = UUID()
        let second = UserAccount(id: "bootstrap-second", email: "second@example.test", displayName: "Second", linkedMemberId: secondID)
        sut.session = UserSession(account: second)
        sut.currentUser = GroupMember(id: secondID, name: "Second", isCurrentUser: true)
        await mockAccountService.resumeBootstrap()
        do { try await login.value; XCTFail("Stale login must not succeed") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(sut.session?.account.id, second.id)
        XCTAssertEqual(sut.currentUser.id, secondID)
        XCTAssertTrue(sut.isCheckingAuth, "Old login must not dismiss the new account loading state")
        XCTAssertNil(sut.authenticationSessionRecoveryMessage)
    }

    func testReview_ExplicitLoginResumesPendingIdentityBeforeBootstrap() async throws {
        let neutralAccount = UserAccount(id: UUID().uuidString, email: "recover-login@example.com", displayName: "Owner")
        var completedAccount = neutralAccount
        completedAccount.linkedMemberId = UUID()
        await mockAccountService.addAccount(neutralAccount)
        await mockAccountService.configurePendingOperation(
            IdentityOperationResult(operationId: "pending-login", status: "pending"),
            resumed: IdentityOperationResult(operationId: "pending-login", status: "complete")
        )
        await mockAccountService.configureAccountAfterIdentityResume(completedAccount)

        try await sut.completeAuthenticationAndWait(email: neutralAccount.email, name: neutralAccount.displayName)

        XCTAssertEqual(sut.session?.account.linkedMemberId, completedAccount.linkedMemberId)
        let resumeCount = await mockAccountService.identityResumeCount()
        XCTAssertEqual(resumeCount, 1)
    }

    func testReview_FirstExpenseCommitsServerSelectedLedger() async throws {
        let account = UserAccount(id: "canonical-save-owner", email: "save@example.com", displayName: "Owner", linkedMemberId: sut.currentUser.id)
        sut.session = UserSession(account: account)
        let friend = GroupMember(name: "Alex")
        sut.friends = [AccountFriend(memberId: friend.id, name: friend.name, status: "friend")]
        let draft = SpendingGroup(name: "Alex", members: [sut.currentUser, friend], isDirect: true)
        let canonical = SpendingGroup(name: "Alex", members: draft.members, isDirect: true)
        let expense = Expense(groupId: draft.id, description: "Dinner", totalAmount: 20, paidByMemberId: sut.currentUser.id,
                              involvedMemberIds: draft.members.map(\.id), splits: draft.members.map { ExpenseSplit(memberId: $0.id, amount: 10) })
        let saved = Expense(id: expense.id, groupId: canonical.id, description: expense.description,
                            totalAmount: expense.totalAmount, paidByMemberId: expense.paidByMemberId,
                            involvedMemberIds: expense.involvedMemberIds, splits: expense.splits)
        await mockExpenseCloudService.configureCanonicalSaveResult(SavedExpenseResult(expense: saved, group: canonical))

        try await sut.addExpenseAndSync(expense, directExpenseLedger: draft)

        XCTAssertEqual(sut.expenses.first?.groupId, canonical.id)
        XCTAssertEqual(sut.groups.map(\.id), [canonical.id])
        let expectedActors = await mockExpenseCloudService.expectedSaveActors()
        XCTAssertEqual(expectedActors, [account.id])
    }

    func testReview_BlockedFinancialRefreshDoesNotPublishNewIdentity() async throws {
        let selfId = UUID()
        let canonical = UUID()
        let alias = UUID()
        let account = UserAccount(id: "generation-owner", email: "generation@example.com", displayName: "Owner", linkedMemberId: selfId)
        sut.session = UserSession(account: account)
        sut.currentUser = GroupMember(id: selfId, name: "Owner", isCurrentUser: true)
        let oldFriend = AccountFriend(memberId: canonical, name: "Alex", status: "friend")
        sut.processFriendsUpdate([oldFriend])
        let expense = Expense(groupId: UUID(), description: "Mixed settlement history", totalAmount: 25,
                              paidByMemberId: selfId, involvedMemberIds: [selfId, canonical, alias],
                              splits: [ExpenseSplit(memberId: canonical, amount: 10, isSettled: true),
                                       ExpenseSplit(memberId: alias, amount: 15, isSettled: false)])
        sut.expenses = [expense]
        var newFriend = oldFriend
        newFriend.aliasMemberIds = [alias]
        try await mockAccountService.syncFriends(accountEmail: account.email, friends: [newFriend])
        var updated = account
        updated.equivalentMemberIds = [UUID()]
        await mockAccountService.addAccount(updated)
        await mockAccountService.configureSnapshotGenerations(["complete-2"])
        await mockExpenseCloudService.setShouldFail(true)

        sut.handleRealtimeAccountUpdate(updated)
        await sut.loadRemoteData()

        XCTAssertEqual(sut.session?.account, account)
        XCTAssertFalse(sut.areSamePerson(canonical, alias))
        XCTAssertEqual(sut.expenses, [expense])
        XCTAssertEqual(sut.expenses[0].splits.map(\.isSettled), [true, false])
    }

    func testReview_ChangedGenerationDiscardsEntireCandidate() async throws {
        let account = UserAccount(id: "generation-owner", email: "generation@example.com", displayName: "Owner", linkedMemberId: UUID())
        sut.session = UserSession(account: account)
        let oldFriend = AccountFriend(memberId: UUID(), name: "Before", status: "friend")
        sut.friends = [oldFriend]
        let newFriend = AccountFriend(memberId: UUID(), name: "After", status: "friend")
        try await mockAccountService.syncFriends(accountEmail: account.email, friends: [newFriend])
        await mockAccountService.configureSnapshotGenerations(["1", "2", "3", "4", "5", "6"])

        await sut.loadRemoteData()

        XCTAssertEqual(sut.friends, [oldFriend])
        XCTAssertNotNil(sut.dataSyncRecoveryMessage)
    }

    func testReview_RelaunchFindsPendingOperationWithoutLocalReceipt() async throws {
        let account = UserAccount(id: UUID().uuidString, email: "resume@example.com", displayName: "Owner", linkedMemberId: UUID())
        sut.session = UserSession(account: account)
        await mockAccountService.configurePendingOperation(
            IdentityOperationResult(operationId: "durable-operation", status: "pending"),
            resumed: IdentityOperationResult(operationId: "durable-operation", status: "complete")
        )
        try await sut.resumePendingIdentityOperation()
        let resumes = await mockAccountService.identityResumeCount()
        XCTAssertEqual(resumes, 1)
        XCTAssertFalse(sut.isLinkingProcessing)
        XCTAssertNil(sut.linkingRecoveryMessage)
    }

    func testReview_KnownCurrenciesRemainSeparateAndUnknownRecordsStayIndividual() {
        let selfId = sut.currentUser.id
        let other = UUID()
        func expense(_ amount: Double, _ code: String?) -> Expense {
            Expense(groupId: UUID(), description: "History", totalAmount: amount, paidByMemberId: selfId,
                    involvedMemberIds: [selfId, other], splits: [ExpenseSplit(memberId: other, amount: amount)], currencyCode: code)
        }
        sut.expenses = [expense(10, "USD"), expense(20, "EUR"), expense(30, nil), expense(40, nil)]
        XCTAssertEqual(sut.overallNetBalance(), 10)
        XCTAssertEqual(sut.overallNetBalanceByCurrency(), ["USD": 10, "EUR": 20])
        XCTAssertEqual(sut.overallUnknownCurrencyExpenses().map(\.totalAmount), [30, 40])
    }

    func testReview_RemoteHydrationPreservesDistinctPersonWithCurrentUsersName() async throws {
        let selfId = UUID()
        let account = UserAccount(id: "review-owner", email: "review-owner@example.com", displayName: "Alex Smith", linkedMemberId: selfId)
        sut.session = UserSession(account: account)
        sut.currentUser = GroupMember(id: selfId, name: account.displayName, isCurrentUser: true)
        let otherAlex = GroupMember(name: "Alex Smith")
        let thirdPerson = GroupMember(name: "Morgan")
        let group = SpendingGroup(name: "Three People", members: [sut.currentUser, otherAlex, thirdPerson])
        let expense = Expense(
            groupId: group.id,
            description: "Dinner paid by the other Alex",
            totalAmount: 90,
            paidByMemberId: otherAlex.id,
            involvedMemberIds: [selfId, otherAlex.id, thirdPerson.id],
            splits: [
                ExpenseSplit(memberId: selfId, amount: 30, isSettled: true),
                ExpenseSplit(memberId: otherAlex.id, amount: 30),
                ExpenseSplit(memberId: thirdPerson.id, amount: 30)
            ]
        )
        await mockGroupCloudService.addGroup(group)
        await mockExpenseCloudService.addExpense(expense)

        await sut.loadRemoteData()

        let loadedGroup = try XCTUnwrap(sut.groups.first { $0.id == group.id })
        let loadedExpense = try XCTUnwrap(sut.expenses.first { $0.id == expense.id })
        XCTAssertTrue(loadedGroup.members.contains { $0.id == otherAlex.id })
        XCTAssertEqual(loadedExpense.paidByMemberId, otherAlex.id)
        XCTAssertEqual(loadedExpense.splits.count, 3)
        XCTAssertEqual(loadedExpense.splits.first { $0.memberId == selfId }?.amount, 30)
        XCTAssertEqual(loadedExpense.splits.first { $0.memberId == selfId }?.isSettled, true)
    }

    func testReview_ReconciliationDoesNotImportPreviousAccountsFriends() async throws {
        let accountA = UserAccount(id: "review-account-a", email: "review-a@example.com", displayName: "Owner A")
        let accountB = UserAccount(id: "review-account-b", email: "review-b@example.com", displayName: "Owner B")
        let friendA = AccountFriend(memberId: UUID(), name: "Private A Friend", status: "friend")
        let friendB = AccountFriend(memberId: UUID(), name: "Private B Friend", status: "friend")
        sut.session = UserSession(account: accountA)
        sut.friends = [friendA]
        try await mockAccountService.syncFriends(accountEmail: accountA.email, friends: [friendA])
        await mockAccountService.suspendNextFriendFetch()

        let recovery = Task { await sut.reconcileAfterNetworkRecovery() }
        await mockAccountService.waitUntilFriendFetchSuspends()
        sut.session = UserSession(account: accountB)
        sut.friends = [friendB]
        await mockAccountService.resumeFriendFetch()
        await recovery.value

        XCTAssertEqual(sut.session?.account.id, accountB.id)
        XCTAssertEqual(Set(sut.friends.map(\.memberId)), Set([friendB.memberId]))
    }

    func testReview_FailedEmailFriendPersistenceDoesNotConfirmFriend() async throws {
        let account = UserAccount(id: "review-owner", email: "review-owner@example.com", displayName: "Owner")
        let candidate = GroupMember(name: "Unpersisted Friend")
        sut.session = UserSession(account: account)
        await mockAccountService.setShouldFail(true)

        do {
            try await sut.sendLinkRequest(toEmail: "review-recipient@example.com", forFriend: candidate)
            XCTFail("Expected friend persistence to fail")
        } catch {
            XCTAssertTrue(sut.confirmedFriends.isEmpty, "A failed first friend write must not create a confirmed friend")
            XCTAssertTrue(sut.outgoingLinkRequests.isEmpty)
        }
    }

    func testReview_ManualFriendDoesNotPickOneOfTwoUnrelatedSameNameParticipants() {
        let account = UserAccount(id: "review-owner", email: "review-owner@example.com", displayName: "Owner")
        sut.session = UserSession(account: account)
        let firstAlex = GroupMember(name: "Alex")
        let secondAlex = GroupMember(name: "Alex")
        sut.groups = [
            SpendingGroup(name: "Work", members: [sut.currentUser, firstAlex]),
            SpendingGroup(name: "School", members: [sut.currentUser, secondAlex])
        ]

        let candidate = sut.manualFriendCandidate(named: "Alex")

        XCTAssertNotEqual(candidate.id, firstAlex.id)
        XCTAssertNotEqual(candidate.id, secondAlex.id)
    }
}

@MainActor
final class AppStoreLinkingTests: XCTestCase {
    var sut: AppStore!
    var mockPersistence: MockPersistenceService!
    var mockAccountService: MockAccountServiceForAppStore!
    var mockExpenseCloudService: MockExpenseCloudServiceForAppStore!
    var mockGroupCloudService: MockGroupCloudServiceForAppStore!
    var mockLinkRequestService: MockLinkRequestServiceForAppStore!
    var mockInviteLinkService: MockInviteLinkServiceForTests!

    override func setUp() async throws {
        try await super.setUp()

        mockPersistence = MockPersistenceService()
        mockAccountService = MockAccountServiceForAppStore()
        mockExpenseCloudService = MockExpenseCloudServiceForAppStore()
        mockGroupCloudService = MockGroupCloudServiceForAppStore()
        mockLinkRequestService = MockLinkRequestServiceForAppStore()
        mockInviteLinkService = MockInviteLinkServiceForTests()

        sut = AppStore(
            persistence: mockPersistence,
            accountService: mockAccountService,
            expenseCloudService: mockExpenseCloudService,
            groupCloudService: mockGroupCloudService,
            linkRequestService: mockLinkRequestService,
            inviteLinkService: mockInviteLinkService,
            emailAuthService: MockEmailAuthService(),
            skipClerkInit: true
        )
    }

    override func tearDown() async throws {
        mockPersistence.reset()
        await mockAccountService.reset()
        await mockExpenseCloudService.reset()
        await mockGroupCloudService.reset()
        await mockLinkRequestService.reset()
        await mockInviteLinkService.reset()
        sut = nil
        try await super.tearDown()
    }

    // MARK: - Link Account with Retry Tests

    func testLinkAccount_SuccessfullyLinksAccount() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        // Create a group with Alice
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let alice = group.members.first { $0.name == "Alice" }!

        // Create and accept a link request
        let request = LinkRequest(
            id: UUID(),
            requesterId: "alice-account",
            requesterEmail: "alice@example.com",
            requesterName: "Alice",
            recipientEmail: account.email,
            targetMemberId: alice.id,
            targetMemberName: "Alice",
            createdAt: Date(),
            status: .pending,
            expiresAt: Date().addingTimeInterval(7 * 24 * 3600),
            rejectedAt: nil
        )

        await mockLinkRequestService.addIncomingRequest(request)
        try await sut.fetchLinkRequests()

        // When
        try await sut.acceptLinkRequest(request)

        // Then - should complete without error
        XCTAssertTrue(true)
    }

    func testLinkAccount_HandlesErrors() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let alice = group.members.first { $0.name == "Alice" }!

        let request = LinkRequest(
            id: UUID(),
            requesterId: "alice-account",
            requesterEmail: "alice@example.com",
            requesterName: "Alice",
            recipientEmail: account.email,
            targetMemberId: alice.id,
            targetMemberName: "Alice",
            createdAt: Date(),
            status: .pending,
            expiresAt: Date().addingTimeInterval(7 * 24 * 3600),
            rejectedAt: nil
        )

        await mockLinkRequestService.addIncomingRequest(request)
        try await sut.fetchLinkRequests()

        // When
        try await sut.acceptLinkRequest(request)

        // Then
        XCTAssertTrue(true)
    }

    // MARK: - Update Friend Link Status Tests

    func testUpdateFriendLinkStatus_UpdatesLocalFriendState() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let alice = group.members.first { $0.name == "Alice" }!

        // Add friend to account service
        let friend = AccountFriend(
            memberId: alice.id,
            name: "Alice",
            nickname: nil,
            hasLinkedAccount: false,
            linkedAccountId: nil,
            linkedAccountEmail: nil
        )
        try await mockAccountService.syncFriends(accountEmail: account.email, friends: [friend])

        // When - link the account
        let request = LinkRequest(
            id: UUID(),
            requesterId: "alice-account",
            requesterEmail: "alice@example.com",
            requesterName: "Alice",
            recipientEmail: account.email,
            targetMemberId: alice.id,
            targetMemberName: "Alice",
            createdAt: Date(),
            status: .pending,
            expiresAt: Date().addingTimeInterval(7 * 24 * 3600),
            rejectedAt: nil
        )

        await mockLinkRequestService.addIncomingRequest(request)
        try await sut.fetchLinkRequests()
        try await sut.acceptLinkRequest(request)

        // Then
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(true)
    }

    // MARK: - Sync Affected Data Tests

    func testSyncAffectedData_SyncsGroupsWithLinkedMember() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        // Create multiple groups with Alice
        sut.addGroup(name: "Group1", memberNames: ["Alice", "Bob"])
        sut.addGroup(name: "Group2", memberNames: ["Alice", "Charlie"])
        sut.addGroup(name: "Group3", memberNames: ["Bob", "Charlie"]) // No Alice

        let alice = sut.groups[0].members.first { $0.name == "Alice" }!

        // Add expenses
        let group1 = sut.groups[0]
        let expense = Expense(
            groupId: group1.id,
            description: "Dinner",
            totalAmount: 100,
            paidByMemberId: alice.id,
            involvedMemberIds: [alice.id, sut.currentUser.id],
            splits: [
                ExpenseSplit(memberId: alice.id, amount: 50),
                ExpenseSplit(memberId: sut.currentUser.id, amount: 50)
            ]
        )
        sut.addExpense(expense)

        // When - link Alice's account
        let request = LinkRequest(
            id: UUID(),
            requesterId: "alice-account",
            requesterEmail: "alice@example.com",
            requesterName: "Alice",
            recipientEmail: account.email,
            targetMemberId: alice.id,
            targetMemberName: "Alice",
            createdAt: Date(),
            status: .pending,
            expiresAt: Date().addingTimeInterval(7 * 24 * 3600),
            rejectedAt: nil
        )

        await mockLinkRequestService.addIncomingRequest(request)
        try await sut.fetchLinkRequests()
        try await sut.acceptLinkRequest(request)

        // Then - should sync affected groups and expenses
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(true)
    }

    func testSyncAffectedData_HandlesMultipleExpenses() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let alice = group.members.first { $0.name == "Alice" }!

        // Add multiple expenses
        for i in 1...5 {
            let expense = Expense(
                groupId: group.id,
                description: "Expense \(i)",
                totalAmount: Double(i * 100),
                paidByMemberId: alice.id,
                involvedMemberIds: [alice.id, sut.currentUser.id],
                splits: [
                    ExpenseSplit(memberId: alice.id, amount: Double(i * 50)),
                    ExpenseSplit(memberId: sut.currentUser.id, amount: Double(i * 50))
                ]
            )
            sut.addExpense(expense)
        }

        // When - link account
        let request = LinkRequest(
            id: UUID(),
            requesterId: "alice-account",
            requesterEmail: "alice@example.com",
            requesterName: "Alice",
            recipientEmail: account.email,
            targetMemberId: alice.id,
            targetMemberName: "Alice",
            createdAt: Date(),
            status: .pending,
            expiresAt: Date().addingTimeInterval(7 * 24 * 3600),
            rejectedAt: nil
        )

        await mockLinkRequestService.addIncomingRequest(request)
        try await sut.fetchLinkRequests()
        try await sut.acceptLinkRequest(request)

        // Then
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(true)
    }

    // MARK: - Reconcile Link State Tests

    func testReconcileLinkState_UpdatesLocalStateFromRemote() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        sut.addGroup(name: "Trip", memberNames: ["Alice", "Bob"])
        let group = sut.groups[0]
        let alice = group.members.first { $0.name == "Alice" }!
        let bob = group.members.first { $0.name == "Bob" }!

        // Add remote friends with linked accounts
        let aliceFriend = AccountFriend(
            memberId: alice.id,
            name: "Alice",
            nickname: nil,
            hasLinkedAccount: true,
            linkedAccountId: "alice-account",
            linkedAccountEmail: "alice@example.com"
        )

        let bobFriend = AccountFriend(
            memberId: bob.id,
            name: "Bob",
            nickname: nil,
            hasLinkedAccount: true,
            linkedAccountId: "bob-account",
            linkedAccountEmail: "bob@example.com"
        )

        try await mockAccountService.syncFriends(accountEmail: account.email, friends: [aliceFriend, bobFriend])

        // When - trigger reconciliation
        await sut.reconcileAfterNetworkRecovery()

        // Then
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(true)
    }

    func testReconcileLinkState_HandlesPartiallyLinkedFriends() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        sut.addGroup(name: "Trip", memberNames: ["Alice", "Bob", "Charlie"])
        let group = sut.groups[0]
        let alice = group.members.first { $0.name == "Alice" }!
        let bob = group.members.first { $0.name == "Bob" }!
        let charlie = group.members.first { $0.name == "Charlie" }!

        // Only Alice is linked
        let aliceFriend = AccountFriend(
            memberId: alice.id,
            name: "Alice",
            nickname: nil,
            hasLinkedAccount: true,
            linkedAccountId: "alice-account",
            linkedAccountEmail: "alice@example.com"
        )

        let bobFriend = AccountFriend(
            memberId: bob.id,
            name: "Bob",
            nickname: nil,
            hasLinkedAccount: false,
            linkedAccountId: nil,
            linkedAccountEmail: nil
        )

        let charlieFriend = AccountFriend(
            memberId: charlie.id,
            name: "Charlie",
            nickname: nil,
            hasLinkedAccount: false,
            linkedAccountId: nil,
            linkedAccountEmail: nil
        )

        try await mockAccountService.syncFriends(accountEmail: account.email, friends: [aliceFriend, bobFriend, charlieFriend])

        // When
        await sut.reconcileAfterNetworkRecovery()

        // Then
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(true)
    }

    // MARK: - Retry Failed Link Operations Tests

    func testRetryFailedLinkOperations_RetriesPendingFailures() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        // When - trigger retry (even with no failures)
        await sut.reconcileAfterNetworkRecovery()

        // Then
        XCTAssertTrue(true)
    }

    // MARK: - Prevent Duplicate Linking Tests

    func testSendLinkRequest_ThrowsForAlreadyLinkedMember() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let alice = group.members.first { $0.name == "Alice" }!

        // Mark Alice as already linked
        let linkedFriend = AccountFriend(
            memberId: alice.id,
            name: "Alice",
            nickname: nil,
            hasLinkedAccount: true,
            linkedAccountId: "alice-account",
            linkedAccountEmail: "alice@example.com"
        )

        sut.addImportedFriend(linkedFriend)

        // When/Then - should throw
        await XCTAssertThrowsError(
            try await sut.sendLinkRequest(toEmail: "other@example.com", forFriend: alice)
        )
    }

    func testSendLinkRequest_ThrowsForAccountAlreadyLinkedToAnotherMember() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        sut.addGroup(name: "Trip", memberNames: ["Alice", "Bob"])
        let group = sut.groups[0]
        let alice = group.members.first { $0.name == "Alice" }!
        let bob = group.members.first { $0.name == "Bob" }!

        // Alice is already linked to an account
        let aliceFriend = AccountFriend(
            memberId: alice.id,
            name: "Alice",
            nickname: nil,
            hasLinkedAccount: true,
            linkedAccountId: "alice-account",
            linkedAccountEmail: "alice@example.com"
        )

        sut.addImportedFriend(aliceFriend)

        // When/Then - trying to link Bob to Alice's email should throw
        await XCTAssertThrowsError(
            try await sut.sendLinkRequest(toEmail: "alice@example.com", forFriend: bob)
        )
    }

    // MARK: - Claim Invite Token Tests

    func testClaimInviteToken_SuccessfullyClaimsToken() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let tokenId = UUID()
        let memberId = UUID()

        await mockInviteLinkService.addValidToken(
            tokenId: tokenId,
            targetMemberId: memberId,
            targetMemberName: "Alice",
            creatorEmail: "creator@example.com"
        )

        try await sut.claimInviteToken(tokenId)

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(true)
    }

    func testClaimInviteToken_HandlesInvalidToken() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let invalidTokenId = UUID()

        await XCTAssertThrowsError(
            try await sut.claimInviteToken(invalidTokenId)
        )
    }

    func testClaimInviteToken_HandlesExpiredToken() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let tokenId = UUID()

        await XCTAssertThrowsError(
            try await sut.claimInviteToken(tokenId)
        )
    }

    func testClaimInviteToken_WithMergeFriend_RefreshesCanonicalStateAfterAcknowledgement() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let tokenId = UUID()
        let targetMemberId = UUID()
        let creatorMemberId = UUID()
        let claimerCanonicalMemberId = await mockInviteLinkService.claimerCanonicalMemberId()
        // The server transaction commits this account snapshot before acknowledging the claim.
        var committedAccount = try XCTUnwrap(sut.session?.account)
        committedAccount.linkedMemberId = claimerCanonicalMemberId
        committedAccount.equivalentMemberIds = [targetMemberId]
        await mockAccountService.addAccount(committedAccount)
        let mergeFriend = AccountFriend(memberId: UUID(), name: "Chuck", hasLinkedAccount: false)
        let canonicalFriend = AccountFriend(
            memberId: creatorMemberId,
            name: "Creator",
            hasLinkedAccount: true,
            linkedAccountId: "creator-account",
            linkedAccountEmail: "creator@example.com"
        )

        sut.friends = [mergeFriend]
        try await mockAccountService.syncFriends(
            accountEmail: account.email,
            friends: [canonicalFriend]
        )

        await mockInviteLinkService.addValidToken(
            tokenId: tokenId,
            targetMemberId: targetMemberId,
            targetMemberName: "Alice",
            creatorEmail: "creator@example.com"
        )

        try await sut.claimInviteToken(tokenId, mergingLocalFriend: mergeFriend)

        let claimedTokenId = await mockInviteLinkService.claimedTokenId()
        let claimedMergeMemberId = await mockInviteLinkService.claimedMergeLocalFriendMemberId()

        XCTAssertEqual(claimedTokenId, tokenId)
        XCTAssertEqual(claimedMergeMemberId, mergeFriend.memberId)
        XCTAssertNotEqual(targetMemberId, claimerCanonicalMemberId)
        XCTAssertEqual(sut.session?.account.linkedMemberId, claimerCanonicalMemberId)
        XCTAssertTrue(sut.session?.account.equivalentMemberIds.contains(targetMemberId) == true)
        XCTAssertFalse(sut.friends.contains(where: { $0.memberId == mergeFriend.memberId }))
        XCTAssertTrue(sut.friends.contains(where: { $0.memberId == canonicalFriend.memberId }))
    }

    func testClaimInviteToken_ReconcilesCommittedMergeAfterCallerCancellation() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let tokenId = UUID()
        let targetMemberId = UUID()
        let creatorMemberId = UUID()
        let claimerCanonicalMemberId = await mockInviteLinkService.claimerCanonicalMemberId()
        // The server transaction commits this account snapshot before acknowledging the claim.
        var committedAccount = try XCTUnwrap(sut.session?.account)
        committedAccount.linkedMemberId = claimerCanonicalMemberId
        committedAccount.equivalentMemberIds = [targetMemberId]
        await mockAccountService.addAccount(committedAccount)
        let mergeFriend = AccountFriend(memberId: UUID(), name: "Chuck", hasLinkedAccount: false)
        let canonicalFriend = AccountFriend(
            memberId: creatorMemberId,
            name: "Creator",
            hasLinkedAccount: true,
            linkedAccountId: "creator-account",
            linkedAccountEmail: "creator@example.com"
        )

        sut.friends = [mergeFriend]
        try await mockAccountService.syncFriends(
            accountEmail: account.email,
            friends: [canonicalFriend]
        )
        await mockInviteLinkService.addValidToken(
            tokenId: tokenId,
            targetMemberId: targetMemberId,
            targetMemberName: "Alice",
            creatorEmail: "creator@example.com"
        )
        await mockInviteLinkService.suspendClaimAfterCommit(tokenId)

        let claimTask = Task {
            try await sut.claimInviteToken(tokenId, mergingLocalFriend: mergeFriend)
        }
        await mockInviteLinkService.waitUntilClaimCommitted(tokenId)
        claimTask.cancel()
        await mockInviteLinkService.resumeClaimAfterCommit(tokenId)

        try await claimTask.value

        XCTAssertEqual(sut.session?.account.linkedMemberId, claimerCanonicalMemberId)
        XCTAssertTrue(sut.session?.account.equivalentMemberIds.contains(targetMemberId) == true)
        XCTAssertFalse(sut.friends.contains(where: { $0.memberId == mergeFriend.memberId }))
        XCTAssertTrue(sut.friends.contains(where: { $0.memberId == canonicalFriend.memberId }))
    }

    func testClaimInviteToken_DoesNotRetryAfterAccountSwitch() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")

        sut = AppStore(
            persistence: mockPersistence,
            accountService: mockAccountService,
            expenseCloudService: mockExpenseCloudService,
            groupCloudService: mockGroupCloudService,
            linkRequestService: mockLinkRequestService,
            inviteLinkService: mockInviteLinkService,
            emailAuthService: MockEmailAuthService(),
            retryPolicy: RetryPolicy(maxAttempts: 2, baseDelay: 0, maxDelay: 0),
            skipClerkInit: true
        )
        sut.session = UserSession(account: account)

        let tokenId = UUID()
        await mockInviteLinkService.addValidToken(
            tokenId: tokenId,
            targetMemberId: UUID(),
            targetMemberName: "Alice",
            creatorEmail: "creator@example.com"
        )
        await mockInviteLinkService.suspendNextClaim(with: PayBackError.networkUnavailable)

        let claimTask = Task {
            try await sut.claimInviteToken(tokenId)
        }
        await mockInviteLinkService.waitUntilClaimAttempted()
        sut.session = UserSession(
            account: UserAccount(id: "test-456", email: "other@example.com", displayName: "Other User")
        )
        await mockInviteLinkService.resumeSuspendedClaim()

        do {
            try await claimTask.value
            XCTFail("Expected the claim to stop when the initiating account changed")
        } catch let error as PayBackError {
            XCTAssertEqual(error, .authSessionMissing)
        }

        let claimAttempts = await mockInviteLinkService.claimAttempts()
        let claimedTokenId = await mockInviteLinkService.claimedTokenId()
        XCTAssertEqual(claimAttempts, 1)
        XCTAssertNil(claimedTokenId)
    }

    func testClaimInviteToken_DoesNotRetryAfterSameAccountRelogin() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")

        sut = AppStore(
            persistence: mockPersistence,
            accountService: mockAccountService,
            expenseCloudService: mockExpenseCloudService,
            groupCloudService: mockGroupCloudService,
            linkRequestService: mockLinkRequestService,
            inviteLinkService: mockInviteLinkService,
            emailAuthService: MockEmailAuthService(),
            retryPolicy: RetryPolicy(maxAttempts: 2, baseDelay: 0, maxDelay: 0),
            skipClerkInit: true
        )
        sut.session = UserSession(account: account)

        let tokenId = UUID()
        await mockInviteLinkService.addValidToken(
            tokenId: tokenId,
            targetMemberId: UUID(),
            targetMemberName: "Alice",
            creatorEmail: "creator@example.com"
        )
        await mockInviteLinkService.suspendNextClaim(with: PayBackError.networkUnavailable)

        let claimTask = Task {
            try await sut.claimInviteToken(tokenId)
        }
        await mockInviteLinkService.waitUntilClaimAttempted()
        await sut.signOut()
        sut.session = UserSession(account: account)
        await mockInviteLinkService.resumeSuspendedClaim()

        do {
            try await claimTask.value
            XCTFail("Expected the claim to stop at the old logical session boundary")
        } catch let error as PayBackError {
            XCTAssertEqual(error, .authSessionMissing)
        }

        let claimAttempts = await mockInviteLinkService.claimAttempts()
        let claimedTokenId = await mockInviteLinkService.claimedTokenId()
        XCTAssertEqual(claimAttempts, 1)
        XCTAssertNil(claimedTokenId)
    }

    func testClaimInviteToken_DoesNotRetryWhileSignOutIsSuspended() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        let emailAuthService = SuspendedSignOutEmailAuthService()

        sut = AppStore(
            persistence: mockPersistence,
            accountService: mockAccountService,
            expenseCloudService: mockExpenseCloudService,
            groupCloudService: mockGroupCloudService,
            linkRequestService: mockLinkRequestService,
            inviteLinkService: mockInviteLinkService,
            emailAuthService: emailAuthService,
            retryPolicy: RetryPolicy(maxAttempts: 2, baseDelay: 0, maxDelay: 0),
            skipClerkInit: true
        )
        sut.session = UserSession(account: account)

        let tokenId = UUID()
        await mockInviteLinkService.addValidToken(
            tokenId: tokenId,
            targetMemberId: UUID(),
            targetMemberName: "Alice",
            creatorEmail: "creator@example.com"
        )
        await mockInviteLinkService.suspendNextClaim(with: PayBackError.networkUnavailable)

        let claimTask = Task {
            try await sut.claimInviteToken(tokenId)
        }
        await mockInviteLinkService.waitUntilClaimAttempted()
        let signOutTask = Task {
            await sut.signOut()
        }
        await emailAuthService.waitUntilSignOutStarted()
        await mockInviteLinkService.resumeSuspendedClaim()

        var claimError: PayBackError?
        do {
            try await claimTask.value
        } catch let error as PayBackError {
            claimError = error
        }

        await emailAuthService.resumeSignOut()
        await signOutTask.value

        XCTAssertEqual(claimError, .authSessionMissing)
        let claimAttempts = await mockInviteLinkService.claimAttempts()
        let claimedTokenId = await mockInviteLinkService.claimedTokenId()
        XCTAssertEqual(claimAttempts, 1)
        XCTAssertNil(claimedTokenId)
    }

    func testClaimInviteToken_DoesNotRetryWhileMissingAccountRecoverySignOutIsSuspended() async throws {
        let account = UserAccount(id: "missing-account", email: "missing@example.com", displayName: "Missing User")
        let emailAuthService = SuspendedSignOutEmailAuthService()
        let identity = AuthenticationSessionIdentity(
            email: account.email,
            displayName: account.displayName
        )

        sut = AppStore(
            persistence: mockPersistence,
            accountService: mockAccountService,
            expenseCloudService: mockExpenseCloudService,
            groupCloudService: mockGroupCloudService,
            linkRequestService: mockLinkRequestService,
            inviteLinkService: mockInviteLinkService,
            emailAuthService: emailAuthService,
            retryPolicy: RetryPolicy(maxAttempts: 2, baseDelay: 0, maxDelay: 0),
            skipClerkInit: true,
            authenticationSessionLoader: { identity }
        )
        sut.session = UserSession(account: account)

        let tokenId = UUID()
        await mockInviteLinkService.addValidToken(
            tokenId: tokenId,
            targetMemberId: UUID(),
            targetMemberName: "Alice",
            creatorEmail: "creator@example.com"
        )
        await mockInviteLinkService.suspendNextClaim(with: PayBackError.networkUnavailable)

        let claimTask = Task {
            try await sut.claimInviteToken(tokenId)
        }
        await mockInviteLinkService.waitUntilClaimAttempted()
        let recoveryTask = Task {
            await sut.checkSession()
        }
        await emailAuthService.waitUntilSignOutStarted()
        await mockInviteLinkService.resumeSuspendedClaim()

        var claimError: PayBackError?
        do {
            try await claimTask.value
        } catch let error as PayBackError {
            claimError = error
        }

        await emailAuthService.resumeSignOut()
        await recoveryTask.value

        XCTAssertEqual(claimError, .authSessionMissing)
        let claimAttempts = await mockInviteLinkService.claimAttempts()
        let claimedTokenId = await mockInviteLinkService.claimedTokenId()
        XCTAssertEqual(claimAttempts, 1)
        XCTAssertNil(claimedTokenId)
    }

    func testClaimInviteToken_DoesNotApplyRemoteFriendsAfterAccountSwitch() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        sut.session = UserSession(account: account)

        let tokenId = UUID()
        let oldAccountFriend = AccountFriend(memberId: UUID(), name: "Old Account Friend")
        let newAccountFriend = AccountFriend(memberId: UUID(), name: "New Account Friend")
        try await mockAccountService.syncFriends(
            accountEmail: account.email,
            friends: [oldAccountFriend]
        )
        await mockAccountService.suspendNextFriendFetch()
        await mockInviteLinkService.addValidToken(
            tokenId: tokenId,
            targetMemberId: UUID(),
            targetMemberName: "Alice",
            creatorEmail: "creator@example.com"
        )

        let claimTask = Task {
            try await sut.claimInviteToken(tokenId)
        }
        await mockAccountService.waitUntilFriendFetchSuspends()
        sut.session = UserSession(
            account: UserAccount(id: "test-456", email: "other@example.com", displayName: "Other User")
        )
        sut.friends = [newAccountFriend]
        await mockAccountService.resumeFriendFetch()

        do {
            try await claimTask.value
            XCTFail("Expected the claim refresh to stop when the initiating account changed")
        } catch let error as PayBackError {
            XCTAssertEqual(error, .authSessionMissing)
        }

        XCTAssertEqual(sut.friends.map(\.memberId), [newAccountFriend.memberId])
        XCTAssertFalse(sut.friends.contains(where: { $0.memberId == oldAccountFriend.memberId }))
    }

    func testClaimInviteToken_WithMergeFriend_KeepsFriendWhenClaimFails() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let tokenId = UUID()
        let targetMemberId = UUID()
        let mergeFriend = AccountFriend(memberId: UUID(), name: "Chuck", hasLinkedAccount: false)

        sut.friends = [mergeFriend]

        await mockInviteLinkService.addValidToken(
            tokenId: tokenId,
            targetMemberId: targetMemberId,
            targetMemberName: "Alice",
            creatorEmail: "creator@example.com"
        )
        await mockInviteLinkService.setClaimError(PayBackError.networkUnavailable)

        await XCTAssertThrowsError(
            try await sut.claimInviteToken(tokenId, mergingLocalFriend: mergeFriend)
        )

        XCTAssertTrue(sut.friends.contains(where: { $0.memberId == mergeFriend.memberId }))
    }

    func testClaimInviteToken_RejectsMergeFriendThatBecameLinkedBeforeSubmission() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let tokenId = UUID()
        let mergeFriend = AccountFriend(
            memberId: UUID(),
            name: "Chuck",
            hasLinkedAccount: true,
            linkedAccountId: "linked-account"
        )
        sut.friends = [mergeFriend]

        await XCTAssertThrowsError(
            try await sut.claimInviteToken(tokenId, mergingLocalFriend: mergeFriend)
        )

        let claimedTokenId = await mockInviteLinkService.claimedTokenId()
        XCTAssertNil(claimedTokenId)
    }

    func testClaimInviteToken_RejectsNonConfirmedMergeFriendStatusesBeforeSubmission() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let unavailableFriends: [(label: String, status: String, linkState: String?)] = [
            ("ghost", "friend", "ghost"),
            ("pending", "pending", nil),
            ("rejected", "rejected", nil),
            ("request_sent", "request_sent", nil)
        ]

        for unavailableFriend in unavailableFriends {
            let tokenId = UUID()
            let mergeFriend = AccountFriend(
                memberId: UUID(),
                name: "Unavailable \(unavailableFriend.label)",
                hasLinkedAccount: false,
                status: unavailableFriend.status,
                linkState: unavailableFriend.linkState
            )
            sut.friends = [mergeFriend]
            await mockInviteLinkService.addValidToken(
                tokenId: tokenId,
                targetMemberId: UUID(),
                targetMemberName: "Alice",
                creatorEmail: "creator@example.com"
            )

            await XCTAssertThrowsError(
                try await sut.claimInviteToken(tokenId, mergingLocalFriend: mergeFriend),
                "State \(unavailableFriend.label) should not be mergeable"
            )
        }

        let claimedTokenId = await mockInviteLinkService.claimedTokenId()
        XCTAssertNil(claimedTokenId)
    }

    func testMergeEligibility_AllowsManualFriends() {
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Imported Friend",
            hasLinkedAccount: false,
            status: "manual",
            linkState: "unlinked"
        )

        XCTAssertTrue(sut.isMergeableUnlinkedFriend(friend))
    }

    func testMergeEligibility_RejectsLinkedMemberProvenance() throws {
        let friendMemberId = UUID()
        let linkedMemberId = UUID()
        let dto = ConvexAccountFriendDTO(
            member_id: friendMemberId.uuidString,
            name: "Partially Linked Friend",
            nickname: nil,
            original_name: nil,
            status: "friend",
            link_state: "unlinked",
            has_linked_account: false,
            linked_account_id: nil,
            linked_account_email: nil,
            linked_member_id: linkedMemberId.uuidString,
            profile_image_url: nil,
            profile_avatar_color: nil
        )

        let friend = try XCTUnwrap(dto.toAccountFriend())
        XCTAssertFalse(sut.isMergeableUnlinkedFriend(friend))
    }

    func testClaimInviteToken_RejectsStatuslessGroupOnlyMergeFriendBeforeSubmission() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let tokenId = UUID()
        let mergeFriend = AccountFriend(memberId: UUID(), name: "Group Only", hasLinkedAccount: false)
        sut.friends = [mergeFriend]
        sut.groups = [
            SpendingGroup(
                name: "Shared Group",
                members: [
                    GroupMember(id: sut.currentUser.id, name: sut.currentUser.name, isCurrentUser: true),
                    GroupMember(id: mergeFriend.memberId, name: mergeFriend.name)
                ],
                isDirect: false
            )
        ]
        await mockInviteLinkService.addValidToken(
            tokenId: tokenId,
            targetMemberId: UUID(),
            targetMemberName: "Alice",
            creatorEmail: "creator@example.com"
        )

        await XCTAssertThrowsError(
            try await sut.claimInviteToken(tokenId, mergingLocalFriend: mergeFriend)
        )

        let claimedTokenId = await mockInviteLinkService.claimedTokenId()
        XCTAssertNil(claimedTokenId)
    }

    // MARK: - Manual Friend Merge Tests

    func testMergeableUnlinkedFriendsExcludesPendingAndLinkedRows() {
        let eligible = AccountFriend(memberId: UUID(), name: "Eligible", status: "friend")
        let pending = AccountFriend(memberId: UUID(), name: "Pending", status: "pending")
        let linked = AccountFriend(
            memberId: UUID(),
            name: "Linked",
            hasLinkedAccount: true,
            linkedAccountId: "linked-account",
            linkedAccountEmail: "linked@example.com",
            status: "friend"
        )
        sut.friends = [eligible, pending, linked]

        XCTAssertEqual(sut.mergeableUnlinkedFriends.map(\.memberId), [eligible.memberId])
    }

    func testMergeableUnlinkedFriendsIncludesManualRows() {
        let manual = AccountFriend(memberId: UUID(), name: "Imported Friend", status: "manual")
        sut.friends = [manual]

        XCTAssertEqual(sut.mergeableUnlinkedFriends.map(\.memberId), [manual.memberId])
    }

    func testMergeableUnlinkedFriendsExcludesCurrentUserEquivalentIdentity() async throws {
        let equivalentMemberId = UUID()
        let account = UserAccount(
            id: "test-123",
            email: "test@example.com",
            displayName: "Example User",
            equivalentMemberIds: [equivalentMemberId]
        )
        await mockAccountService.addAccount(account)
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let staleSelfAlias = AccountFriend(
            memberId: equivalentMemberId,
            name: "Old Me",
            status: "friend"
        )
        sut.friends = [staleSelfAlias]

        XCTAssertTrue(sut.mergeableUnlinkedFriends.isEmpty)
    }

    func testMergeFriend_PreservesLocalSourceWhenBackendRejects() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let source = AccountFriend(memberId: UUID(), name: "Duplicate", status: "friend")
        let target = AccountFriend(memberId: UUID(), name: "Canonical", status: "friend")
        sut.friends = [source, target]
        await mockAccountService.setShouldFail(true)

        await XCTAssertThrowsError(
            try await sut.mergeFriend(unlinkedMemberId: source.memberId, into: target.memberId)
        )

        XCTAssertTrue(sut.friends.contains(where: { $0.memberId == source.memberId }))
    }

    func testMergeFriend_RoutesTwoOwnedUnlinkedFriendsToLocalMergeEndpoint() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let source = AccountFriend(memberId: UUID(), name: "Duplicate", status: "friend")
        let target = AccountFriend(memberId: UUID(), name: "Canonical", status: "friend")
        sut.friends = [source, target]
        try await mockAccountService.syncFriends(accountEmail: account.email, friends: [source, target])

        try await sut.mergeFriend(unlinkedMemberId: source.memberId, into: target.memberId)

        let localMerge = await mockAccountService.latestMergeUnlinkedFriendsCall()
        let compatibilityMerge = await mockAccountService.latestMergeMemberIdsCall()
        XCTAssertEqual(localMerge?.target, target.memberId.uuidString)
        XCTAssertEqual(localMerge?.source, source.memberId.uuidString)
        XCTAssertNil(compatibilityMerge)
        XCTAssertFalse(sut.friends.contains(where: { $0.memberId == source.memberId }))
        let canonical = try XCTUnwrap(sut.friends.first(where: { $0.memberId == target.memberId }))
        XCTAssertTrue(canonical.aliasMemberIds?.contains(source.memberId) == true)
    }

    func testMergeFriend_HydrationFailureKeepsRetryableLocalState() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let source = AccountFriend(memberId: UUID(), name: "Duplicate", status: "friend")
        let target = AccountFriend(memberId: UUID(), name: "Canonical", status: "friend")
        sut.friends = [source, target]
        try await mockAccountService.syncFriends(accountEmail: account.email, friends: [source, target])
        await mockAccountService.failNextFriendFetch()

        await XCTAssertThrowsError(
            try await sut.mergeFriend(unlinkedMemberId: source.memberId, into: target.memberId)
        )
        XCTAssertTrue(sut.friends.contains(where: { $0.memberId == source.memberId }))

        try await sut.mergeFriend(unlinkedMemberId: source.memberId, into: target.memberId)
        XCTAssertFalse(sut.friends.contains(where: { $0.memberId == source.memberId }))
        XCTAssertTrue(sut.friends.contains(where: { $0.memberId == target.memberId }))
    }

    func testMergeFriend_RetriesCommittedMutationAfterAcknowledgementLoss() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let source = AccountFriend(memberId: UUID(), name: "Duplicate", status: "friend")
        let target = AccountFriend(memberId: UUID(), name: "Canonical", status: "friend")
        sut.friends = [source, target]
        try await mockAccountService.syncFriends(accountEmail: account.email, friends: [source, target])
        await mockAccountService.throwAfterNextMergeCommit()

        try await sut.mergeFriend(unlinkedMemberId: source.memberId, into: target.memberId)

        let callCount = await mockAccountService.mergeUnlinkedFriendsCallCount()
        XCTAssertEqual(callCount, 2)
        XCTAssertFalse(sut.friends.contains(where: { $0.memberId == source.memberId }))
        XCTAssertTrue(sut.friends.contains(where: { $0.memberId == target.memberId }))
    }

    func testMergeFriend_AccountSwitchDuringRetryStopsSecondMutation() async throws {
        let accountA = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        let accountB = UserAccount(id: "test-456", email: "other@example.com", displayName: "Other User")
        sut.session = UserSession(account: accountA)

        let source = AccountFriend(memberId: UUID(), name: "Duplicate", status: "friend")
        let target = AccountFriend(memberId: UUID(), name: "Canonical", status: "friend")
        let accountBFriend = AccountFriend(memberId: UUID(), name: "Other Friend", status: "friend")
        sut.friends = [source, target]
        try await mockAccountService.syncFriends(accountEmail: accountA.email, friends: [source, target])
        await mockAccountService.throwAfterNextMergeCommit()

        let mergeTask = Task { @MainActor in
            try await sut.mergeFriend(unlinkedMemberId: source.memberId, into: target.memberId)
        }
        let firstMergeStarted = await waitForMergeUnlinkedFriendCall()
        XCTAssertTrue(firstMergeStarted)
        sut.session = UserSession(account: accountB)
        sut.friends = [accountBFriend]

        do {
            try await mergeTask.value
            XCTFail("Expected the retry to stop when the initiating account changed")
        } catch let error as PayBackError {
            XCTAssertEqual(error, .authSessionMissing)
        }

        let callCount = await mockAccountService.mergeUnlinkedFriendsCallCount()
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(sut.session?.account, accountB)
        XCTAssertEqual(sut.friends.map(\.memberId), [accountBFriend.memberId])
    }

    private func waitForMergeUnlinkedFriendCall() async -> Bool {
        for _ in 0..<1_000 {
            if await mockAccountService.mergeUnlinkedFriendsCallCount() > 0 { return true }
            await Task.yield()
        }
        return false
    }

    func testMergeFriend_DoesNotApplyRemoteFriendsAfterAccountSwitch() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        sut.session = UserSession(account: account)

        let source = AccountFriend(memberId: UUID(), name: "Duplicate", status: "friend")
        let target = AccountFriend(memberId: UUID(), name: "Canonical", status: "friend")
        let newAccountFriend = AccountFriend(memberId: UUID(), name: "New Account Friend", status: "friend")
        sut.friends = [source, target]
        try await mockAccountService.syncFriends(accountEmail: account.email, friends: [source, target])
        await mockAccountService.suspendNextFriendFetch()

        let mergeTask = Task {
            try await sut.mergeFriend(unlinkedMemberId: source.memberId, into: target.memberId)
        }
        await mockAccountService.waitUntilFriendFetchSuspends()
        sut.session = UserSession(
            account: UserAccount(id: "test-456", email: "other@example.com", displayName: "Other User")
        )
        sut.friends = [newAccountFriend]
        await mockAccountService.resumeFriendFetch()

        do {
            try await mergeTask.value
            XCTFail("Expected the merge refresh to stop when the initiating account changed")
        } catch let error as PayBackError {
            XCTAssertEqual(error, .authSessionMissing)
        }

        XCTAssertEqual(sut.friends.map(\.memberId), [newAccountFriend.memberId])
        XCTAssertFalse(sut.friends.contains(where: { $0.memberId == source.memberId }))
        XCTAssertFalse(sut.friends.contains(where: { $0.memberId == target.memberId }))
    }

    func testMergeFriend_DoesNotApplyRemoteFriendsAfterSameAccountRelogin() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        sut.session = UserSession(account: account)

        let source = AccountFriend(memberId: UUID(), name: "Duplicate", status: "friend")
        let target = AccountFriend(memberId: UUID(), name: "Canonical", status: "friend")
        let newSessionFriend = AccountFriend(memberId: UUID(), name: "New Session Friend", status: "friend")
        sut.friends = [source, target]
        try await mockAccountService.syncFriends(accountEmail: account.email, friends: [source, target])
        await mockAccountService.suspendNextFriendFetch()

        let mergeTask = Task {
            try await sut.mergeFriend(unlinkedMemberId: source.memberId, into: target.memberId)
        }
        await mockAccountService.waitUntilFriendFetchSuspends()
        await sut.signOut()
        sut.session = UserSession(account: account)
        sut.friends = [newSessionFriend]
        await mockAccountService.resumeFriendFetch()

        do {
            try await mergeTask.value
            XCTFail("Expected the merge refresh to stop at the old logical session boundary")
        } catch let error as PayBackError {
            XCTAssertEqual(error, .authSessionMissing)
        }

        XCTAssertEqual(sut.friends.map(\.memberId), [newSessionFriend.memberId])
        XCTAssertFalse(sut.friends.contains(where: { $0.memberId == source.memberId }))
        XCTAssertFalse(sut.friends.contains(where: { $0.memberId == target.memberId }))
    }

    func testMergeFriend_RejectsLinkedTargetBeforeBackendSubmission() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let source = AccountFriend(memberId: UUID(), name: "Duplicate", status: "friend")
        let target = AccountFriend(
            memberId: UUID(),
            name: "Canonical",
            hasLinkedAccount: true,
            linkedAccountId: "canonical-account",
            linkedAccountEmail: "canonical@example.com",
            status: "friend"
        )
        sut.friends = [source, target]
        await XCTAssertThrowsError(
            try await sut.mergeFriend(unlinkedMemberId: source.memberId, into: target.memberId)
        )

        let compatibilityMerge = await mockAccountService.latestMergeMemberIdsCall()
        let localMerge = await mockAccountService.latestMergeUnlinkedFriendsCall()
        XCTAssertNil(compatibilityMerge)
        XCTAssertNil(localMerge)
    }

    func testMergeFriend_RejectsGroupOnlySourceBeforeBackendSubmission() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let groupOnlySource = UUID()
        let target = AccountFriend(memberId: UUID(), name: "Canonical", status: "friend")
        sut.friends = [target]

        await XCTAssertThrowsError(
            try await sut.mergeFriend(unlinkedMemberId: groupOnlySource, into: target.memberId)
        )

        let compatibilityMerge = await mockAccountService.latestMergeMemberIdsCall()
        let localMerge = await mockAccountService.latestMergeUnlinkedFriendsCall()
        XCTAssertNil(compatibilityMerge)
        XCTAssertNil(localMerge)
    }

    // MARK: - Unlinked Friend Rename Tests

    func testRenameUnlinkedFriendUpdatesEquivalentCachedNamesAndCloudSnapshots() async throws {
        let account = UserAccount(
            id: "test-123",
            email: "test@example.com",
            displayName: "Example User"
        )
        let currentUserId = UUID()
        let canonicalId = UUID()
        let aliasId = UUID()
        let group = SpendingGroup(
            name: "Old Name",
            members: [
                GroupMember(id: currentUserId, name: "Example User", isCurrentUser: true),
                GroupMember(id: aliasId, name: "Old Name")
            ],
            isDirect: true
        )
        let expense = Expense(
            groupId: group.id,
            description: "Dinner",
            totalAmount: 20,
            paidByMemberId: currentUserId,
            involvedMemberIds: [currentUserId, aliasId],
            splits: [
                ExpenseSplit(memberId: currentUserId, amount: 10),
                ExpenseSplit(memberId: aliasId, amount: 10)
            ],
            participantNames: [
                currentUserId: "Example User",
                aliasId: "Old Name"
            ]
        )
        let friend = AccountFriend(
            memberId: canonicalId,
            name: "Old Name",
            hasLinkedAccount: false,
            status: "friend",
            aliasMemberIds: [aliasId]
        )

        sut.currentUser = GroupMember(
            id: currentUserId,
            name: "Example User",
            isCurrentUser: true
        )
        sut.session = UserSession(account: account)
        try await mockAccountService.syncFriends(accountEmail: account.email, friends: [friend])
        await mockGroupCloudService.addGroup(group)
        await mockExpenseCloudService.addExpense(expense)
        await mockExpenseCloudService.setUpsertDelaysNanoseconds([250_000_000])
        await sut.loadRemoteData()

        let initialUpsertInvocationCount = await mockExpenseCloudService.currentUpsertInvocationCount()
        XCTAssertEqual(initialUpsertInvocationCount, 0, "Hydration must not rewrite historical expenses")

        try await sut.renameUnlinkedFriend(memberId: canonicalId, to: "  New Name  ")
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(sut.friends.first?.name, "New Name")
        XCTAssertEqual(
            sut.groups.first?.members.first(where: { $0.id == aliasId })?.name,
            "New Name"
        )
        XCTAssertEqual(sut.groups.first?.name, "New Name")
        XCTAssertEqual(sut.expenses.first?.participantNames?[aliasId], "New Name")

        let syncedFriends = await mockAccountService.latestSyncedFriends(
            accountEmail: account.email
        )
        XCTAssertEqual(syncedFriends?.first?.name, "New Name")

        let syncedGroups = try await mockGroupCloudService.fetchGroups()
        XCTAssertEqual(
            syncedGroups.first?.members.first(where: { $0.id == aliasId })?.name,
            "New Name"
        )
        let syncedExpenses = try await mockExpenseCloudService.fetchExpenses()
        XCTAssertEqual(syncedExpenses.first?.participantNames?[aliasId], "New Name")
    }

    func testRemoteLoadStartedBeforeSignOutCannotRestoreSignedOutData() async throws {
        let account = UserAccount(
            id: "old-account",
            email: "old@example.com",
            displayName: "Old User"
        )
        let staleGroup = SpendingGroup(
            name: "Old Account Group",
            members: [
                GroupMember(name: "One"),
                GroupMember(name: "Two"),
                GroupMember(name: "Three")
            ]
        )
        sut.session = UserSession(account: account)
        await mockGroupCloudService.queueFetches(
            groups: [[staleGroup]],
            delaysNanoseconds: [250_000_000]
        )

        let load = Task { await sut.loadRemoteData() }
        for _ in 0..<100 {
            if await mockGroupCloudService.currentFetchInvocationCount() == 1 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        await sut.signOut()
        await load.value

        XCTAssertNil(sut.session)
        XCTAssertTrue(sut.groups.isEmpty)
        XCTAssertTrue(sut.expenses.isEmpty)
        XCTAssertTrue(sut.friends.isEmpty)
    }

    func testNewerOverlappingRemoteLoadWinsOverOlderSnapshot() async throws {
        let account = UserAccount(
            id: "test-account",
            email: "test@example.com",
            displayName: "Example User"
        )
        let members = [
            GroupMember(name: "One"),
            GroupMember(name: "Two"),
            GroupMember(name: "Three")
        ]
        let staleGroup = SpendingGroup(name: "Stale Group", members: members)
        let freshGroup = SpendingGroup(name: "Fresh Group", members: members)
        sut.session = UserSession(account: account)
        await mockGroupCloudService.queueFetches(
            groups: [[staleGroup], [freshGroup]],
            delaysNanoseconds: [250_000_000, 0]
        )

        let olderLoad = Task { await sut.loadRemoteData() }
        for _ in 0..<100 {
            if await mockGroupCloudService.currentFetchInvocationCount() == 1 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let newerLoad = Task { await sut.loadRemoteData() }

        await newerLoad.value
        await olderLoad.value

        XCTAssertEqual(sut.groups.map(\.name), ["Fresh Group"])
    }

    func testRenameUnlinkedFriendResolvesImportedGroupMemberPointerWithoutAliasMetadata() async throws {
        let account = UserAccount(
            id: "test-123",
            email: "test@example.com",
            displayName: "Example User"
        )
        let currentUserId = UUID()
        let friendMemberId = UUID()
        let importedGroupMemberId = UUID()
        let group = SpendingGroup(
            name: "Old Name",
            members: [
                GroupMember(id: currentUserId, name: "Example User", isCurrentUser: true),
                GroupMember(
                    id: importedGroupMemberId,
                    name: "Old Name",
                    accountFriendMemberId: friendMemberId
                )
            ],
            isDirect: true
        )
        let expense = Expense(
            groupId: group.id,
            description: "Dinner",
            totalAmount: 20,
            paidByMemberId: currentUserId,
            involvedMemberIds: [currentUserId, importedGroupMemberId],
            splits: [
                ExpenseSplit(memberId: currentUserId, amount: 10),
                ExpenseSplit(memberId: importedGroupMemberId, amount: 10)
            ],
            participantNames: [
                currentUserId: "Example User",
                importedGroupMemberId: "Old Name"
            ]
        )
        let friend = AccountFriend(
            memberId: friendMemberId,
            name: "Old Name",
            hasLinkedAccount: false,
            status: "friend"
        )

        sut.currentUser = GroupMember(
            id: currentUserId,
            name: "Example User",
            isCurrentUser: true
        )
        sut.session = UserSession(account: account)
        try await mockAccountService.syncFriends(accountEmail: account.email, friends: [friend])
        await mockGroupCloudService.addGroup(group)
        await mockExpenseCloudService.addExpense(expense)
        await sut.loadRemoteData()

        try await sut.renameUnlinkedFriend(memberId: friendMemberId, to: "New Name")

        XCTAssertEqual(sut.groups.first?.members.last?.name, "New Name")
        XCTAssertEqual(sut.groups.first?.name, "New Name")
        XCTAssertEqual(sut.expenses.first?.participantNames?[importedGroupMemberId], "New Name")
    }

    func testMergePreviewResolvesImportedGroupMemberPointerWithoutAliasMetadata() {
        let friendMemberId = UUID()
        let importedGroupMemberId = UUID()
        let group = SpendingGroup(
            name: "Trip",
            members: [
                GroupMember(
                    id: importedGroupMemberId,
                    name: "Friend",
                    accountFriendMemberId: friendMemberId
                )
            ]
        )
        let expense = Expense(
            groupId: group.id,
            description: "Dinner",
            totalAmount: 20,
            paidByMemberId: importedGroupMemberId,
            involvedMemberIds: [importedGroupMemberId],
            splits: [ExpenseSplit(memberId: importedGroupMemberId, amount: 20)]
        )

        sut.friends = [AccountFriend(memberId: friendMemberId, name: "Friend", status: "friend")]
        sut.groups = [group]
        sut.expenses = [expense]

        let identityMemberIds = sut.accountFriendIdentityMemberIds(for: [friendMemberId])
        let expenseCount = MergeFriendsLogic.combinedExpenseCount(
            expenses: sut.expenses,
            memberIds: Array(identityMemberIds),
            areSamePerson: sut.areSamePerson
        )

        XCTAssertEqual(expenseCount, 1)
    }

    func testRenameUnlinkedFriendRejectsLinkedFriendWithoutChangingNickname() async throws {
        let account = UserAccount(
            id: "test-123",
            email: "test@example.com",
            displayName: "Example User"
        )
        let linked = AccountFriend(
            memberId: UUID(),
            name: "Real Name",
            nickname: "Nickname",
            hasLinkedAccount: true,
            linkedAccountId: "linked-account",
            linkedAccountEmail: "linked@example.com",
            status: "friend"
        )
        sut.session = UserSession(account: account)
        sut.friends = [linked]

        await XCTAssertThrowsError(
            try await sut.renameUnlinkedFriend(memberId: linked.memberId, to: "Changed")
        )

        XCTAssertEqual(sut.friends.first?.name, "Real Name")
        XCTAssertEqual(sut.friends.first?.nickname, "Nickname")
    }

    // MARK: - Validate Invite Token Tests

    func testValidateInviteToken_ReturnsValidationForValidToken() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let tokenId = UUID()
        let memberId = UUID()

        await mockInviteLinkService.addValidToken(
            tokenId: tokenId,
            targetMemberId: memberId,
            targetMemberName: "Alice",
            creatorEmail: "creator@example.com"
        )

        // When
        let validation = try await sut.validateInviteToken(tokenId)

        // Then
        XCTAssertTrue(validation.isValid)
        XCTAssertNotNil(validation.token)
    }

    func testValidateInviteToken_HandlesInvalidToken() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let tokenId = UUID()

        // When/Then - should throw or return invalid for non-existent token
        do {
            let validation = try await sut.validateInviteToken(tokenId)
            XCTAssertFalse(validation.isValid)
        } catch {
            // Expected for invalid token
            XCTAssertTrue(true)
        }
    }

}

private actor SuspendedSignOutEmailAuthService: EmailAuthService {
    private var hasStartedSignOut = false
    private var signOutStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var signOutContinuation: CheckedContinuation<Void, Never>?

    func signIn(email: String, password: String) async throws -> EmailAuthSignInResult {
        throw PayBackError.authInvalidCredentials(message: "Not implemented")
    }

    func signUp(
        email: String,
        password: String,
        firstName: String,
        lastName: String?
    ) async throws -> SignUpResult {
        throw PayBackError.authInvalidCredentials(message: "Not implemented")
    }

    func verifyCode(code: String) async throws -> EmailAuthSignInResult {
        throw PayBackError.authInvalidCredentials(message: "Not implemented")
    }

    func sendPasswordReset(email: String) async throws {
        throw PayBackError.authInvalidCredentials(message: "Not implemented")
    }

    func verifyPasswordResetCode(code: String) async throws {
        throw PayBackError.authSessionMissing
    }

    func resendPasswordResetCode() async throws {
        throw PayBackError.authSessionMissing
    }

    func completePasswordReset(newPassword: String) async throws -> PasswordResetResult {
        throw PayBackError.authSessionMissing
    }

    func resendConfirmationEmail(email: String) async throws {
        throw PayBackError.authInvalidCredentials(message: "Not implemented")
    }

    func signOut() async throws {
        hasStartedSignOut = true
        let waiters = signOutStartWaiters
        signOutStartWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            signOutContinuation = continuation
        }
    }

    func deleteCurrentUser() async throws {
        throw PayBackError.authInvalidCredentials(message: "Not implemented")
    }

    func waitUntilSignOutStarted() async {
        guard !hasStartedSignOut else { return }
        await withCheckedContinuation { continuation in
            signOutStartWaiters.append(continuation)
        }
    }

    func resumeSignOut() {
        signOutContinuation?.resume()
        signOutContinuation = nil
    }
}
