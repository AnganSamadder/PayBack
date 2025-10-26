import XCTest
@testable import PayBack

@MainActor
final class GroupCloudServiceTests: XCTestCase {
    
    // MARK: - Error Tests
    
    func test_groupCloudServiceError_userNotAuthenticated_hasDescription() {
        // Given
        let error = GroupCloudServiceError.userNotAuthenticated
        
        // When
        let description = error.errorDescription
        
        // Then
        XCTAssertNotNil(description)
        XCTAssertTrue(description?.contains("sign in") ?? false)
    }
    
    func test_groupCloudServiceError_userNotAuthenticated_isLocalizedError() {
        // Given
        let error = GroupCloudServiceError.userNotAuthenticated
        
        // Then
        XCTAssertTrue(error is LocalizedError)
        XCTAssertFalse(error.localizedDescription.isEmpty)
    }
    
    // MARK: - ExpenseParticipant Tests
    
    func test_expenseParticipant_initialization_withoutLinkedAccount() {
        // Given
        let memberId = UUID()
        let name = "John Doe"
        
        // When
        let participant = ExpenseParticipant(
            memberId: memberId,
            name: name,
            linkedAccountId: nil,
            linkedAccountEmail: nil
        )
        
        // Then
        XCTAssertEqual(participant.memberId, memberId)
        XCTAssertEqual(participant.name, name)
        XCTAssertNil(participant.linkedAccountId)
        XCTAssertNil(participant.linkedAccountEmail)
    }
    
    func test_expenseParticipant_initialization_withLinkedAccount() {
        // Given
        let memberId = UUID()
        let name = "Jane Smith"
        let linkedId = "account-123"
        let linkedEmail = "jane@example.com"
        
        // When
        let participant = ExpenseParticipant(
            memberId: memberId,
            name: name,
            linkedAccountId: linkedId,
            linkedAccountEmail: linkedEmail
        )
        
        // Then
        XCTAssertEqual(participant.memberId, memberId)
        XCTAssertEqual(participant.name, name)
        XCTAssertEqual(participant.linkedAccountId, linkedId)
        XCTAssertEqual(participant.linkedAccountEmail, linkedEmail)
    }
    
    func test_expenseParticipant_multipleParticipants_haveDifferentIds() {
        // Given/When
        let participant1 = ExpenseParticipant(
            memberId: UUID(),
            name: "User 1",
            linkedAccountId: nil,
            linkedAccountEmail: nil
        )
        let participant2 = ExpenseParticipant(
            memberId: UUID(),
            name: "User 2",
            linkedAccountId: nil,
            linkedAccountEmail: nil
        )
        
        // Then
        XCTAssertNotEqual(participant1.memberId, participant2.memberId)
    }
    
    func test_expenseParticipant_nameWithSpecialCharacters() {
        // Given
        let memberId = UUID()
        let specialName = "José García-Müller 🎉"
        
        // When
        let participant = ExpenseParticipant(
            memberId: memberId,
            name: specialName,
            linkedAccountId: nil,
            linkedAccountEmail: nil
        )
        
        // Then
        XCTAssertEqual(participant.name, specialName)
    }
    
    func test_expenseParticipant_emptyName() {
        // Given
        let memberId = UUID()
        let emptyName = ""
        
        // When
        let participant = ExpenseParticipant(
            memberId: memberId,
            name: emptyName,
            linkedAccountId: nil,
            linkedAccountEmail: nil
        )
        
        // Then
        XCTAssertEqual(participant.name, emptyName)
    }
    
    func test_expenseParticipant_veryLongName() {
        // Given
        let memberId = UUID()
        let longName = String(repeating: "A", count: 1000)
        
        // When
        let participant = ExpenseParticipant(
            memberId: memberId,
            name: longName,
            linkedAccountId: nil,
            linkedAccountEmail: nil
        )
        
        // Then
        XCTAssertEqual(participant.name, longName)
    }
    
    func test_expenseParticipant_linkedAccountId_withoutEmail() {
        // Given
        let memberId = UUID()
        let linkedId = "account-456"
        
        // When
        let participant = ExpenseParticipant(
            memberId: memberId,
            name: "Test User",
            linkedAccountId: linkedId,
            linkedAccountEmail: nil
        )
        
        // Then
        XCTAssertEqual(participant.linkedAccountId, linkedId)
        XCTAssertNil(participant.linkedAccountEmail)
    }
    
    func test_expenseParticipant_linkedAccountEmail_withoutId() {
        // Given
        let memberId = UUID()
        let linkedEmail = "test@example.com"
        
        // When
        let participant = ExpenseParticipant(
            memberId: memberId,
            name: "Test User",
            linkedAccountId: nil,
            linkedAccountEmail: linkedEmail
        )
        
        // Then
        XCTAssertNil(participant.linkedAccountId)
        XCTAssertEqual(participant.linkedAccountEmail, linkedEmail)
    }
    
    func test_expenseParticipant_arrayOfParticipants() {
        // Given
        let participants = (1...10).map { index in
            ExpenseParticipant(
                memberId: UUID(),
                name: "Participant \(index)",
                linkedAccountId: index % 2 == 0 ? "account-\(index)" : nil,
                linkedAccountEmail: index % 2 == 0 ? "user\(index)@example.com" : nil
            )
        }
        
        // Then
        XCTAssertEqual(participants.count, 10)
        
        // Verify half have linked accounts
        let linkedCount = participants.filter { $0.linkedAccountId != nil }.count
        XCTAssertEqual(linkedCount, 5)
        
        // Verify all have unique member IDs
        let uniqueIds = Set(participants.map(\.memberId))
        XCTAssertEqual(uniqueIds.count, 10)
    }
}
