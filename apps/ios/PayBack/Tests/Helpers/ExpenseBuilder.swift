import Foundation
@testable import PayBack

/// Builder pattern for creating test Expense objects
class ExpenseBuilder {
    private var id: UUID = UUID()
    private var groupId: UUID = UUID()
    private var description: String = "Test Expense"
    private var date: Date = Date()
    private var totalAmount: Double = 100.0
    private var paidByMemberId: UUID = UUID()
    private var involvedMemberIds: [UUID] = []
    private var splits: [ExpenseSplit] = []
    private var isSettled: Bool = false
    private var participantNames: [UUID: String]? = nil
    
    func withId(_ id: UUID) -> ExpenseBuilder {
        self.id = id
        return self
    }
    
    func withGroupId(_ groupId: UUID) -> ExpenseBuilder {
        self.groupId = groupId
        return self
    }
    
    func withDescription(_ description: String) -> ExpenseBuilder {
        self.description = description
        return self
    }
    
    func withDate(_ date: Date) -> ExpenseBuilder {
        self.date = date
        return self
    }
    
    func withTotalAmount(_ amount: Double) -> ExpenseBuilder {
        self.totalAmount = amount
        return self
    }
    
    func withPaidBy(_ memberId: UUID) -> ExpenseBuilder {
        self.paidByMemberId = memberId
        return self
    }
    
    func withMembers(_ memberIds: [UUID]) -> ExpenseBuilder {
        self.involvedMemberIds = memberIds
        return self
    }
    
    func withSplits(_ splits: [ExpenseSplit]) -> ExpenseBuilder {
        self.splits = splits
        return self
    }
    
    func withIsSettled(_ isSettled: Bool) -> ExpenseBuilder {
        self.isSettled = isSettled
        return self
    }
    
    func withParticipantNames(_ names: [UUID: String]) -> ExpenseBuilder {
        self.participantNames = names
        return self
    }
    
    /// Creates equal splits for all involved members
    func withEqualSplits() -> ExpenseBuilder {
        // If no members set, create a default member
        if involvedMemberIds.isEmpty {
            let defaultMember = UUID()
            involvedMemberIds = [defaultMember]
            paidByMemberId = defaultMember
        }
        
        let splitAmount = totalAmount / Double(involvedMemberIds.count)
        self.splits = involvedMemberIds.map { memberId in
            ExpenseSplit(memberId: memberId, amount: splitAmount, isSettled: false)
        }
        return self
    }
    
    func build() -> Expense {
        // Ensure we have at least one member
        if involvedMemberIds.isEmpty {
            involvedMemberIds = [paidByMemberId]
        }
        
        // Ensure we have splits
        if splits.isEmpty {
            let splitAmount = totalAmount / Double(involvedMemberIds.count)
            splits = involvedMemberIds.map { memberId in
                ExpenseSplit(memberId: memberId, amount: splitAmount, isSettled: false)
            }
        }
        
        return Expense(
            id: id,
            groupId: groupId,
            description: description,
            date: date,
            totalAmount: totalAmount,
            paidByMemberId: paidByMemberId,
            involvedMemberIds: involvedMemberIds,
            splits: splits,
            isSettled: isSettled,
            participantNames: participantNames
        )
    }
}
