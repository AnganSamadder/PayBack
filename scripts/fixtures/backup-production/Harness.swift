import Foundation

protocol AccountService {
    func bulkImport(request: BulkImportRequest) async throws -> BulkImportResult
}
struct FakeAccountService: AccountService {
    func bulkImport(request: BulkImportRequest) async throws -> BulkImportResult {
        precondition(request.expected_account_id == "account")
        precondition(request.financial_contract_version == 2)
        // The server has already seen this expense, or retained its clear suppression.
        let partial = request.expenses.first?.description == "Partial restore"
        return BulkImportResult(success: !partial, created: .init(friends: 0, groups: 0, expenses: 0),
            errors: partial ? ["One row could not be restored"] : [])
    }
}
struct Dependencies { static let current = Dependencies(); let accountService: AccountService = FakeAccountService() }
@MainActor final class AppStore {
    var dataEpoch = 0
    struct Session { var account: Account }
    struct Account { var id: String; var email: String }
    var session: Session? = Session(account: Account(id: "account", email: "review@example.test"))
    var isImporting = false
    var currentUser: GroupMember
    var friends: [AccountFriend] = []
    var groups: [SpendingGroup] = []
    var expenses: [Expense] = []
    var refreshCount = 0
    var switchSessionDuringRefresh = false
    init(currentUser: GroupMember) { self.currentUser = currentUser }
    func loadRemoteData() async {
        precondition(!isImporting)
        refreshCount += 1
        expenses = [] // The authoritative snapshot keeps the cleared expense hidden.
        if switchSessionDuringRefresh {
            dataEpoch += 1
            session = Session(account: Account(id: "new-account", email: "new@example.test"))
            isImporting = true // A new session's import gate must not be cleared by the old defer.
        }
    }
}
@main struct Proof {
    @MainActor static func main() async throws {
        let owner = GroupMember(name: "Owner")
        let photo = "https://example.test/group-participant.png"
        let groupParticipant = GroupMember(name: "Group participant", profileImageUrl: photo)
        let group = SpendingGroup(name: "Trip", members: [owner, groupParticipant])
        let photoBackup = DataExportService.exportAllData(groups: [group], expenses: [], friends: [], currentUser: owner, accountEmail: "review@example.test")
        let photoRequest = DataImportService.convertToBulkImportRequest(from: try DataImportService.parseExport(photoBackup))
        let photoJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(photoRequest.groups[0])) as! [String: Any]
        let photoRows = photoJSON["members"] as! [[String: Any]]
        let photoRow = photoRows.first { $0["id"] as? String == groupParticipant.id.uuidString }!
        precondition(photoRow["profile_image_url"] as? String == photo)
        precondition(photoRequest.friends.isEmpty)
        print("Group-only participant photo retained in wire payload without friend promotion: PASS")
        let expense = Expense(groupId: UUID(), description: "Cleared old expense", totalAmount: 10,
            paidByMemberId: owner.id, involvedMemberIds: [owner.id],
            splits: [ExpenseSplit(memberId: owner.id, amount: 10)], contextKind: .groupedIndividual, currencyCode: nil)
        let backup = DataExportService.exportAllData(groups: [], expenses: [expense], friends: [], currentUser: owner, accountEmail: "review@example.test")
        let store = AppStore(currentUser: owner)
        let result = await DataImportService.importData(from: backup, into: store)
        guard case .success(let summary) = result else { preconditionFailure("Unexpected result") }
        precondition(summary.expensesAdded == 0)
        precondition(store.refreshCount == 1)
        precondition(store.expenses.isEmpty)
        precondition(!store.isImporting)
        let partialStore = AppStore(currentUser: owner)
        let partial = await DataImportService.importData(from: backup.replacingOccurrences(of: "Cleared old expense", with: "Partial restore"), into: partialStore)
        guard case .partialSuccess = partial else { preconditionFailure("Expected partial import") }
        precondition(partialStore.refreshCount == 1 && partialStore.expenses.isEmpty && !partialStore.isImporting)
        let switchingStore = AppStore(currentUser: owner)
        switchingStore.switchSessionDuringRefresh = true
        let switched = await DataImportService.importData(from: backup, into: switchingStore)
        guard case .incompatibleFormat = switched else { preconditionFailure("Expected stale session result rejection") }
        precondition(switchingStore.expenses.isEmpty && switchingStore.isImporting)
        print("PRODUCTION branch: skipped/suppressed rows remain absent; complete refresh runs after gate cleared; server counts retained: PASS")
    }
}
