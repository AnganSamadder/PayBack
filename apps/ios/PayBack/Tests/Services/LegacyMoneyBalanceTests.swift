import XCTest
@testable import PayBack

@MainActor
final class LegacyMoneyBalanceTests: XCTestCase {
    private var store: AppStore!
    private var friend: GroupMember!
    private var group: SpendingGroup!
    private var expenseCloudService: MockExpenseCloudServiceForAppStore!

    override func setUp() async throws {
        try await super.setUp()
        expenseCloudService = MockExpenseCloudServiceForAppStore()
        store = AppStore(
            persistence: MockPersistenceService(),
            accountService: MockAccountServiceForAppStore(),
            expenseCloudService: expenseCloudService,
            groupCloudService: MockGroupCloudServiceForAppStore(),
            linkRequestService: MockLinkRequestServiceForAppStore(),
            inviteLinkService: MockInviteLinkServiceForTests(),
            skipClerkInit: true
        )
        friend = GroupMember(name: "Alex")
        group = SpendingGroup(name: "Shared expenses", members: [store.currentUser, friend])
        store.groups = [group]
    }

    override func tearDown() async throws {
        store = nil
        friend = nil
        group = nil
        await expenseCloudService.reset()
        expenseCloudService = nil
        try await super.tearDown()
    }

    func testMissingCurrencyInOldCacheContributesOnlyUnsettledSharesToEveryBalance() throws {
        let me = store.currentUser.id
        let first = try legacyExpense(
            description: "Groceries", paidBy: me,
            splits: [ExpenseSplit(memberId: me, amount: 60),
                     ExpenseSplit(memberId: friend.id, amount: 30),
                     ExpenseSplit(memberId: friend.id, amount: 10, isSettled: true)]
        )
        let second = try legacyExpense(
            description: "Dinner", paidBy: friend.id,
            splits: [ExpenseSplit(memberId: me, amount: 20),
                     ExpenseSplit(memberId: me, amount: 15, isSettled: true),
                     ExpenseSplit(memberId: friend.id, amount: 45)]
        )
        let settled = try legacyExpense(
            description: "Already paid", paidBy: me,
            splits: [ExpenseSplit(memberId: friend.id, amount: 300, isSettled: true)]
        )
        let source = [first, second, settled]
        store.expenses = source
        let code = Locale.current.currency?.identifier ?? "USD"

        XCTAssertEqual(store.overallNetBalanceByCurrency(), [code: 10])
        XCTAssertEqual(store.netBalanceByCurrency(in: group), [code: 10])
        XCTAssertEqual(store.balanceByCurrency(forFriend: friend), [code: 10])
        XCTAssertEqual(store.overallNetBalance(), 10)
        XCTAssertEqual(store.netBalance(for: group), 10)
        XCTAssertEqual(store.netBalance(forFriend: friend), 10)
        XCTAssertEqual(try encodedHistory(store.expenses), try encodedHistory(source), "Reading a balance must preserve raw history")
        XCTAssertTrue(store.expenses.allSatisfy { $0.currencyCode == nil })
    }

    func testLegacyDebtRetainsItsNegativeSign() throws {
        let expense = try legacyExpense(
            description: "Friend paid", paidBy: friend.id,
            splits: [ExpenseSplit(memberId: store.currentUser.id, amount: 12.50),
                     ExpenseSplit(memberId: friend.id, amount: 12.50)]
        )
        store.expenses = [expense]
        let code = Locale.current.currency?.identifier ?? "USD"
        XCTAssertEqual(store.overallNetBalanceByCurrency(), [code: -12.50])
        XCTAssertEqual(store.balanceByCurrency(forFriend: friend), [code: -12.50])
    }

    func testLegacyAndExplicitCurrenciesShareOnlyTheirDisplayCurrencyBucket() throws {
        let legacy = try legacyExpense(
            description: "Before upgrade", paidBy: store.currentUser.id,
            splits: [ExpenseSplit(memberId: friend.id, amount: 10)]
        )
        let dollars = expense(description: "New USD", amount: 3, currency: "USD")
        let euros = expense(description: "Recorded EUR", amount: 7, currency: "EUR")
        store.expenses = [legacy, dollars, euros]
        let legacyCode = Locale.current.currency?.identifier ?? "USD"
        var expected = ["USD": 3.0, "EUR": 7.0]
        expected[legacyCode, default: 0] += 10

        XCTAssertEqual(store.overallNetBalanceByCurrency(), expected)
        XCTAssertEqual(store.netBalanceByCurrency(in: group), expected)
        XCTAssertEqual(store.balanceByCurrency(forFriend: friend), expected)
        XCTAssertNil(store.expenses[0].currencyCode)
        XCTAssertEqual(store.expenses[1].currencyCode, "USD")
        XCTAssertEqual(store.expenses[2].currencyCode, "EUR")
        XCTAssertEqual(ExpenseMoneyText.overview(expected), "Multiple currencies")
    }

    func testFriendWithoutExpensesStillShowsTheExistingZeroBalanceLabel() {
        let balances = store.balanceByCurrency(forFriend: friend)
        XCTAssertTrue(balances.isEmpty)
        XCTAssertEqual(store.netBalance(forFriend: friend), 0)
        XCTAssertEqual(ExpenseMoneyText.overview(balances), "$0")
    }

    func testManyLegacyExpensesRenderOneNetAmountWithoutExpenseTitles() throws {
        store.expenses = try (0..<40).map { index in
            try legacyExpense(
                description: "Very long private expense title \(index)",
                paidBy: store.currentUser.id,
                splits: [ExpenseSplit(memberId: friend.id, amount: 1.25)]
            )
        }
        let balances = store.balanceByCurrency(forFriend: friend)
        let text = ExpenseMoneyText.overview(balances)
        let code = Locale.current.currency?.identifier ?? "USD"
        XCTAssertEqual(balances, [code: 50])
        XCTAssertEqual(text, 50.0.formatted(.currency(code: code)))
        XCTAssertFalse(text.contains("private expense"))
        XCTAssertFalse(text.contains("currency unknown"))
        XCTAssertFalse(text.contains("total:"))
    }

    func testLegacyMemberPreviewDoesNotDiscardOutstandingBalance() throws {
        store.expenses = [try legacyExpense(
            description: "Preview", paidBy: store.currentUser.id,
            splits: [ExpenseSplit(memberId: friend.id, amount: 15),
                     ExpenseSplit(memberId: friend.id, amount: 10, isSettled: true)]
        )]
        let preview = store.generateExpensePreview(forMemberId: friend.id)
        XCTAssertEqual(preview.totalBalance, -15)
        XCTAssertEqual(preview.expenseCount, 1)
    }

    func testSettledForeignHistoryDoesNotHideTheActiveLegacyBalance() throws {
        let legacy = try legacyExpense(
            description: "Outstanding", paidBy: store.currentUser.id,
            splits: [ExpenseSplit(memberId: friend.id, amount: 15)]
        )
        let legacyCode = ExpenseMoneyText.legacyCurrencyCode
        let foreignCode = legacyCode == "EUR" ? "USD" : "EUR"
        var settled = expense(description: "Already paid foreign expense", amount: 50, currency: foreignCode)
        settled.splits[0].isSettled = true
        settled.isSettled = true
        store.expenses = [settled, legacy]
        XCTAssertEqual(store.balanceByCurrency(forFriend: friend), [legacyCode: 15])
        XCTAssertEqual(store.overallNetBalanceByCurrency(), [legacyCode: 15])
        XCTAssertEqual(store.netBalanceByCurrency(in: group), [legacyCode: 15])
    }

    func testOffsettingLegacyDebtsHaveZeroNetButRemainUnsettled() throws {
        store.expenses = [
            try legacyExpense(description: "I paid", paidBy: store.currentUser.id,
                              splits: [ExpenseSplit(memberId: friend.id, amount: 10)]),
            try legacyExpense(description: "Friend paid", paidBy: friend.id,
                              splits: [ExpenseSplit(memberId: store.currentUser.id, amount: 10)])
        ]
        XCTAssertEqual(store.netBalance(forFriend: friend), 0)
        XCTAssertTrue(store.hasUnsettledBalanceExposure(forFriend: friend))
        XCTAssertTrue(store.hasUnsettledBalanceExposure(for: friend, in: group))
    }

    func testFractionalCentOffsetsDoNotBecomeTinyDebtOrExtraCurrency() throws {
        let me = store.currentUser.id
        let first = try legacyExpense(description: "Ten cents", paidBy: me,
                                      splits: [ExpenseSplit(memberId: friend.id, amount: 0.10)])
        let second = try legacyExpense(description: "Twenty cents", paidBy: me,
                                       splits: [ExpenseSplit(memberId: friend.id, amount: 0.20)])
        let third = try legacyExpense(description: "Thirty cents back", paidBy: friend.id,
                                      splits: [ExpenseSplit(memberId: me, amount: 0.30)])
        store.expenses = [first, second, third]
        XCTAssertEqual(store.netBalance(forFriend: friend), 0)
        XCTAssertEqual(store.overallNetBalance(), 0)
        XCTAssertEqual(store.netBalanceByCurrency(for: friend, in: group), [ExpenseMoneyText.legacyCurrencyCode: 0])
        XCTAssertTrue(store.hasUnsettledBalanceExposure(forFriend: friend))

        let foreignCode = ExpenseMoneyText.legacyCurrencyCode == "EUR" ? "USD" : "EUR"
        store.expenses.append(expense(description: "Foreign balance", amount: 10, currency: foreignCode))
        XCTAssertEqual(store.balanceByCurrency(forFriend: friend), [foreignCode: 10])
    }

    func testFractionalAliasRowsSumWithoutBinaryResidueAndKeepRealSubcentValues() throws {
        let me = store.currentUser.id
        store.expenses = [
            try legacyExpense(description: "Several raw rows", paidBy: me,
                              splits: [ExpenseSplit(memberId: friend.id, amount: 0.10), ExpenseSplit(memberId: friend.id, amount: 0.20)]),
            try legacyExpense(description: "Offset", paidBy: friend.id,
                              splits: [ExpenseSplit(memberId: me, amount: 0.30)])
        ]
        XCTAssertEqual(store.netBalance(forFriend: friend), 0)
        store.expenses.append(expense(description: "Real historical fraction", amount: 0.000000001, currency: ExpenseMoneyText.legacyCurrencyCode))
        XCTAssertEqual(store.netBalance(forFriend: friend), 0.000000001)
    }

    func testThirdPartyPayerDoesNotCreateDebtBetweenTwoOtherParticipants() {
        let payer = GroupMember(name: "Third participant")
        group.members.append(payer)
        store.groups = [group]
        store.expenses = [Expense(
            groupId: group.id, description: "Third participant paid", totalAmount: 15,
            paidByMemberId: payer.id, involvedMemberIds: [store.currentUser.id, friend.id, payer.id],
            splits: [ExpenseSplit(memberId: store.currentUser.id, amount: 5),
                     ExpenseSplit(memberId: friend.id, amount: 7),
                     ExpenseSplit(memberId: payer.id, amount: 3)], currencyCode: nil
        )]
        XCTAssertEqual(store.netBalance(forFriend: friend), 0)
        XCTAssertFalse(store.hasUnsettledBalanceExposure(forFriend: friend))
        XCTAssertEqual(store.netBalanceByCurrency(for: friend, in: group), [ExpenseMoneyText.legacyCurrencyCode: -7])
        XCTAssertTrue(store.hasUnsettledBalanceExposure(for: friend, in: group))
    }

    func testGroupMemberBalanceUsesTheExpenseOwnersIdentityMap() {
        let rawOther = UUID()
        let me = store.currentUser.id
        store.processFriendsUpdate([AccountFriend(memberId: friend.id, name: friend.name, aliasMemberIds: [rawOther])])
        let separate = Expense(
            groupId: group.id, description: "Owner keeps participants separate", totalAmount: 20,
            paidByMemberId: me, involvedMemberIds: [me, rawOther, friend.id],
            splits: [ExpenseSplit(memberId: rawOther, amount: 7), ExpenseSplit(memberId: friend.id, amount: 13)],
            ownerAccountId: "another-owner", currencyCode: nil,
            financialIdentityMap: [me: me, rawOther: rawOther, friend.id: friend.id]
        )
        store.expenses = [separate]
        XCTAssertTrue(store.areSamePerson(rawOther, friend.id), "The viewer has a local alias")
        XCTAssertEqual(store.netBalanceByCurrency(for: friend, in: group), [ExpenseMoneyText.legacyCurrencyCode: -13])
        XCTAssertEqual(store.balanceByCurrency(forFriend: friend), [ExpenseMoneyText.legacyCurrencyCode: 13])
        let merged = Expense(
            groupId: group.id, description: "Owner confirms equivalent participants", totalAmount: 7,
            paidByMemberId: me, involvedMemberIds: [me, rawOther, friend.id],
            splits: [ExpenseSplit(memberId: rawOther, amount: 5), ExpenseSplit(memberId: friend.id, amount: 2)],
            ownerAccountId: "another-owner", currencyCode: nil,
            financialIdentityMap: [me: me, rawOther: friend.id, friend.id: friend.id]
        )
        store.expenses.append(merged)
        XCTAssertEqual(store.netBalanceByCurrency(for: friend, in: group), [ExpenseMoneyText.legacyCurrencyCode: -20])
        XCTAssertEqual(store.balanceByCurrency(forFriend: friend), [ExpenseMoneyText.legacyCurrencyCode: 20])
    }

    func testSettlingSelectedLegacySplitPreservesTheRestOfItsRawHistory() async throws {
        let me = store.currentUser.id
        store.session = UserSession(account: UserAccount(
            id: "legacy-test-account", email: "legacy@example.test", displayName: "Legacy", linkedMemberId: me
        ))
        let alreadyPaid = ExpenseSplit(memberId: me, amount: 10, isSettled: true)
        let selected = ExpenseSplit(memberId: me, amount: 15)
        let unselected = ExpenseSplit(memberId: me, amount: 3)
        let payerShare = ExpenseSplit(memberId: friend.id, amount: 7)
        let original = try legacyExpense(description: "Legacy settlement", paidBy: friend.id,
                                         splits: [alreadyPaid, selected, unselected, payerShare])
        store.expenses = [original]
        await expenseCloudService.addExpense(original)

        try await store.settleExpenseForSplits(original, splitIds: [selected.id])

        var expected = original
        expected.splits[1].isSettled = true
        XCTAssertEqual(try encodedHistory(store.expenses), try encodedHistory([expected]))
        XCTAssertNil(store.expenses.first?.currencyCode)
        XCTAssertEqual(store.expenses.first?.splits.map(\.isSettled), [true, true, false, false])
        XCTAssertEqual(store.netBalance(forFriend: friend), -3)
    }

    private func encodedHistory(_ expenses: [Expense]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(expenses)
    }

    private func legacyExpense(description: String, paidBy: UUID, splits: [ExpenseSplit]) throws -> Expense {
        let value = Expense(
            groupId: group.id, description: description,
            totalAmount: splits.reduce(0) { $0 + $1.amount }, paidByMemberId: paidBy,
            involvedMemberIds: [store.currentUser.id, friend.id], splits: splits,
            isSettled: splits.allSatisfy(\.isSettled), currencyCode: nil
        )
        let encoded = try JSONEncoder().encode(value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["currencyCode"], "Fixture must represent a pre-currency cache record")
        let decoded = try JSONDecoder().decode(Expense.self, from: encoded)
        XCTAssertNil(decoded.currencyCode)
        return decoded
    }

    private func expense(description: String, amount: Double, currency: String) -> Expense {
        Expense(
            groupId: group.id, description: description, totalAmount: amount,
            paidByMemberId: store.currentUser.id,
            involvedMemberIds: [store.currentUser.id, friend.id],
            splits: [ExpenseSplit(memberId: friend.id, amount: amount)], currencyCode: currency
        )
    }
}
