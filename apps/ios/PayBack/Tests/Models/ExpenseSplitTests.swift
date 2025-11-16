import XCTest
@testable import PayBack

final class ExpenseSplitTests: XCTestCase {
	func testExpenseSplitInitialization() {
		let memberId = UUID()
		let split = ExpenseSplit(memberId: memberId, amount: 50.0)
		
		XCTAssertEqual(split.memberId, memberId)
		XCTAssertEqual(split.amount, 50.0)
		XCTAssertFalse(split.isSettled)
	}
	
	func testExpenseSplitWithSettled() {
		let memberId = UUID()
		let split = ExpenseSplit(memberId: memberId, amount: 50.0, isSettled: true)
		
		XCTAssertEqual(split.memberId, memberId)
		XCTAssertEqual(split.amount, 50.0)
		XCTAssertTrue(split.isSettled)
	}
	
	func testExpenseSplitCodable() throws {
		let memberId = UUID()
		let split = ExpenseSplit(memberId: memberId, amount: 50.0, isSettled: true)
		
		let encoder = JSONEncoder()
		let data = try encoder.encode(split)
		
		let decoder = JSONDecoder()
		let decodedSplit = try decoder.decode(ExpenseSplit.self, from: data)
		
		XCTAssertEqual(decodedSplit.memberId, split.memberId)
		XCTAssertEqual(decodedSplit.amount, split.amount)
		XCTAssertEqual(decodedSplit.isSettled, split.isSettled)
	}
	
	func testExpenseSplitEquality() {
		let memberId = UUID()
		let split1 = ExpenseSplit(id: UUID(), memberId: memberId, amount: 50.0)
		let split2 = ExpenseSplit(id: split1.id, memberId: memberId, amount: 50.0)
		
		XCTAssertEqual(split1, split2)
	}
	
	func testExpenseSplitHashable() {
		let memberId = UUID()
		let split1 = ExpenseSplit(memberId: memberId, amount: 50.0)
		let split2 = ExpenseSplit(memberId: memberId, amount: 100.0)
		
		var set = Set<ExpenseSplit>()
		set.insert(split1)
		set.insert(split2)
		
		XCTAssertEqual(set.count, 2)
	}
	
	func testExpenseSplitZeroAmount() {
		let memberId = UUID()
		let split = ExpenseSplit(memberId: memberId, amount: 0.0)
		
		XCTAssertEqual(split.amount, 0.0)
	}
	
	func testExpenseSplitNegativeAmount() {
		let memberId = UUID()
		let split = ExpenseSplit(memberId: memberId, amount: -10.0)
		
		XCTAssertEqual(split.amount, -10.0)
	}
	
	func testExpenseSplitLargeAmount() {
		let memberId = UUID()
		let split = ExpenseSplit(memberId: memberId, amount: 999999.99)
		
		XCTAssertEqual(split.amount, 999999.99)
	}
}
