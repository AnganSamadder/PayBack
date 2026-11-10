import XCTest
@testable import PayBack

final class ExpenseMoneyContractTests: XCTestCase {
    private let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let c = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    func testAllModesConserveIntegerCentsAndIgnoreInputOrder() throws {
        for weights in [[a: 1.0, b: 1, c: 1], [a: 33.3, b: 33.3, c: 33.4], [a: 2, b: 3, c: 7], [a: 1.25, b: 5.12, c: 2.68], [a: 0, b: 5, c: 0]] {
            for total in [0.01, 0.02, 1, 10.01, 999_999_999.99, 1_000_000_000] {
                let result = try ExpenseMoneyLogic.allocate(total: total, weights: weights)
                let reverse = Dictionary(uniqueKeysWithValues: weights.sorted { $0.key.uuidString > $1.key.uuidString }.map { ($0.key, $0.value) })
                XCTAssertEqual(result, try ExpenseMoneyLogic.allocate(total: total, weights: reverse))
                XCTAssertEqual(result.values.compactMap(ExpenseMoneyLogic.cents).reduce(0, +), ExpenseMoneyLogic.cents(total))
                XCTAssertTrue(result.values.allSatisfy { $0 >= 0 })
            }
        }
        XCTAssertEqual(try ExpenseMoneyLogic.allocate(total: 10, weights: [c: 1, b: 1, a: 1]), [a: 3.34, b: 3.33, c: 3.33])
        XCTAssertEqual(try ExpenseMoneyLogic.allocate(total: 0.01, weights: [c: 1, b: 1, a: 1]), [a: 0.01, b: 0, c: 0])
    }

    func testInvalidTotalsWeightsAndUnbalancedAdjustmentsReject() throws {
        for total in [Double.nan, .infinity, -1, 0, 0.001, 1_000_000_000.01] {
            XCTAssertThrowsError(try ExpenseMoneyLogic.allocate(total: total, weights: [a: 1]))
        }
        for weights in [[a: -1.0], [a: Double.nan], [a: Double.infinity], [a: 0.0]] {
            XCTAssertThrowsError(try ExpenseMoneyLogic.allocate(total: 10, weights: weights))
        }
        for adjustments in [[a: 1.0], [a: 0.001, b: -0.001], [a: -6, b: 6], [c: 1]] {
            XCTAssertThrowsError(try ExpenseMoneyLogic.allocate(total: 10, weights: [a: 1, b: 1], adjustments: adjustments))
        }
        XCTAssertEqual(try ExpenseMoneyLogic.allocate(total: 10, weights: [a: 1, b: 1], adjustments: [a: -1, b: 1]), [a: 4, b: 6])
    }

    func testUnknownCurrencyDecodeDoesNotGuessAndKnownRoundTrips() throws {
        let expense = sample(currency: nil)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let restored = try decoder.decode(Expense.self, from: encoder.encode(expense))
        XCTAssertNil(restored.currencyCode)
        XCTAssertEqual(restored.splits, expense.splits)
        XCTAssertEqual(try decoder.decode(Expense.self, from: encoder.encode(sample(currency: "EUR"))).currencyCode, "EUR")
        XCTAssertNil(ExpenseMoneyText.singleKnownCurrency(in: [expense]))
        XCTAssertNil(ExpenseMoneyText.singleKnownCurrency(in: [sample(currency: "USD"), sample(currency: "EUR")]))
        XCTAssertEqual(ExpenseMoneyText.singleKnownCurrency(in: [sample(currency: "EUR")]), "EUR")
        XCTAssertTrue(ExpenseMoneyText.format(0.000000001, currencyCode: "USD").contains("000000001"))
        let encodedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(restored)) as? [String: Any])
        XCTAssertNil(encodedObject["currencyCode"], "Display compatibility must not invent stored currency metadata")
    }

    func testLegacyAmountsKeepTheEstablishedCurrencyPresentation() {
        let expense = sample(currency: nil)
        let legacyCurrency = Locale.current.currency?.identifier ?? "USD"
        XCTAssertEqual(expense.displayCurrencyCode, legacyCurrency)
        XCTAssertEqual(ExpenseMoneyText.format(25, currencyCode: nil), 25.0.formatted(.currency(code: legacyCurrency)))
        XCTAssertNil(expense.currencyCode)
    }

    func testExplicitCurrencyOverridesTheLegacyDisplayFallback() {
        XCTAssertEqual(sample(currency: "USD").displayCurrencyCode, "USD")
        XCTAssertEqual(sample(currency: "EUR").displayCurrencyCode, "EUR")
        XCTAssertEqual(ExpenseMoneyText.format(12.50, currencyCode: "EUR"), 12.50.formatted(.currency(code: "EUR")))
    }

    func testLegacySelectionAcceptsTheMatchingDisplayCurrencyButKeepsForeignCurrencySeparate() {
        let legacy = sample(currency: nil)
        let currentCurrency = Locale.current.currency?.identifier ?? "USD"
        let foreignCurrency = currentCurrency == "EUR" ? "USD" : "EUR"
        XCTAssertEqual(ExpenseMoneyText.singleDisplayCurrency(in: [legacy]), currentCurrency)
        XCTAssertEqual(ExpenseMoneyText.singleDisplayCurrency(in: [legacy, sample(currency: currentCurrency)]), currentCurrency)
        XCTAssertNil(ExpenseMoneyText.singleDisplayCurrency(in: [legacy, sample(currency: foreignCurrency)]))
        XCTAssertNil(ExpenseMoneyText.singleDisplayCurrency(in: []))
        XCTAssertNil(ExpenseMoneyText.singleKnownCurrency(in: [legacy]))
        XCTAssertNil(legacy.currencyCode)
    }

    func testHistoricalFractionsSurviveCurrencySpecificMinorUnitFormatting() throws {
        for (code, amount) in [("JPY", 0.5), ("TND", 1.234), ("EUR", 0.000000001), ("USD", -0.001)] {
            let text = ExpenseMoneyText.format(amount, currencyCode: code)
            let parsed = try FloatingPointFormatStyle<Double>.Currency(code: code).parseStrategy.parse(text)
            XCTAssertEqual(parsed, amount, "Historical \(code) amount must not be rounded away: \(text)")
        }
    }

    func testLegacyPaymentBreakdownUsesUnsettledSharesAndRejectsMixedDisplayCurrencies() {
        let legacy = sample(currency: nil)
        let recipients = ExpensePaymentBreakdown.recipients(
            expenses: [legacy], isCurrentUser: { id, _ in id == self.a },
            resolveMember: { GroupMember(id: $0, name: "Payer") },
            participantName: { _, _ in "Payer" }
        )
        XCTAssertEqual(recipients.count, 1)
        XCTAssertEqual(recipients.first?.id, b)
        XCTAssertEqual(recipients.first?.amount, 15)
        let foreign = ExpenseMoneyText.legacyCurrencyCode == "EUR" ? "USD" : "EUR"
        XCTAssertTrue(ExpensePaymentBreakdown.recipients(
            expenses: [legacy, sample(currency: foreign)], isCurrentUser: { id, _ in id == self.a },
            resolveMember: { GroupMember(id: $0, name: "Payer") },
            participantName: { _, _ in "Payer" }
        ).isEmpty)
        XCTAssertNil(legacy.currencyCode)
    }

    func testBalanceOverviewKeepsEmptySingleAndMixedCurrencyLabelsCompact() {
        XCTAssertEqual(ExpenseMoneyText.overview([:]), "$0")
        XCTAssertEqual(ExpenseMoneyText.overview(["USD": 25]), 25.0.formatted(.currency(code: "USD")))
        XCTAssertEqual(ExpenseMoneyText.overview(["EUR": 5, "USD": 10]), "Multiple currencies")
        XCTAssertEqual(ExpenseMoneyText.overview(["EUR": 0, "USD": 0]), "$0")
    }

    func testMixedRowsStayStableAndStatusIncludesEveryRowInEitherOrder() {
        var expense = sample(currency: nil)
        let rows = expense.splits
        XCTAssertFalse(expense.isSettled(for: a))
        XCTAssertEqual(expense.split(for: a)?.amount, 25)
        XCTAssertEqual(expense.splits, rows)
        expense.splits.reverse()
        XCTAssertFalse(expense.isSettled(for: a))
        XCTAssertEqual(expense.split(for: a)?.amount, 25)
    }

    func testSelectionIncludesEveryAliasRowWithoutMutatingHistory() {
        let settled = ExpenseSplit(memberId: a, amount: 10, isSettled: true)
        let unpaid = ExpenseSplit(memberId: b, amount: 15, isSettled: false)
        let unrelated = ExpenseSplit(memberId: c, amount: 3, isSettled: false)
        let rows = [settled, unpaid, unrelated]
        let aliases: (UUID, UUID) -> Bool = { left, right in
            left == right || (left != self.c && right != self.c)
        }
        for ordered in [rows, rows.reversed().map { $0 }] {
            let settling = ExpenseSettlementSelection.summaries(rows: ordered, selectingSettled: false, equivalent: aliases)
            let undoing = ExpenseSettlementSelection.summaries(rows: ordered, selectingSettled: true, equivalent: aliases)
            XCTAssertEqual(settling.count, 2)
            XCTAssertEqual(settling.first { $0.memberId != c }?.amount, 15)
            XCTAssertEqual(settling.first { $0.memberId != c }?.splitIds, [unpaid.id])
            XCTAssertEqual(undoing.first { $0.memberId != c }?.amount, 10)
            XCTAssertEqual(undoing.first { $0.memberId != c }?.splitIds, [settled.id])
        }
        XCTAssertEqual(rows, [settled, unpaid, unrelated])
    }

    func testSelectionAmountAlwaysCarriesExactlyItsRawSplitIds() {
        let first = ExpenseSplit(memberId: a, amount: 10)
        let second = ExpenseSplit(memberId: b, amount: 15)
        let separate = ExpenseSettlementSelection.summaries(rows: [first, second], selectingSettled: false, equivalent: ==)
        XCTAssertEqual(separate.count, 2)
        XCTAssertEqual(separate.first { $0.memberId == a }?.amount, 10)
        XCTAssertEqual(separate.first { $0.memberId == a }?.splitIds, [first.id])
        let merged = ExpenseSettlementSelection.summaries(rows: [second, first], selectingSettled: false, equivalent: { _, _ in true })
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.amount, 25)
        XCTAssertEqual(merged.first?.splitIds, [first.id, second.id])
    }

    func testTrustedExpenseCachePreservesFinancialIdentityProjectionAndRawRows() throws {
        let expense = Expense(groupId: UUID(), description: "Shared", totalAmount: 10, paidByMemberId: a, involvedMemberIds: [a, b], splits: [ExpenseSplit(memberId: b, amount: 10)], financialIdentityMap: [a: a, b: c])
        let encoded = try JSONEncoder().encode(expense)
        let restored = try JSONDecoder().decode(Expense.self, from: encoded)
        XCTAssertEqual(restored.financialIdentityMap, [a: a, b: c])
        XCTAssertEqual(restored.splits, expense.splits)
        XCTAssertEqual(restored.totalAmount, expense.totalAmount)
        let legacy = try JSONDecoder().decode(Expense.self, from: JSONEncoder().encode(sample(currency: nil)))
        XCTAssertNil(legacy.financialIdentityMap)
    }

    func testPaymentBreakdownKeepsCanonicalRecipientWhenOnlyRawPayerNameIsKnown() {
        let first = Expense(groupId: UUID(), description: "Shared", totalAmount: 10, paidByMemberId: a, involvedMemberIds: [a, c], splits: [ExpenseSplit(memberId: c, amount: 10)], participantNames: [a: "Bob"], financialIdentityMap: [a: b, c: c])
        let second = Expense(groupId: first.groupId, description: "Later", totalAmount: 15, paidByMemberId: b, involvedMemberIds: [b, c], splits: [ExpenseSplit(memberId: c, amount: 15)], participantNames: [b: "Bob"], financialIdentityMap: [b: b, c: c])
        let rows = ExpensePaymentBreakdown.recipients(
            expenses: [first, second], isCurrentUser: { id, _ in id == self.c },
            resolveMember: { _ in nil },
            participantName: { id, expense in expense.participantNames?[id] ?? "Unknown" }
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, b)
        XCTAssertEqual(rows.first?.member.name, "Bob")
        XCTAssertEqual(rows.first?.amount, 25)
    }

    func testPaymentBreakdownDoesNotUseDirectoryAliasesAsFinancialGrouping() {
        let first = Expense(groupId: UUID(), description: "First", totalAmount: 10, paidByMemberId: a, involvedMemberIds: [a, c], splits: [ExpenseSplit(memberId: c, amount: 10)])
        let second = Expense(groupId: first.groupId, description: "Second", totalAmount: 15, paidByMemberId: b, involvedMemberIds: [b, c], splits: [ExpenseSplit(memberId: c, amount: 15)])
        let displayMember = GroupMember(id: a, name: "My local nickname")
        let rows = ExpensePaymentBreakdown.recipients(
            expenses: [first, second], isCurrentUser: { id, _ in id == self.c },
            resolveMember: { _ in displayMember }, participantName: { _, _ in "Unused" }
        )
        XCTAssertEqual(Set(rows.map(\.id)), [a, b])
        XCTAssertEqual(rows.map(\.amount).reduce(0, +), 25)
    }

    func testAuthoringDraftCanonicalizesAndDeduplicatesOnlyServerProjectedMembers() throws {
        let placeholder = GroupMember(id: a, name: "Old Bob", isCurrentUser: true)
        let canonical = GroupMember(id: b, name: "Bob")
        let other = GroupMember(id: c, name: "Charlie")
        let group = SpendingGroup(name: "Shared", members: [placeholder, canonical, other], memberIdentityMap: [a: b, b: b, c: c])
        let cached = try JSONDecoder().decode(SpendingGroup.self, from: JSONEncoder().encode(group))
        XCTAssertEqual(cached.memberIdentityMap, group.memberIdentityMap)
        XCTAssertEqual(cached.members.map(\.id), [a, b, c])
        let draft = ExpenseAuthoringGroupProjection.draft(from: cached)
        XCTAssertEqual(draft.id, group.id)
        XCTAssertEqual(draft.members.map(\.id), [b, c])
        XCTAssertEqual(draft.members.first?.name, "Bob")
        XCTAssertTrue(draft.members.allSatisfy { $0.isCurrentUser == nil })
        XCTAssertEqual(group.members.map(\.id), [a, b, c])
        XCTAssertEqual(group.members.first?.name, "Old Bob")
        let allocated = try ExpenseMoneyLogic.allocate(total: 10, weights: Dictionary(uniqueKeysWithValues: draft.members.map { ($0.id, 1.0) }))
        XCTAssertEqual(allocated, [b: 5, c: 5])
    }

    func testAuthoringDraftWithoutProjectionDoesNotMergeSameNameOrTrustCreatorFlag() throws {
        let group = SpendingGroup(name: "Legacy", members: [GroupMember(id: a, name: "Bob", isCurrentUser: true), GroupMember(id: b, name: "Bob")])
        let cached = try JSONDecoder().decode(SpendingGroup.self, from: JSONEncoder().encode(group))
        XCTAssertNil(cached.memberIdentityMap)
        let draft = ExpenseAuthoringGroupProjection.draft(from: cached)
        XCTAssertEqual(draft.members.map(\.id), [a, b])
        XCTAssertTrue(draft.members.allSatisfy { $0.isCurrentUser == nil })
    }

    private func sample(currency: String?) -> Expense {
        Expense(groupId: UUID(), description: "History", totalAmount: 25, paidByMemberId: b, involvedMemberIds: [a, b], splits: [ExpenseSplit(memberId: a, amount: 10, isSettled: true), ExpenseSplit(memberId: a, amount: 15)], currencyCode: currency)
    }
}
