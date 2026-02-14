import XCTest
@testable import PayBack

final class ExpenseModelTests: XCTestCase {

    func testExpenseCreation() {
        let expenseId = UUID()
        let groupId = UUID()
        let payerId = UUID()
        let member1 = UUID()
        let member2 = UUID()

        let split1 = ExpenseSplit(memberId: member1, amount: 25.0)
        let split2 = ExpenseSplit(memberId: member2, amount: 25.0)

        let expense = Expense(
            id: expenseId,
            groupId: groupId,
            description: "Dinner",
            date: Date(),
            totalAmount: 50.0,
            paidByMemberId: payerId,
            involvedMemberIds: [member1, member2],
            splits: [split1, split2],
            isSettled: false,
            participantNames: nil
        )

        XCTAssertEqual(expense.id, expenseId)
        XCTAssertEqual(expense.groupId, groupId)
        XCTAssertEqual(expense.totalAmount, 50.0)
        XCTAssertEqual(expense.description, "Dinner")
        XCTAssertEqual(expense.paidByMemberId, payerId)
        XCTAssertEqual(expense.involvedMemberIds.count, 2)
        XCTAssertEqual(expense.splits.count, 2)
        XCTAssertFalse(expense.isSettled)
    }

    func testExpenseSplitCreation() {
        let memberId = UUID()
        let split = ExpenseSplit(memberId: memberId, amount: 50.0, isSettled: false)

        XCTAssertEqual(split.memberId, memberId)
        XCTAssertEqual(split.amount, 50.0)
        XCTAssertFalse(split.isSettled)
    }

    func testExpenseSplitSettlement() {
        let memberId = UUID()
        var split = ExpenseSplit(memberId: memberId, amount: 50.0, isSettled: false)

        XCTAssertFalse(split.isSettled)
        split.isSettled = true
        XCTAssertTrue(split.isSettled)
    }

    func testExpenseWithParticipantNames() {
        let member1 = UUID()
        let member2 = UUID()
        let participantNames = [member1: "Alice", member2: "Bob"]

        let expense = Expense(
            id: UUID(),
            groupId: UUID(),
            description: "Lunch",
            date: Date(),
            totalAmount: 100.0,
            paidByMemberId: member1,
            involvedMemberIds: [member1, member2],
            splits: [
                ExpenseSplit(memberId: member1, amount: 50.0),
                ExpenseSplit(memberId: member2, amount: 50.0)
            ],
            isSettled: false,
            participantNames: participantNames
        )

        XCTAssertNotNil(expense.participantNames)
        XCTAssertEqual(expense.participantNames?[member1], "Alice")
        XCTAssertEqual(expense.participantNames?[member2], "Bob")
    }

    func testExpenseSettlement() {
        var expense = Expense(
            id: UUID(),
            groupId: UUID(),
            description: "Test",
            date: Date(),
            totalAmount: 100.0,
            paidByMemberId: UUID(),
            involvedMemberIds: [UUID()],
            splits: [ExpenseSplit(memberId: UUID(), amount: 100.0)],
            isSettled: false,
            participantNames: nil
        )

        XCTAssertFalse(expense.isSettled)
        expense.isSettled = true
        XCTAssertTrue(expense.isSettled)
    }

    func testGroupMemberCreation() {
        let memberId = UUID()
        let member = GroupMember(id: memberId, name: "Alice")

        XCTAssertEqual(member.id, memberId)
        XCTAssertEqual(member.name, "Alice")
    }

    func testGroupMemberEquality() {
        let memberId = UUID()
        let member1 = GroupMember(id: memberId, name: "Alice")
        let member2 = GroupMember(id: memberId, name: "Alice Updated")

        XCTAssertEqual(member1, member2)
    }

    func testSpendingGroupCreation() {
        let groupId = UUID()
        let member1 = GroupMember(name: "Alice")
        let member2 = GroupMember(name: "Bob")
        let createdDate = Date()

        let group = SpendingGroup(
            id: groupId,
            name: "Trip to Paris",
            members: [member1, member2],
            createdAt: createdDate,
            isDirect: false
        )

        XCTAssertEqual(group.id, groupId)
        XCTAssertEqual(group.name, "Trip to Paris")
        XCTAssertEqual(group.members.count, 2)
        XCTAssertEqual(group.createdAt, createdDate)
        XCTAssertEqual(group.isDirect, false)
    }

    func testSpendingGroupDirectFlag() {
        let directGroup = SpendingGroup(
            name: "Direct Payment",
            members: [],
            isDirect: true
        )

        XCTAssertEqual(directGroup.isDirect, true)
    }
}
