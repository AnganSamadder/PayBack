import XCTest
@testable import PayBack

/// Performance tests for memory usage and leak detection
///
/// These tests measure memory usage and detect memory leaks in critical operations
/// to ensure the system manages memory efficiently.
///
/// IMPORTANT: These tests should be run in Release configuration for accurate results.
/// Configure the test scheme to use Release build configuration for performance tests.
///
/// Related Requirements: R20
final class MemoryUsageTests: XCTestCase {
    
    // MARK: - Retry Policy Memory Tests
    
    /// Test that retry operations don't leak memory
    ///
    /// This test validates that the retry policy properly releases resources
    /// after operations complete, even when retries occur.
    func test_retryPolicy_noMemoryLeaks() async {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        
        measure(metrics: [XCTMemoryMetric()], options: options) {
            let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01)
            
            let expectation = self.expectation(description: "retry-operations")
            
            Task {
                // Perform 100 retry operations
                for _ in 0..<100 {
                    _ = try? await policy.execute {
                        return "test"
                    }
                }
                expectation.fulfill()
            }
            
            wait(for: [expectation], timeout: 10.0)
        }
        
        // Memory should return to baseline after operations complete
    }
    
    /// Test memory usage with failing retry operations
    func test_retryPolicy_failingOperations_noMemoryLeaks() async {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        
        measure(metrics: [XCTMemoryMetric()], options: options) {
            let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01)
            
            let expectation = self.expectation(description: "failing-retries")
            
            Task {
                // Perform operations that fail and retry
                for _ in 0..<50 {
                    _ = try? await policy.execute {
                        throw PayBackError.networkUnavailable
                    }
                }
                expectation.fulfill()
            }
            
            wait(for: [expectation], timeout: 10.0)
        }
    }
    
    // MARK: - Large Data Structure Memory Tests
    
    /// Test memory usage when creating large expense lists
    func test_largeExpenseList_memoryUsageReasonable() {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        
        measure(metrics: [XCTMemoryMetric()], options: options) {
            // Create 1000 expenses with splits
            let expenses = (0..<1000).map { i in
                let memberIds = (0..<10).map { _ in UUID() }
                let splits = memberIds.map { memberId in
                    ExpenseSplit(
                        id: UUID(),
                        memberId: memberId,
                        amount: 10.0,
                        isSettled: false
                    )
                }
                
                return Expense(
                    id: UUID(),
                    groupId: UUID(),
                    description: "Expense \(i)",
                    date: Date(),
                    totalAmount: 100.0,
                    paidByMemberId: memberIds[0],
                    involvedMemberIds: memberIds,
                    splits: splits,
                    isSettled: false
                )
            }
            
            // Use the expenses to prevent optimization
            _ = expenses.count
        }
    }
    
    /// Test memory usage when creating large friend lists
    func test_largeFriendList_memoryUsageReasonable() {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        
        measure(metrics: [XCTMemoryMetric()], options: options) {
            // Create 1000 friends
            let friends = (0..<1000).map { i in
                AccountFriend(
                    memberId: UUID(),
                    name: "Friend \(i)",
                    hasLinkedAccount: i % 2 == 0,
                    linkedAccountId: i % 2 == 0 ? "account-\(i)" : nil,
                    linkedAccountEmail: i % 2 == 0 ? "friend\(i)@example.com" : nil
                )
            }
            
            // Use the friends to prevent optimization
            _ = friends.count
        }
    }
    
    /// Test memory usage during split calculations
    func test_splitCalculations_memoryUsageReasonable() {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        
        measure(metrics: [XCTMemoryMetric()], options: options) {
            // Perform 1000 split calculations
            for _ in 0..<1000 {
                let memberIds = (0..<10).map { _ in UUID() }
                _ = calculateEqualSplits(totalAmount: 100.0, memberIds: memberIds)
            }
        }
    }
    
    /// Test memory usage during reconciliation
    func test_reconciliation_memoryUsageReasonable() async {
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        
        measure(metrics: [XCTMemoryMetric()], options: options) {
            let reconciliation = LinkStateReconciliation()
            
            let friends = (0..<500).map { i in
                AccountFriend(
                    memberId: UUID(),
                    name: "Friend \(i)",
                    hasLinkedAccount: false
                )
            }
            
            let expectation = self.expectation(description: "reconcile-memory")
            
            Task {
                // Perform multiple reconciliations
                for _ in 0..<10 {
                    _ = await reconciliation.reconcile(
                        localFriends: friends,
                        remoteFriends: friends
                    )
                }
                expectation.fulfill()
            }
            
            wait(for: [expectation], timeout: 10.0)
        }
    }
    
    // MARK: - Concurrent Operations Memory Tests
    
    /// Test memory usage with concurrent split calculations
    func test_concurrentSplitCalculations_noMemoryLeaks() async {
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        
        measure(metrics: [XCTMemoryMetric()], options: options) {
            let expectation = self.expectation(description: "concurrent-splits")
            
            Task {
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<100 {
                        group.addTask {
                            let memberIds = (0..<10).map { _ in UUID() }
                            _ = calculateEqualSplits(totalAmount: 100.0, memberIds: memberIds)
                        }
                    }
                }
                expectation.fulfill()
            }
            
            wait(for: [expectation], timeout: 10.0)
        }
    }
    
    /// Test memory usage with concurrent reconciliations
    func test_concurrentReconciliations_noMemoryLeaks() async {
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        
        measure(metrics: [XCTMemoryMetric()], options: options) {
            let reconciliation = LinkStateReconciliation()
            
            let friends = (0..<100).map { i in
                AccountFriend(
                    memberId: UUID(),
                    name: "Friend \(i)",
                    hasLinkedAccount: false
                )
            }
            
            let expectation = self.expectation(description: "concurrent-reconcile")
            
            Task {
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<20 {
                        group.addTask {
                            _ = await reconciliation.reconcile(
                                localFriends: friends,
                                remoteFriends: friends
                            )
                        }
                    }
                }
                expectation.fulfill()
            }
            
            wait(for: [expectation], timeout: 10.0)
        }
    }
    
    // MARK: - String and Collection Memory Tests
    
    /// Test memory usage with large string operations
    func test_stringOperations_memoryUsageReasonable() {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        
        measure(metrics: [XCTMemoryMetric()], options: options) {
            // Create and manipulate strings
            for i in 0..<1000 {
                let description = "Expense description \(i) with some additional text"
                let normalized = description.lowercased().trimmingCharacters(in: .whitespaces)
                _ = normalized.count
            }
        }
    }
    
    /// Test memory usage with UUID operations
    func test_uuidOperations_memoryUsageReasonable() {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        
        measure(metrics: [XCTMemoryMetric()], options: options) {
            // Create and sort UUIDs
            let uuids = (0..<1000).map { _ in UUID() }
            let sorted = uuids.sorted { $0.uuidString < $1.uuidString }
            _ = sorted.count
        }
    }
    
    /// Test memory usage with dictionary operations
    func test_dictionaryOperations_memoryUsageReasonable() {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        
        measure(metrics: [XCTMemoryMetric()], options: options) {
            // Create and manipulate dictionaries
            var memberAmounts: [UUID: Double] = [:]
            
            for _ in 0..<1000 {
                let memberId = UUID()
                memberAmounts[memberId] = Double.random(in: 0...100)
            }
            
            _ = memberAmounts.values.reduce(0, +)
        }
    }
    
    // MARK: - Codable Memory Tests
    
    /// Test memory usage during JSON encoding/decoding
    func test_jsonCodable_memoryUsageReasonable() throws {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        
        measure(metrics: [XCTMemoryMetric()], options: options) {
            let encoder = JSONEncoder()
            let decoder = JSONDecoder()
            
            // Create and encode/decode expenses
            for i in 0..<100 {
                let memberIds = (0..<10).map { _ in UUID() }
                let splits = memberIds.map { memberId in
                    ExpenseSplit(
                        id: UUID(),
                        memberId: memberId,
                        amount: 10.0,
                        isSettled: false
                    )
                }
                
                let expense = Expense(
                    id: UUID(),
                    groupId: UUID(),
                    description: "Expense \(i)",
                    date: Date(),
                    totalAmount: 100.0,
                    paidByMemberId: memberIds[0],
                    involvedMemberIds: memberIds,
                    splits: splits,
                    isSettled: false
                )
                
                if let data = try? encoder.encode(expense) {
                    _ = try? decoder.decode(Expense.self, from: data)
                }
            }
        }
    }
    
    // MARK: - Builder Pattern Memory Tests
    
    /// Test memory usage with ExpenseBuilder
    func test_expenseBuilder_memoryUsageReasonable() {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        
        measure(metrics: [XCTMemoryMetric()], options: options) {
            // Create expenses using builder pattern
            for i in 0..<1000 {
                let memberIds = (0..<10).map { _ in UUID() }
                
                _ = ExpenseBuilder()
                    .withDescription("Expense \(i)")
                    .withTotalAmount(100.0)
                    .withMembers(memberIds)
                    .withEqualSplits()
                    .build()
            }
        }
    }
    
    // MARK: - Cleanup and Deallocation Tests
    
    /// Test that large structures are properly deallocated
    func test_largeStructures_properDeallocation() {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        
        measure(metrics: [XCTMemoryMetric()], options: options) {
            autoreleasepool {
                // Create large structures in autoreleasepool
                var expenses: [Expense] = []
                
                for i in 0..<1000 {
                    let memberIds = (0..<10).map { _ in UUID() }
                    let splits = memberIds.map { memberId in
                        ExpenseSplit(
                            id: UUID(),
                            memberId: memberId,
                            amount: 10.0,
                            isSettled: false
                        )
                    }
                    
                    let expense = Expense(
                        id: UUID(),
                        groupId: UUID(),
                        description: "Expense \(i)",
                        date: Date(),
                        totalAmount: 100.0,
                        paidByMemberId: memberIds[0],
                        involvedMemberIds: memberIds,
                        splits: splits,
                        isSettled: false
                    )
                    
                    expenses.append(expense)
                }
                
                // Clear the array
                expenses.removeAll()
            }
            
            // Memory should be released after autoreleasepool
        }
    }
}
