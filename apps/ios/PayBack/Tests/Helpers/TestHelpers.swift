import Foundation
import XCTest
@testable import PayBack

// MARK: - Currency Fixture Models

/// Information about a currency's minor units and symbol
struct CurrencyInfo: Codable {
    let minorUnits: Int
    let symbol: String
}

/// Fixture containing currency information for testing
struct CurrencyFixture: Codable {
    let currencies: [String: CurrencyInfo]
    
    /// Get the number of minor units (decimal places) for a currency
    /// - Parameter currencyCode: The ISO 4217 currency code (e.g., "USD", "JPY")
    /// - Returns: The number of minor units, defaulting to 2 if not found
    func minorUnits(for currencyCode: String) -> Int {
        return currencies[currencyCode]?.minorUnits ?? 2
    }
    
    /// Get the currency symbol for a currency code
    /// - Parameter currencyCode: The ISO 4217 currency code
    /// - Returns: The currency symbol, or the code itself if not found
    func symbol(for currencyCode: String) -> String {
        return currencies[currencyCode]?.symbol ?? currencyCode
    }
}

// MARK: - Bundle Helper Class

/// Helper class for accessing test bundle (needed because Bundle(for:) requires a class)
class BundleHelper {}

// MARK: - Fixture Loading Helper

/// Load the currency minor units fixture from the test bundle
/// - Returns: A CurrencyFixture containing all currency information
/// - Throws: An error if the fixture cannot be loaded or decoded
func loadCurrencyFixture() throws -> CurrencyFixture {
    // Try with subdirectory first
    var url = Bundle(for: BundleHelper.self).url(
        forResource: "currency_minor_units",
        withExtension: "json",
        subdirectory: "Fixtures"
    )
    
    // If not found, try without subdirectory (in case Fixtures is a group, not a folder reference)
    if url == nil {
        url = Bundle(for: BundleHelper.self).url(
            forResource: "currency_minor_units",
            withExtension: "json"
        )
    }
    
    guard let fileURL = url else {
        throw NSError(
            domain: "TestHelpers",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not find currency_minor_units.json fixture"]
        )
    }
    
    let data = try Data(contentsOf: fileURL)
    let decoder = JSONDecoder()
    return try decoder.decode(CurrencyFixture.self, from: data)
}

// MARK: - Seeded Random Number Generator

/// A seeded random number generator for reproducible property-based tests
struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64
    
    init(seed: UInt64) {
        self.state = seed
    }
    
    mutating func next() -> UInt64 {
        // Linear congruential generator
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

// MARK: - Property-Based Test Case Generator

/// Test case for property-based expense splitting tests
struct ExpenseTestCase {
    let totalAmount: Decimal
    let memberCount: Int
    let memberIds: [UUID]
    
    /// Generate a random test case with specified member count
    static func random(memberCount: Int = Int.random(in: 2...20)) -> ExpenseTestCase {
        let amount = Decimal(Double.random(in: 0.01...10000.00))
        let ids = (0..<memberCount).map { _ in UUID() }
        return ExpenseTestCase(totalAmount: amount, memberCount: memberCount, memberIds: ids)
    }
    
    /// Generate a random test case using a seeded random number generator
    static func random<R: RandomNumberGenerator>(
        using rng: inout R,
        amount: ClosedRange<Double> = 0.01...10_000,
        members: ClosedRange<Int> = 2...20
    ) -> ExpenseTestCase {
        let m = Int.random(in: members, using: &rng)
        let amountDouble = Double.random(in: amount, using: &rng)
        // Use string-based conversion for precision
        let amt = Decimal(string: String(amountDouble)) ?? Decimal(amountDouble)
        let ids = (0..<m).map { _ in UUID() }
        return ExpenseTestCase(totalAmount: amt, memberCount: m, memberIds: ids)
    }
}

// MARK: - Test Fixtures

/// Sample test data for unit tests
struct TestFixtures {
    static let sampleGroupMember = GroupMember(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Alice"
    )
    
    static let sampleGroupMember2 = GroupMember(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        name: "Bob"
    )
    
    static let sampleGroupMember3 = GroupMember(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        name: "Charlie"
    )
    
    static let sampleGroup = SpendingGroup(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
        name: "Test Group",
        members: [sampleGroupMember, sampleGroupMember2, sampleGroupMember3],
        createdAt: Date(timeIntervalSince1970: 1700000000),
        isDirect: false
    )
    
    static let sampleExpense = Expense(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000100")!,
        groupId: sampleGroup.id,
        description: "Test Expense",
        date: Date(timeIntervalSince1970: 1700000000),
        totalAmount: 100.0,
        paidByMemberId: sampleGroupMember.id,
        involvedMemberIds: [sampleGroupMember.id, sampleGroupMember2.id, sampleGroupMember3.id],
        splits: [
            ExpenseSplit(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000001000")!,
                memberId: sampleGroupMember.id,
                amount: 33.34,
                isSettled: false
            ),
            ExpenseSplit(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000001001")!,
                memberId: sampleGroupMember2.id,
                amount: 33.33,
                isSettled: false
            ),
            ExpenseSplit(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000001002")!,
                memberId: sampleGroupMember3.id,
                amount: 33.33,
                isSettled: false
            )
        ],
        isSettled: false
    )
}

// MARK: - Assertion Helpers

/// Assert that the sum of splits equals the total amount (conservation of money)
func assertConservation(
    splits: [ExpenseSplit],
    totalAmount: Double,
    accuracy: Double = 0.01,
    file: StaticString = #file,
    line: UInt = #line
) {
    let sum = splits.reduce(0.0) { $0 + $1.amount }
    XCTAssertEqual(
        sum,
        totalAmount,
        accuracy: accuracy,
        "Sum of splits (\(sum)) should equal total amount (\(totalAmount))",
        file: file,
        line: line
    )
}

/// Assert that the same inputs produce identical outputs (determinism)
func assertDeterministic<T: Equatable>(
    operation: () -> T,
    iterations: Int = 2,
    file: StaticString = #file,
    line: UInt = #line
) {
    guard iterations >= 2 else {
        XCTFail("Determinism test requires at least 2 iterations", file: file, line: line)
        return
    }
    
    let results = (0..<iterations).map { _ in operation() }
    let first = results[0]
    
    for (index, result) in results.enumerated().dropFirst() {
        XCTAssertEqual(
            result,
            first,
            "Iteration \(index) produced different result. Expected deterministic behavior.",
            file: file,
            line: line
        )
    }
}

/// Helper utilities for tests
struct TestHelpers {
    
    /// Load a JSON fixture from the test bundle
    static func loadFixture<T: Decodable>(
        _ type: T.Type,
        filename: String,
        subdirectory: String? = "Fixtures",
        file: StaticString = #file,
        line: UInt = #line
    ) throws -> T {
        guard let url = Bundle(for: BundleHelper.self).url(
            forResource: filename,
            withExtension: "json",
            subdirectory: subdirectory
        ) else {
            XCTFail(
                "Could not find fixture file: \(filename).json in \(subdirectory ?? "root")",
                file: file,
                line: line
            )
            throw NSError(
                domain: "TestHelpers",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Fixture file not found"]
            )
        }
        
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(type, from: data)
    }
}


// MARK: - ExpenseBuilder

// MARK: - Expense Split Calculator (Test Helper)

/// Calculates equal splits using integer minor units to avoid floating-point drift
/// and correctly handle negative amounts (refunds).
///
/// This is a test helper function that will eventually be moved to production code.
///
/// - Parameters:
///   - totalAmount: Total expense amount (can be negative for refunds)
///   - memberIds: Array of member UUIDs to split among
///   - minorUnits: Number of decimal places for the currency (default 2 for USD/EUR)
/// - Returns: Array of ExpenseSplit with deterministic rounding
func calculateEqualSplits(totalAmount: Decimal, memberIds: [UUID], minorUnits: Int = 2) -> [ExpenseSplit] {
    guard !memberIds.isEmpty else { return [] }
    
    // Convert to minor units (cents for USD) to avoid floating-point issues
    let scale = pow(10 as Decimal, minorUnits)
    let totalMinor = NSDecimalNumber(decimal: totalAmount * scale).int64Value
    let n = Int64(memberIds.count)
    
    // Integer division (truncates toward zero for both positive and negative)
    let base = totalMinor / n
    let remainderValue = totalMinor - base * n
    let remainder = Int(remainderValue)
    
    // Stable, deterministic order (by UUID string, ASCII comparison)
    let sorted = memberIds.sorted { $0.uuidString < $1.uuidString }
    
    return sorted.enumerated().map { i, id in
        var share = base
        
        // Distribute remainder by sign
        if remainder >= 0 && i < remainder {
            share += 1
        } else if remainder <= 0 && i < -remainder {
            share -= 1
        }
        
        let amount = Decimal(share) / scale
        return ExpenseSplit(
            id: UUID(),
            memberId: id,
            amount: NSDecimalNumber(decimal: amount).doubleValue,
            isSettled: false
        )
    }
}

/// Overload for Double convenience
func calculateEqualSplits(totalAmount: Double, memberIds: [UUID], minorUnits: Int = 2) -> [ExpenseSplit] {
    // Convert via string to preserve exact decimal precision
    let decimalAmount = Decimal(string: String(totalAmount)) ?? Decimal(totalAmount)
    return calculateEqualSplits(totalAmount: decimalAmount, memberIds: memberIds, minorUnits: minorUnits)
}
