import XCTest
@testable import PayBack

final class UserAccountTests: XCTestCase {
    
    // MARK: - UserAccount Tests
    
    func test_userAccount_initialization_withDefaults() {
        let account = UserAccount(
            id: "user123",
            email: "test@example.com",
            displayName: "Example User"
        )
        
        XCTAssertEqual(account.id, "user123")
        XCTAssertEqual(account.email, "test@example.com")
        XCTAssertEqual(account.displayName, "Example User")
        XCTAssertNil(account.linkedMemberId)
        XCTAssertNotNil(account.createdAt)
    }
    
    func test_userAccount_initialization_withAllParameters() {
        let memberId = UUID()
        let createdAt = Date(timeIntervalSince1970: 1000000)
        
        let account = UserAccount(
            id: "user456",
            email: "user@test.com",
            displayName: "Full User",
            linkedMemberId: memberId,
            createdAt: createdAt
        )
        
        XCTAssertEqual(account.id, "user456")
        XCTAssertEqual(account.email, "user@test.com")
        XCTAssertEqual(account.displayName, "Full User")
        XCTAssertEqual(account.linkedMemberId, memberId)
        XCTAssertEqual(account.createdAt, createdAt)
    }
    
    func test_userAccount_identifiable() {
        let account = UserAccount(
            id: "uniqueId",
            email: "id@test.com",
            displayName: "ID User"
        )
        
        XCTAssertEqual(account.id, "uniqueId")
    }
    
    func test_userAccount_codable_roundTrip() throws {
        let memberId = UUID()
        let createdAt = Date(timeIntervalSince1970: 1234567890)
        
        let original = UserAccount(
            id: "encode123",
            email: "encode@test.com",
            displayName: "Encode User",
            linkedMemberId: memberId,
            createdAt: createdAt
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(UserAccount.self, from: data)
        
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.email, original.email)
        XCTAssertEqual(decoded.displayName, original.displayName)
        XCTAssertEqual(decoded.linkedMemberId, original.linkedMemberId)
        // Compare timestamps since Date encoding might vary slightly
        XCTAssertEqual(decoded.createdAt.timeIntervalSince1970, 
                      original.createdAt.timeIntervalSince1970, 
                      accuracy: 0.001)
    }
    
    func test_userAccount_hashable() {
        let memberId = UUID()
        let createdAt = Date(timeIntervalSince1970: 999999)
        
        let account1 = UserAccount(
            id: "hash1",
            email: "hash@test.com",
            displayName: "Hash User",
            linkedMemberId: memberId,
            createdAt: createdAt
        )
        
        let account2 = UserAccount(
            id: "hash1",
            email: "hash@test.com",
            displayName: "Hash User",
            linkedMemberId: memberId,
            createdAt: createdAt
        )
        
        let account3 = UserAccount(
            id: "hash2",
            email: "different@test.com",
            displayName: "Different User"
        )
        
        XCTAssertEqual(account1, account2)
        XCTAssertNotEqual(account1, account3)
        
        var set = Set<UserAccount>()
        set.insert(account1)
        XCTAssertTrue(set.contains(account2))
        XCTAssertFalse(set.contains(account3))
    }
    
    // MARK: - UserSession Tests
    
    func test_userSession_initialization() {
        let account = UserAccount(
            id: "session123",
            email: "session@test.com",
            displayName: "Session User"
        )
        let session = UserSession(account: account)
        
        XCTAssertEqual(session.account.id, "session123")
        XCTAssertEqual(session.account.email, "session@test.com")
    }
    
    func test_userSession_equatable() {
        let createdAt = Date(timeIntervalSince1970: 1234567)
        let account1 = UserAccount(
            id: "eq1",
            email: "eq@test.com",
            displayName: "Eq User",
            createdAt: createdAt
        )
        let account2 = UserAccount(
            id: "eq1",
            email: "eq@test.com",
            displayName: "Eq User",
            createdAt: createdAt
        )
        let account3 = UserAccount(
            id: "eq2",
            email: "different@test.com",
            displayName: "Different User",
            createdAt: Date(timeIntervalSince1970: 7654321)
        )
        
        let session1 = UserSession(account: account1)
        let session2 = UserSession(account: account2)
        let session3 = UserSession(account: account3)
        
        XCTAssertEqual(session1, session2)
        XCTAssertNotEqual(session1, session3)
    }
    
    // MARK: - AccountFriend Tests
    
    func test_accountFriend_initialization_minimal() {
        let memberId = UUID()
        let friend = AccountFriend(
            memberId: memberId,
            name: "John Doe"
        )
        
        XCTAssertEqual(friend.memberId, memberId)
        XCTAssertEqual(friend.name, "John Doe")
        XCTAssertNil(friend.nickname)
        XCTAssertFalse(friend.hasLinkedAccount)
        XCTAssertNil(friend.linkedAccountId)
        XCTAssertNil(friend.linkedAccountEmail)
    }
    
    func test_accountFriend_initialization_full() {
        let memberId = UUID()
        let friend = AccountFriend(
            memberId: memberId,
            name: "Jane Smith",
            nickname: "Janie",
            hasLinkedAccount: true,
            linkedAccountId: "linked123",
            linkedAccountEmail: "jane@example.com"
        )
        
        XCTAssertEqual(friend.memberId, memberId)
        XCTAssertEqual(friend.name, "Jane Smith")
        XCTAssertEqual(friend.nickname, "Janie")
        XCTAssertTrue(friend.hasLinkedAccount)
        XCTAssertEqual(friend.linkedAccountId, "linked123")
        XCTAssertEqual(friend.linkedAccountEmail, "jane@example.com")
    }
    
    func test_accountFriend_identifiable() {
        let memberId = UUID()
        let friend = AccountFriend(memberId: memberId, name: "Test")
        
        XCTAssertEqual(friend.id, memberId)
    }
    
    // MARK: - Display Name Tests
    
    func test_displayName_unlinkedFriend_showRealNames() {
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Real Name",
            nickname: "Nick",
            hasLinkedAccount: false
        )
        
        // Unlinked friends always show name, regardless of preference
        XCTAssertEqual(friend.displayName(showRealNames: true), "Real Name")
    }
    
    func test_displayName_unlinkedFriend_showNicknames() {
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Real Name",
            nickname: "Nick",
            hasLinkedAccount: false
        )
        
        // Unlinked friends always show name, regardless of preference
        XCTAssertEqual(friend.displayName(showRealNames: false), "Real Name")
    }
    
    func test_displayName_linkedFriend_noNickname_showRealNames() {
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Real Name",
            nickname: nil,
            hasLinkedAccount: true
        )
        
        XCTAssertEqual(friend.displayName(showRealNames: true), "Real Name")
    }
    
    func test_displayName_linkedFriend_noNickname_showNicknames() {
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Real Name",
            nickname: nil,
            hasLinkedAccount: true
        )
        
        // No nickname means always show real name
        XCTAssertEqual(friend.displayName(showRealNames: false), "Real Name")
    }
    
    func test_displayName_linkedFriend_emptyNickname_showRealNames() {
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Real Name",
            nickname: "",
            hasLinkedAccount: true
        )
        
        XCTAssertEqual(friend.displayName(showRealNames: true), "Real Name")
    }
    
    func test_displayName_linkedFriend_emptyNickname_showNicknames() {
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Real Name",
            nickname: "",
            hasLinkedAccount: true
        )
        
        // Empty nickname means always show real name
        XCTAssertEqual(friend.displayName(showRealNames: false), "Real Name")
    }
    
    func test_displayName_linkedFriend_withNickname_showRealNames() {
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Real Name",
            nickname: "Nick",
            hasLinkedAccount: true
        )
        
        XCTAssertEqual(friend.displayName(showRealNames: true), "Real Name")
    }
    
    func test_displayName_linkedFriend_withNickname_showNicknames() {
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Real Name",
            nickname: "Nick",
            hasLinkedAccount: true
        )
        
        XCTAssertEqual(friend.displayName(showRealNames: false), "Nick")
    }
    
    // MARK: - Secondary Display Name Tests
    
    func test_secondaryDisplayName_unlinkedFriend_showRealNames() {
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Real Name",
            nickname: "Nick",
            hasLinkedAccount: false
        )
        
        // Unlinked friends have no secondary name
        XCTAssertNil(friend.secondaryDisplayName(showRealNames: true))
    }
    
    func test_secondaryDisplayName_unlinkedFriend_showNicknames() {
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Real Name",
            nickname: "Nick",
            hasLinkedAccount: false
        )
        
        // Unlinked friends have no secondary name
        XCTAssertNil(friend.secondaryDisplayName(showRealNames: false))
    }
    
    func test_secondaryDisplayName_linkedFriend_noNickname_showRealNames() {
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Real Name",
            nickname: nil,
            hasLinkedAccount: true
        )
        
        // No nickname means no secondary name
        XCTAssertNil(friend.secondaryDisplayName(showRealNames: true))
    }
    
    func test_secondaryDisplayName_linkedFriend_noNickname_showNicknames() {
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Real Name",
            nickname: nil,
            hasLinkedAccount: true
        )
        
        // No nickname means no secondary name
        XCTAssertNil(friend.secondaryDisplayName(showRealNames: false))
    }
    
    func test_secondaryDisplayName_linkedFriend_emptyNickname_showRealNames() {
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Real Name",
            nickname: "",
            hasLinkedAccount: true
        )
        
        // Empty nickname means no secondary name
        XCTAssertNil(friend.secondaryDisplayName(showRealNames: true))
    }
    
    func test_secondaryDisplayName_linkedFriend_emptyNickname_showNicknames() {
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Real Name",
            nickname: "",
            hasLinkedAccount: true
        )
        
        // Empty nickname means no secondary name
        XCTAssertNil(friend.secondaryDisplayName(showRealNames: false))
    }
    
    func test_secondaryDisplayName_linkedFriend_withNickname_showRealNames() {
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Real Name",
            nickname: "Nick",
            hasLinkedAccount: true
        )
        
        // Show nickname underneath when showing real names
        XCTAssertEqual(friend.secondaryDisplayName(showRealNames: true), "Nick")
    }
    
    func test_secondaryDisplayName_linkedFriend_withNickname_showNicknames() {
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Real Name",
            nickname: "Nick",
            hasLinkedAccount: true
        )
        
        // Show real name underneath when showing nicknames
        XCTAssertEqual(friend.secondaryDisplayName(showRealNames: false), "Real Name")
    }
    
    // MARK: - Codable Tests
    
    func test_accountFriend_codable_roundTrip_full() throws {
        let memberId = UUID()
        let original = AccountFriend(
            memberId: memberId,
            name: "Full Name",
            nickname: "Fullster",
            hasLinkedAccount: true,
            linkedAccountId: "account789",
            linkedAccountEmail: "full@example.com"
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AccountFriend.self, from: data)
        
        XCTAssertEqual(decoded.memberId, original.memberId)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.nickname, original.nickname)
        XCTAssertEqual(decoded.hasLinkedAccount, original.hasLinkedAccount)
        XCTAssertEqual(decoded.linkedAccountId, original.linkedAccountId)
        XCTAssertEqual(decoded.linkedAccountEmail, original.linkedAccountEmail)
    }
    
    func test_accountFriend_codable_roundTrip_minimal() throws {
        let memberId = UUID()
        let original = AccountFriend(
            memberId: memberId,
            name: "Min Name"
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AccountFriend.self, from: data)
        
        XCTAssertEqual(decoded.memberId, original.memberId)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertNil(decoded.nickname)
        XCTAssertFalse(decoded.hasLinkedAccount)
        XCTAssertNil(decoded.linkedAccountId)
        XCTAssertNil(decoded.linkedAccountEmail)
    }
    
    func test_accountFriend_decode_backwardCompatibility_missingNickname() throws {
        let memberId = UUID()
        let json = """
        {
            "memberId": "\(memberId.uuidString)",
            "name": "Old Friend",
            "hasLinkedAccount": false
        }
        """
        
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AccountFriend.self, from: data)
        
        XCTAssertEqual(decoded.memberId, memberId)
        XCTAssertEqual(decoded.name, "Old Friend")
        XCTAssertNil(decoded.nickname) // Should default to nil
        XCTAssertFalse(decoded.hasLinkedAccount)
    }
    
    func test_accountFriend_decode_backwardCompatibility_missingLinkedFields() throws {
        let memberId = UUID()
        let json = """
        {
            "memberId": "\(memberId.uuidString)",
            "name": "Old Friend",
            "hasLinkedAccount": true
        }
        """
        
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AccountFriend.self, from: data)
        
        XCTAssertEqual(decoded.memberId, memberId)
        XCTAssertEqual(decoded.name, "Old Friend")
        XCTAssertTrue(decoded.hasLinkedAccount)
        XCTAssertNil(decoded.linkedAccountId) // Should be nil when missing
        XCTAssertNil(decoded.linkedAccountEmail) // Should be nil when missing
    }
    
    func test_accountFriend_hashable() {
        let memberId = UUID()
        
        let friend1 = AccountFriend(
            memberId: memberId,
            name: "Same Friend",
            nickname: "Sammy",
            hasLinkedAccount: true
        )
        
        let friend2 = AccountFriend(
            memberId: memberId,
            name: "Same Friend",
            nickname: "Sammy",
            hasLinkedAccount: true
        )
        
        let friend3 = AccountFriend(
            memberId: UUID(),
            name: "Different Friend",
            hasLinkedAccount: false
        )
        
        XCTAssertEqual(friend1, friend2)
        XCTAssertNotEqual(friend1, friend3)
        
        var set = Set<AccountFriend>()
        set.insert(friend1)
        XCTAssertTrue(set.contains(friend2))
        XCTAssertFalse(set.contains(friend3))
    }
}
