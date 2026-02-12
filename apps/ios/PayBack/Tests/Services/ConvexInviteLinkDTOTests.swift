import XCTest
@testable import PayBack

/// Tests for ConvexInviteLinkService DTOs
final class ConvexInviteLinkDTOTests: XCTestCase {
    
    // MARK: - ConvexInviteTokenDTO Tests
    
    func testConvexInviteTokenDTO_toInviteToken_ValidUUID_ReturnsToken() {
        let dto = ConvexInviteTokenDTO(
            id: UUID().uuidString,
            creator_id: "user-123",
            creator_email: "creator@example.com",
            creator_name: nil,
            creator_profile_image_url: nil,
            target_member_id: UUID().uuidString,
            target_member_name: "John Doe",
            created_at: Date().timeIntervalSince1970 * 1000,
            expires_at: Date().addingTimeInterval(86400 * 30).timeIntervalSince1970 * 1000,
            claimed_by: nil,
            claimed_at: nil
        )
        
        let token = dto.toInviteToken()
        
        XCTAssertNotNil(token)
        XCTAssertEqual(token?.creatorId, "user-123")
        XCTAssertEqual(token?.creatorEmail, "creator@example.com")
        XCTAssertEqual(token?.targetMemberName, "John Doe")
        XCTAssertNil(token?.claimedBy)
        XCTAssertNil(token?.claimedAt)
    }
    
    func testConvexInviteTokenDTO_toInviteToken_InvalidMainUUID_ReturnsNil() {
        let dto = ConvexInviteTokenDTO(
            id: "not-a-uuid",
            creator_id: "user-123",
            creator_email: "creator@example.com",
            creator_name: nil,
            creator_profile_image_url: nil,
            target_member_id: UUID().uuidString,
            target_member_name: "John Doe",
            created_at: 1704067200000,
            expires_at: 1706745600000,
            claimed_by: nil,
            claimed_at: nil
        )
        
        let token = dto.toInviteToken()
        XCTAssertNil(token)
    }
    
    func testConvexInviteTokenDTO_toInviteToken_InvalidTargetMemberUUID_ReturnsNil() {
        let dto = ConvexInviteTokenDTO(
            id: UUID().uuidString,
            creator_id: "user-123",
            creator_email: "creator@example.com",
            creator_name: nil,
            creator_profile_image_url: nil,
            target_member_id: "invalid-uuid",
            target_member_name: "John Doe",
            created_at: 1704067200000,
            expires_at: 1706745600000,
            claimed_by: nil,
            claimed_at: nil
        )
        
        let token = dto.toInviteToken()
        XCTAssertNil(token)
    }
    
    func testConvexInviteTokenDTO_toInviteToken_WithClaimedData_PreservesClaimInfo() {
        let claimedAt = Date()
        let dto = ConvexInviteTokenDTO(
            id: UUID().uuidString,
            creator_id: "user-123",
            creator_email: "creator@example.com",
            creator_name: nil,
            creator_profile_image_url: nil,
            target_member_id: UUID().uuidString,
            target_member_name: "John Doe",
            created_at: Date().timeIntervalSince1970 * 1000,
            expires_at: Date().addingTimeInterval(86400 * 30).timeIntervalSince1970 * 1000,
            claimed_by: "claimer-account-id",
            claimed_at: claimedAt.timeIntervalSince1970 * 1000
        )
        
        let token = dto.toInviteToken()
        
        XCTAssertNotNil(token)
        XCTAssertEqual(token?.claimedBy, "claimer-account-id")
        XCTAssertNotNil(token?.claimedAt)
    }
    
    func testConvexInviteTokenDTO_toInviteToken_DateConversion_IsAccurate() {
        let createdAt: Double = 1704067200000 // Jan 1, 2024, 00:00:00 UTC
        let expiresAt: Double = 1706745600000 // Feb 1, 2024, 00:00:00 UTC
        
        let dto = ConvexInviteTokenDTO(
            id: UUID().uuidString,
            creator_id: "user-123",
            creator_email: "creator@example.com",
            creator_name: nil,
            creator_profile_image_url: nil,
            target_member_id: UUID().uuidString,
            target_member_name: "John Doe",
            created_at: createdAt,
            expires_at: expiresAt,
            claimed_by: nil,
            claimed_at: nil
        )
        
        guard let token = dto.toInviteToken() else {
            XCTFail("Expected token to be created")
            return
        }
        
        XCTAssertEqual(token.createdAt.timeIntervalSince1970, 1704067200.0, accuracy: 1.0)
        XCTAssertEqual(token.expiresAt.timeIntervalSince1970, 1706745600.0, accuracy: 1.0)
    }
    
    func testConvexInviteTokenDTO_Decodable_FromJSON() throws {
        let json = """
        {
            "id": "550e8400-e29b-41d4-a716-446655440000",
            "creator_id": "user-abc",
            "creator_email": "test@example.com",
            "target_member_id": "661e8400-e29b-41d4-a716-446655440001",
            "target_member_name": "Jane Doe",
            "created_at": 1704067200000,
            "expires_at": 1706745600000,
            "claimed_by": null,
            "claimed_at": null
        }
        """.data(using: .utf8)!
        
        let dto = try JSONDecoder().decode(ConvexInviteTokenDTO.self, from: json)
        
        XCTAssertEqual(dto.id, "550e8400-e29b-41d4-a716-446655440000")
        XCTAssertEqual(dto.creator_id, "user-abc")
        XCTAssertEqual(dto.creator_email, "test@example.com")
        XCTAssertEqual(dto.target_member_name, "Jane Doe")
        XCTAssertNil(dto.claimed_by)
    }
    
    func testConvexInviteTokenDTO_Decodable_WithClaimedFields() throws {
        let json = """
        {
            "id": "550e8400-e29b-41d4-a716-446655440000",
            "creator_id": "user-abc",
            "creator_email": "test@example.com",
            "target_member_id": "661e8400-e29b-41d4-a716-446655440001",
            "target_member_name": "Jane Doe",
            "created_at": 1704067200000,
            "expires_at": 1706745600000,
            "claimed_by": "claimer-123",
            "claimed_at": 1705000000000
        }
        """.data(using: .utf8)!
        
        let dto = try JSONDecoder().decode(ConvexInviteTokenDTO.self, from: json)
        
        XCTAssertEqual(dto.claimed_by, "claimer-123")
        XCTAssertEqual(dto.claimed_at, 1705000000000)
    }
    
    // MARK: - ConvexExpensePreviewDTO Tests
    
    func testConvexExpensePreviewDTO_Decodable_FromJSON() throws {
        let json = """
        {
            "expense_count": 5,
            "group_names": ["Rent", "Utilities", "Groceries"],
            "total_balance": 150.75
        }
        """.data(using: .utf8)!
        
        let dto = try JSONDecoder().decode(ConvexExpensePreviewDTO.self, from: json)
        
        XCTAssertEqual(dto.expense_count, 5)
        XCTAssertEqual(dto.group_names, ["Rent", "Utilities", "Groceries"])
        XCTAssertEqual(dto.total_balance, 150.75, accuracy: 0.01)
    }
    
    func testConvexExpensePreviewDTO_Decodable_EmptyGroups() throws {
        let json = """
        {
            "expense_count": 0,
            "group_names": [],
            "total_balance": 0.0
        }
        """.data(using: .utf8)!
        
        let dto = try JSONDecoder().decode(ConvexExpensePreviewDTO.self, from: json)
        
        XCTAssertEqual(dto.expense_count, 0)
        XCTAssertEqual(dto.group_names, [])
        XCTAssertEqual(dto.total_balance, 0.0, accuracy: 0.01)
    }
    
    func testConvexExpensePreviewDTO_Decodable_NegativeBalance() throws {
        let json = """
        {
            "expense_count": 10,
            "group_names": ["Trip"],
            "total_balance": -250.50
        }
        """.data(using: .utf8)!
        
        let dto = try JSONDecoder().decode(ConvexExpensePreviewDTO.self, from: json)
        
        XCTAssertEqual(dto.total_balance, -250.50, accuracy: 0.01)
    }
    
    // MARK: - ConvexInviteTokenValidationDTO Tests
    
    func testConvexInviteTokenValidationDTO_Decodable_ValidToken() throws {
        let json = """
        {
            "is_valid": true,
            "error": null,
            "token": {
                "id": "550e8400-e29b-41d4-a716-446655440000",
                "creator_id": "user-abc",
                "creator_email": "test@example.com",
                "target_member_id": "661e8400-e29b-41d4-a716-446655440001",
                "target_member_name": "Jane Doe",
                "created_at": 1704067200000,
                "expires_at": 1706745600000,
                "claimed_by": null,
                "claimed_at": null
            },
            "expense_preview": {
                "expense_count": 3,
                "group_names": ["Rent"],
                "total_balance": 100.00
            }
        }
        """.data(using: .utf8)!
        
        let dto = try JSONDecoder().decode(ConvexInviteTokenValidationDTO.self, from: json)
        
        XCTAssertTrue(dto.is_valid)
        XCTAssertNil(dto.error)
        XCTAssertNotNil(dto.token)
        XCTAssertNotNil(dto.expense_preview)
        XCTAssertEqual(dto.expense_preview?.expense_count, 3)
    }
    
    func testConvexInviteTokenValidationDTO_Decodable_InvalidToken() throws {
        let json = """
        {
            "is_valid": false,
            "error": "Token has expired",
            "token": null,
            "expense_preview": null
        }
        """.data(using: .utf8)!
        
        let dto = try JSONDecoder().decode(ConvexInviteTokenValidationDTO.self, from: json)
        
        XCTAssertFalse(dto.is_valid)
        XCTAssertEqual(dto.error, "Token has expired")
        XCTAssertNil(dto.token)
        XCTAssertNil(dto.expense_preview)
    }
    
    func testConvexInviteTokenValidationDTO_Decodable_ClaimedToken() throws {
        let json = """
        {
            "is_valid": false,
            "error": "Token already claimed",
            "token": {
                "id": "550e8400-e29b-41d4-a716-446655440000",
                "creator_id": "user-abc",
                "creator_email": "test@example.com",
                "target_member_id": "661e8400-e29b-41d4-a716-446655440001",
                "target_member_name": "Jane Doe",
                "created_at": 1704067200000,
                "expires_at": 1706745600000,
                "claimed_by": "claimer-456",
                "claimed_at": 1705000000000
            },
            "expense_preview": null
        }
        """.data(using: .utf8)!
        
        let dto = try JSONDecoder().decode(ConvexInviteTokenValidationDTO.self, from: json)
        
        XCTAssertFalse(dto.is_valid)
        XCTAssertEqual(dto.error, "Token already claimed")
        XCTAssertNotNil(dto.token)
        XCTAssertEqual(dto.token?.claimed_by, "claimer-456")
    }
    
    // MARK: - ConvexLinkAcceptResultDTO Tests
    
    func testConvexLinkAcceptResultDTO_Decodable_FromJSON() throws {
        let json = """
        {
            "linked_member_id": "550e8400-e29b-41d4-a716-446655440000",
            "linked_account_id": "account-123",
            "linked_account_email": "linked@example.com"
        }
        """.data(using: .utf8)!
        
        let dto = try JSONDecoder().decode(ConvexLinkAcceptResultDTO.self, from: json)
        
        XCTAssertEqual(dto.linked_member_id, "550e8400-e29b-41d4-a716-446655440000")
        XCTAssertEqual(dto.linked_account_id, "account-123")
        XCTAssertEqual(dto.linked_account_email, "linked@example.com")
    }
    
    func testConvexLinkAcceptResultDTO_Decodable_FromJSON_Canonical() throws {
        let json = """
        {
            "canonical_member_id": "550e8400-e29b-41d4-a716-446655440000",
            "linked_account_id": "account-123",
            "linked_account_email": "linked@example.com"
        }
        """.data(using: .utf8)!
        
        let dto = try JSONDecoder().decode(ConvexLinkAcceptResultDTO.self, from: json)
        
        XCTAssertEqual(dto.linked_member_id, "550e8400-e29b-41d4-a716-446655440000")
        XCTAssertEqual(dto.linked_account_id, "account-123")
        XCTAssertEqual(dto.linked_account_email, "linked@example.com")
    }
    
    func testConvexLinkAcceptResultDTO_Decodable_SpecialCharactersInEmail() throws {
        let json = """
        {
            "linked_member_id": "550e8400-e29b-41d4-a716-446655440000",
            "linked_account_id": "account-456",
            "linked_account_email": "user+tag@sub.domain.example.com"
        }
        """.data(using: .utf8)!
        
        let dto = try JSONDecoder().decode(ConvexLinkAcceptResultDTO.self, from: json)
        
        XCTAssertEqual(dto.linked_account_email, "user+tag@sub.domain.example.com")
    }
    
    // MARK: - Edge Cases
    
    func testConvexInviteTokenDTO_EmptyStrings_HandleGracefully() {
        let dto = ConvexInviteTokenDTO(
            id: UUID().uuidString,
            creator_id: "",
            creator_email: "",
            creator_name: nil,
            creator_profile_image_url: nil,
            target_member_id: UUID().uuidString,
            target_member_name: "",
            created_at: Date().timeIntervalSince1970 * 1000,
            expires_at: Date().addingTimeInterval(86400).timeIntervalSince1970 * 1000,
            claimed_by: nil,
            claimed_at: nil
        )
        
        let token = dto.toInviteToken()
        
        XCTAssertNotNil(token)
        XCTAssertEqual(token?.creatorId, "")
        XCTAssertEqual(token?.creatorEmail, "")
        XCTAssertEqual(token?.targetMemberName, "")
    }
    
    func testConvexInviteTokenDTO_VeryLongStrings_HandleGracefully() {
        let longName = String(repeating: "a", count: 1000)
        let dto = ConvexInviteTokenDTO(
            id: UUID().uuidString,
            creator_id: longName,
            creator_email: "test@example.com",
            creator_name: nil,
            creator_profile_image_url: nil,
            target_member_id: UUID().uuidString,
            target_member_name: longName,
            created_at: Date().timeIntervalSince1970 * 1000,
            expires_at: Date().addingTimeInterval(86400).timeIntervalSince1970 * 1000,
            claimed_by: nil,
            claimed_at: nil
        )
        
        let token = dto.toInviteToken()
        
        XCTAssertNotNil(token)
        XCTAssertEqual(token?.creatorId.count, 1000)
        XCTAssertEqual(token?.targetMemberName.count, 1000)
    }
    
    func testConvexInviteTokenDTO_UnicodeCharacters_HandleGracefully() {
        let dto = ConvexInviteTokenDTO(
            id: UUID().uuidString,
            creator_id: "用户-123",
            creator_email: "test@例え.com",
            creator_name: nil,
            creator_profile_image_url: nil,
            target_member_id: UUID().uuidString,
            target_member_name: "José García 🎉",
            created_at: Date().timeIntervalSince1970 * 1000,
            expires_at: Date().addingTimeInterval(86400).timeIntervalSince1970 * 1000,
            claimed_by: nil,
            claimed_at: nil
        )
        
        let token = dto.toInviteToken()
        
        XCTAssertNotNil(token)
        XCTAssertEqual(token?.targetMemberName, "José García 🎉")
    }
    
    func testConvexExpensePreviewDTO_ManyGroups_HandleGracefully() throws {
        let groupNames = (1...100).map { "Group \($0)" }
        let jsonGroups = groupNames.map { "\"\($0)\"" }.joined(separator: ", ")
        let json = """
        {
            "expense_count": 500,
            "group_names": [\(jsonGroups)],
            "total_balance": 99999.99
        }
        """.data(using: .utf8)!
        
        let dto = try JSONDecoder().decode(ConvexExpensePreviewDTO.self, from: json)
        
        XCTAssertEqual(dto.group_names.count, 100)
        XCTAssertEqual(dto.expense_count, 500)
    }
}
