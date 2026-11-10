import Foundation

protocol AccountService: Sendable { func bulkImport(request: BulkImportRequest) async throws -> BulkImportResult }
struct Dependencies { static var current = Dependencies(accountService: RecordingService()); let accountService: AccountService }
enum RemoteHydrationOutcome { case complete, incomplete }
@MainActor final class AppStore {
    var dataEpoch = UUID()
    struct Session { var account: Account }; struct Account { var id: String; var email: String }
    var session: Session? = Session(account: Account(id: "account", email: "review@example.test"))
    var isImporting = false
    var currentUser: GroupMember
    var friends: [AccountFriend] = []; var groups: [SpendingGroup] = []; var expenses: [Expense] = []
    var refreshCount = 0; var failRefresh = false; var switchDuringRefresh = false
    init(currentUser: GroupMember) { self.currentUser = currentUser }
    func refreshAfterImport(expectedAccountID: String, expectedDataEpoch: UUID) async -> RemoteHydrationOutcome {
        precondition(!isImporting && expectedDataEpoch == dataEpoch)
        refreshCount += 1
        if switchDuringRefresh {
            dataEpoch = UUID(); session = Session(account: Account(id: "new", email: "new@example.test"))
            isImporting = true
            return .incomplete
        }
        if failRefresh { return .incomplete }
        expenses = [] // A server snapshot may omit suppressed or skipped source rows.
        return .complete
    }
}

actor RecordingService: AccountService {
    enum Mode { case adaptive, lostCommit, missing, duplicate, singleBudget, uncertain, rejected, scrubbed, normal }
    let mode: Mode
    var calls: [Data] = []; var committed: Set<String> = []; var budgets: Set<String> = []
    var lost = false; var replayedIdentically = false; var lostRequest: Data?
    init(_ mode: Mode = .normal) { self.mode = mode }
    func state() -> (calls: Int, committed: Int, budgets: Set<String>, replayed: Bool) {
        (calls.count, committed.count, budgets, replayedIdentically)
    }
    func bulkImport(request: BulkImportRequest) async throws -> BulkImportResult {
        precondition(request.expected_account_id == "account" && request.expected_account_email == "review@example.test")
        precondition(request.financial_contract_version == 2)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(request); calls.append(encoded)
        let kind = !request.friends.isEmpty ? "friend" : (!request.groups.isEmpty ? "group" : "expense")
        let ids = kind == "friend" ? request.friends.map(\.member_id) : (kind == "group" ? request.groups.map(\.id) : request.expenses.map(\.id))
        precondition(!ids.isEmpty)
        precondition([!request.friends.isEmpty, !request.groups.isEmpty, !request.expenses.isEmpty].filter { $0 }.count == 1)
        for group in request.groups { precondition(group.members.count == 64 || group.members.count == 2) }
        let manifests = request.history_manifest ?? []
        precondition(manifests.count == request.expenses.filter { $0.context_kind != "grouped_individual" }.count)
        for expense in request.expenses where expense.context_kind != "grouped_individual" {
            let declaration = manifests.first { $0.expense_id == expense.id }!
            precondition(declaration.group_id == expense.group_id)
            precondition(Set(declaration.historical_member_ids) == Set([expense.paid_by_member_id] + expense.involved_member_ids + expense.splits.map(\.member_id)))
            precondition(expense.splits.map(\.amount) == [0.0004, 1])
            precondition(expense.splits.map(\.is_settled) == [true, false])
        }
        if mode == .singleBudget { throw ImportTransportError.budgetExceeded(scope: "request") }
        if mode == .uncertain { throw ImportTransportError.uncertainOutcome }
        let limit = kind == "friend" ? 4 : (kind == "group" ? 1 : 2)
        if (mode == .adaptive || mode == .lostCommit) && ids.count > limit {
            budgets.insert(kind); throw ImportTransportError.budgetExceeded(scope: "request")
        }
        var outcomes: [BulkImportResult.ItemOutcome] = []
        for (index, id) in ids.enumerated() {
            let key = kind + ":" + id.lowercased()
            let status = mode == .rejected && index == 0 ? "rejected" : (mode == .scrubbed ? "updated" : (committed.contains(key) ? "already_present" : "created"))
            if status != "rejected" { committed.insert(key) }
            outcomes.append(.init(kind: kind, id: id.lowercased(), status: status,
                error_code: status == "rejected" ? "IMPORT_ITEM_INVALID" : nil,
                notice: mode == .scrubbed ? "inactive_party_scrubbed" : nil))
        }
        if mode == .lostCommit && kind == "expense" && !lost {
            lost = true; lostRequest = encoded; throw ImportTransportError.uncertainOutcome
        }
        if let lostRequest, lostRequest == encoded { replayedIdentically = true }
        if mode == .duplicate, outcomes.count > 1 { outcomes[1] = outcomes[0] }
        return BulkImportResult(success: mode != .rejected,
            created: .init(friends: 999, groups: 999, expenses: 999), // Must never drive modern progress.
            errors: mode == .rejected ? ["Invalid row"] : [], outcomes: mode == .missing ? nil : outcomes)
    }
}

@main struct Proof {
    @MainActor static func main() async throws {
        let owner = GroupMember(name: "Owner")
        let canonical = UUID()
        let others = (0..<63).map { GroupMember(name: "Participant \($0)") }
        let groups = (0..<24).map { SpendingGroup(name: "Group \($0)", members: [owner] + others,
            memberIdentityMap: [others[0].id: canonical]) }
        let expenses = (0..<100).map { index in
            Expense(groupId: groups[0].id, description: "Expense \(index)", totalAmount: 1.0004,
                paidByMemberId: owner.id, involvedMemberIds: [owner.id, canonical],
                splits: [ExpenseSplit(memberId: owner.id, amount: 0.0004, isSettled: true), ExpenseSplit(memberId: canonical, amount: 1)],
                participantNames: [owner.id: "Historic owner", canonical: "Historic participant"],
                subexpenses: [Subexpense(amount: 0), Subexpense(amount: 1.0004)], notes: "Retained note", currencyCode: nil)
        }
        let friends = (0..<20).map { AccountFriend(memberId: UUID(), name: "Friend \($0)") }
        let text = DataExportService.exportAllData(groups: groups, expenses: expenses, friends: friends,
            currentUser: owner, accountEmail: "review@example.test")
        let parsed = try DataImportService.parseExport(text)
        precondition(parsed.groups.allSatisfy { $0.memberCount == 64 })
        precondition(parsed.groupMembers.count == 24 * 64)
        let target = UUID()
        let converted = try DataImportService.convertToBulkImportRequest(from: DataImportService.applyRemappings(to: parsed, memberIdMapping: [owner.id: target], groupIdMapping: [:]))
        precondition(converted.history_manifest?.count == 100)
        precondition(converted.history_manifest!.allSatisfy { Set($0.historical_member_ids) == Set([target.uuidString, canonical.uuidString]) })
        precondition(converted.expenses[0].participants.first { $0.member_id == target.uuidString }?.name == "Historic owner")
        let service = RecordingService(.lostCommit)
        let result = await DataImportService.performBulkImport(from: parsed, memberIdMapping: [owner.id: target], accountService: service,
            expectedAccountID: "account", expectedAccountEmail: "review@example.test", isCurrent: { true }, sleeper: { _ in })
        guard case .success(let summary) = result else { fatalError("Adaptive import failed: \(result)") }
        precondition(summary.processedItems == 144 && summary.alreadyPresentItems == 2 && summary.totalItems == 142)
        let recorded = await service.state()
        precondition(recorded.committed == 144 && recorded.budgets == Set(["friend", "group", "expense"]) && recorded.replayed)
        print("PASS: actual parser/remapping/importer, 24 x 64-member groups +100 expenses, all-phase bisection, exact manifests/rows, lost-commit replay and truthful outcomes")

        for mode in [RecordingService.Mode.missing, .duplicate, .singleBudget, .uncertain, .rejected] {
            let failing = RecordingService(mode)
            let result = await DataImportService.performBulkImport(from: parsed, accountService: failing,
                expectedAccountID: "account", expectedAccountEmail: "review@example.test", isCurrent: { true }, sleeper: { _ in })
            guard case .partialSuccess(let partial, _) = result else { fatalError("Expected incomplete \(mode)") }
            precondition(partial.incompletePhase == "friend")
            if mode == .missing || mode == .duplicate { precondition(partial.processedItems == 0) }
            if mode == .uncertain { let state = await failing.state(); precondition(state.calls == 3) }
        }
        var active = true
        let switched = await DataImportService.performBulkImport(from: parsed, accountService: RecordingService(.uncertain),
            expectedAccountID: "account", expectedAccountEmail: "review@example.test", isCurrent: { active }, sleeper: { _ in active = false })
        guard case .partialSuccess = switched else { fatalError("Account switch must stop backoff") }
        let cancelled = Task { @MainActor in
            await DataImportService.performBulkImport(from: parsed, accountService: RecordingService(.uncertain),
                expectedAccountID: "account", expectedAccountEmail: "review@example.test", isCurrent: { true }, sleeper: { _ in withUnsafeCurrentTask { $0?.cancel() } })
        }
        guard case .partialSuccess = await cancelled.value else { fatalError("Cancellation must stop backoff") }
        print("PASS: malformed/missing outcomes, single-item overflow, row rejection, bounded uncertain retries, account switch/cancellation during backoff")

        let scrubbed = await DataImportService.performBulkImport(from: parsed, accountService: RecordingService(.scrubbed),
            expectedAccountID: "account", expectedAccountEmail: "review@example.test", isCurrent: { true }, sleeper: { _ in })
        guard case .success(let scrub) = scrubbed else { fatalError("Scrub notice is not rejection") }
        precondition(scrub.scrubbedItems == 144 && scrub.updatedItems == 144 && scrub.totalItems == 0)
        for failure in [false, true] {
            Dependencies.current = Dependencies(accountService: RecordingService())
            let store = AppStore(currentUser: owner); store.failRefresh = failure
            let restored = await DataImportService.importData(from: text, into: store)
            precondition(store.refreshCount == 1 && store.expenses.isEmpty && !store.isImporting)
            if failure {
                guard case .partialSuccess(let progress, _) = restored else { fatalError("Refresh failure is incomplete") }
                precondition(progress.processedItems == 144 && progress.incompletePhase == "refresh")
            } else { guard case .success = restored else { fatalError("Successful hydration required") } }
        }
        Dependencies.current = Dependencies(accountService: RecordingService())
        let switchedStore = AppStore(currentUser: owner); switchedStore.switchDuringRefresh = true
        let switchedRefresh = await DataImportService.importData(from: text, into: switchedStore)
        guard case .partialSuccess = switchedRefresh else { fatalError("Stale refresh must not complete") }
        precondition(switchedStore.isImporting && switchedStore.expenses.isEmpty)
        print("PASS: scrub/updated notices, successful vs failed authoritative refresh, no source replay, newer session gate preserved")
    }
}
