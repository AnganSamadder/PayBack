import XCTest
@testable import PayBack

/// Extended tests for ConvexDTO transformations and edge cases
final class ConvexDTOExtendedTests: XCTestCase {
    
    // MARK: - ConvexExpenseDTO toExpense Tests
    
    func testConvexExpenseDTO_toExpense_MapsAllFields() {
        let dto = ConvexExpenseDTO(
            id: "550e8400-e29b-41d4-a716-446655440000",
            group_id: "661e8400-e29b-41d4-a716-446655440001",
            description: "Dinner",
            date: 1704067200000,
            total_amount: 100.50,
            paid_by_member_id: "772e8400-e29b-41d4-a716-446655440002",
            involved_member_ids: ["772e8400-e29b-41d4-a716-446655440002"],
            splits: [],
            is_settled: true,
            owner_email: nil,
            owner_account_id: nil,
            participant_member_ids: nil,
            participants: nil,
            subexpenses: nil
        )
        
        let expense = dto.toExpense()
        
        XCTAssertEqual(expense.description, "Dinner")
        XCTAssertEqual(expense.totalAmount, 100.50, accuracy: 0.01)
        XCTAssertTrue(expense.isSettled)
    }
    
    func testConvexExpenseDTO_toExpense_ConvertsDateCorrectly() {
        let dto = ConvexExpenseDTO(
            id: "550e8400-e29b-41d4-a716-446655440000",
            group_id: "661e8400-e29b-41d4-a716-446655440001",
            description: "Test",
            date: 1704067200000, // Jan 1, 2024 00:00:00 UTC in ms
            total_amount: 10,
            paid_by_member_id: "772e8400-e29b-41d4-a716-446655440002",
            involved_member_ids: [],
            splits: [],
            is_settled: false,
            owner_email: nil,
            owner_account_id: nil,
            participant_member_ids: nil,
            participants: nil,
            subexpenses: nil
        )
        
        let expense = dto.toExpense()
        
        // Should be close to Jan 1, 2024
        XCTAssertEqual(expense.date.timeIntervalSince1970, 1704067200, accuracy: 1)
    }
    
    // MARK: - ConvexSplitDTO toExpenseSplit Tests
    
    func testConvexSplitDTO_toExpenseSplit_MapsAllFields() {
        let dto = ConvexSplitDTO(
            id: "550e8400-e29b-41d4-a716-446655440000",
            member_id: "661e8400-e29b-41d4-a716-446655440001",
            amount: 75.25,
            is_settled: true
        )
        
        let split = dto.toExpenseSplit()
        
        XCTAssertEqual(split.amount, 75.25, accuracy: 0.01)
        XCTAssertTrue(split.isSettled)
    }
    
    func testConvexSplitDTO_toExpenseSplit_InvalidIdFallsBackToRandomUUID() {
        let dto = ConvexSplitDTO(
            id: "invalid-uuid",
            member_id: "also-invalid",
            amount: 50,
            is_settled: false
        )
        
        let split = dto.toExpenseSplit()
        
        // Should not crash, will use fallback UUID
        XCTAssertEqual(split.amount, 50.0, accuracy: 0.01)
        XCTAssertFalse(split.isSettled)
    }
    
    // MARK: - ConvexParticipantDTO toExpenseParticipant Tests
    
    func testConvexParticipantDTO_toExpenseParticipant_FullyLinked() {
        let dto = ConvexParticipantDTO(
            member_id: "550e8400-e29b-41d4-a716-446655440000",
            name: "Alice",
            linked_account_id: "account-123",
            linked_account_email: "alice@example.com"
        )
        
        let participant = dto.toExpenseParticipant()
        
        XCTAssertEqual(participant.name, "Alice")
        XCTAssertEqual(participant.linkedAccountId, "account-123")
        XCTAssertEqual(participant.linkedAccountEmail, "alice@example.com")
    }
    
    func testConvexParticipantDTO_toExpenseParticipant_Unlinked() {
        let dto = ConvexParticipantDTO(
            member_id: "550e8400-e29b-41d4-a716-446655440000",
            name: "Bob",
            linked_account_id: nil,
            linked_account_email: nil
        )
        
        let participant = dto.toExpenseParticipant()
        
        XCTAssertEqual(participant.name, "Bob")
        XCTAssertNil(participant.linkedAccountId)
    }
    
    // MARK: - ConvexGroupDTO toSpendingGroup Tests
    
    func testConvexGroupDTO_toSpendingGroup_ValidId_ReturnsGroup() {
        let dto = ConvexGroupDTO(
            id: "550e8400-e29b-41d4-a716-446655440000",
            name: "Roommates",
            created_at: 1704067200000,
            members: [],
            is_direct: false,
            is_payback_generated_mock_data: false
        )
        
        let group = dto.toSpendingGroup()
        
        XCTAssertNotNil(group)
        XCTAssertEqual(group?.name, "Roommates")
    }
    
    func testConvexGroupDTO_toSpendingGroup_InvalidId_ReturnsNil() {
        let dto = ConvexGroupDTO(
            id: "not-a-uuid",
            name: "Test",
            created_at: 1704067200000,
            members: [],
            is_direct: nil,
            is_payback_generated_mock_data: nil
        )
        
        XCTAssertNil(dto.toSpendingGroup())
    }
    
    func testConvexGroupDTO_toSpendingGroup_NilOptionals_DefaultsToFalse() {
        let dto = ConvexGroupDTO(
            id: "550e8400-e29b-41d4-a716-446655440000",
            name: "Test",
            created_at: 1704067200000,
            members: [],
            is_direct: nil,
            is_payback_generated_mock_data: nil
        )
        
        let group = dto.toSpendingGroup()
        
        XCTAssertNotNil(group)
        XCTAssertFalse(group?.isDirect ?? true)
        XCTAssertFalse(group?.isDebug ?? true)
    }
    
    // MARK: - ConvexGroupMemberDTO toGroupMember Tests
    
    func testConvexGroupMemberDTO_toGroupMember_ValidId_ReturnsMember() {
        let dto = ConvexGroupMemberDTO(
            id: "550e8400-e29b-41d4-a716-446655440000",
            name: "Alice",
            profile_image_url: nil,
            profile_avatar_color: nil
        )
        
        let member = dto.toGroupMember()
        
        XCTAssertNotNil(member)
        XCTAssertEqual(member?.name, "Alice")
    }
    
    func testConvexGroupMemberDTO_toGroupMember_InvalidId_ReturnsNil() {
        let dto = ConvexGroupMemberDTO(
            id: "invalid",
            name: "Bob",
            profile_image_url: nil,
            profile_avatar_color: nil
        )
        
        XCTAssertNil(dto.toGroupMember())
    }
    
    // MARK: - ConvexAccountFriendDTO toAccountFriend Tests
    
    func testConvexAccountFriendDTO_toAccountFriend_ValidId_ReturnsFriend() {
        let dto = ConvexAccountFriendDTO(
            member_id: "550e8400-e29b-41d4-a716-446655440000",
            name: "Alice",
            nickname: "Ali",
            original_name: nil,
            has_linked_account: true,
            linked_account_id: "account-123",
            linked_account_email: "alice@example.com",
            profile_image_url: nil,
            profile_avatar_color: nil
        )
        
        let friend = dto.toAccountFriend()
        
        XCTAssertNotNil(friend)
        XCTAssertEqual(friend?.name, "Alice")
        XCTAssertEqual(friend?.nickname, "Ali")
        XCTAssertTrue(friend?.hasLinkedAccount ?? false)
    }
    
    func testConvexAccountFriendDTO_toAccountFriend_InvalidId_ReturnsNil() {
        let dto = ConvexAccountFriendDTO(
            member_id: "invalid",
            name: "Bob",
            nickname: nil,
            original_name: nil,
            has_linked_account: nil,
            linked_account_id: nil,
            linked_account_email: nil,
            profile_image_url: nil,
            profile_avatar_color: nil
        )
        
        XCTAssertNil(dto.toAccountFriend())
    }
    
    func testConvexAccountFriendDTO_toAccountFriend_NilHasLinkedAccount_DefaultsToFalse() {
        let dto = ConvexAccountFriendDTO(
            member_id: "550e8400-e29b-41d4-a716-446655440000",
            name: "Charlie",
            nickname: nil,
            original_name: nil,
            has_linked_account: nil,
            linked_account_id: nil,
            linked_account_email: nil,
            profile_image_url: nil,
            profile_avatar_color: nil
        )
        
        let friend = dto.toAccountFriend()
        
        XCTAssertNotNil(friend)
        XCTAssertFalse(friend?.hasLinkedAccount ?? true)
    }
    
    // MARK: - ConvexUserAccountDTO toUserAccount Tests
    
    func testConvexUserAccountDTO_toUserAccount_MapsAllFields() {
        let dto = ConvexUserAccountDTO(
            id: "user-123",
            email: "test@example.com",
            display_name: "Example User",
            profile_image_url: nil,
            profile_avatar_color: nil
        )
        
        let account = dto.toUserAccount()
        
        XCTAssertEqual(account.id, "user-123")
        XCTAssertEqual(account.email, "test@example.com")
        XCTAssertEqual(account.displayName, "Example User")
    }
    
    func testConvexUserAccountDTO_toUserAccount_NilDisplayName_UsesEmail() {
        let dto = ConvexUserAccountDTO(
            id: "user-456",
            email: "fallback@example.com",
            display_name: nil,
            profile_image_url: nil,
            profile_avatar_color: nil
        )
        
        let account = dto.toUserAccount()
        
        XCTAssertEqual(account.displayName, "fallback@example.com")
    }
    
    // MARK: - ConvexLinkRequestDTO toLinkRequest Tests
    
    func testConvexLinkRequestDTO_toLinkRequest_ValidData_ReturnsRequest() {
        let dto = ConvexLinkRequestDTO(
            id: "550e8400-e29b-41d4-a716-446655440000",
            requester_id: "user-123",
            requester_email: "requester@example.com",
            requester_name: "John",
            recipient_email: "recipient@example.com",
            target_member_id: "661e8400-e29b-41d4-a716-446655440001",
            target_member_name: "Jane",
            status: "pending",
            created_at: 1704067200000,
            expires_at: 1704672000000,
            rejected_at: nil
        )
        
        let request = dto.toLinkRequest()
        
        XCTAssertNotNil(request)
        XCTAssertEqual(request?.status, .pending)
        XCTAssertEqual(request?.requesterEmail, "requester@example.com")
    }
    
    func testConvexLinkRequestDTO_toLinkRequest_InvalidId_ReturnsNil() {
        let dto = ConvexLinkRequestDTO(
            id: "invalid",
            requester_id: "user-123",
            requester_email: "test@example.com",
            requester_name: "Test",
            recipient_email: "other@example.com",
            target_member_id: "also-invalid",
            target_member_name: "Other",
            status: "pending",
            created_at: 1704067200000,
            expires_at: 1704672000000,
            rejected_at: nil
        )
        
        XCTAssertNil(dto.toLinkRequest())
    }
    
    func testConvexLinkRequestDTO_toLinkRequest_InvalidStatus_ReturnsNil() {
        let dto = ConvexLinkRequestDTO(
            id: "550e8400-e29b-41d4-a716-446655440000",
            requester_id: "user-123",
            requester_email: "test@example.com",
            requester_name: "Test",
            recipient_email: "other@example.com",
            target_member_id: "661e8400-e29b-41d4-a716-446655440001",
            target_member_name: "Other",
            status: "unknown_status",
            created_at: 1704067200000,
            expires_at: 1704672000000,
            rejected_at: nil
        )
        
        XCTAssertNil(dto.toLinkRequest())
    }
    
    // MARK: - ConvexInviteTokenDTO toInviteToken Tests
    
    func testConvexInviteTokenDTO_toInviteToken_ValidData_ReturnsToken() {
        let dto = ConvexInviteTokenDTO(
            id: "550e8400-e29b-41d4-a716-446655440000",
            creator_id: "user-123",
            creator_email: "creator@example.com",
            creator_name: nil,
            creator_profile_image_url: nil,
            target_member_id: "661e8400-e29b-41d4-a716-446655440001",
            target_member_name: "Friend",
            created_at: 1704067200000,
            expires_at: 1706745600000,
            claimed_by: nil,
            claimed_at: nil
        )
        
        let token = dto.toInviteToken()
        
        XCTAssertNotNil(token)
        XCTAssertEqual(token?.creatorId, "user-123")
        XCTAssertNil(token?.claimedBy)
    }
    
    func testConvexInviteTokenDTO_toInviteToken_InvalidId_ReturnsNil() {
        let dto = ConvexInviteTokenDTO(
            id: "invalid",
            creator_id: "user-123",
            creator_email: "test@example.com",
            creator_name: nil,
            creator_profile_image_url: nil,
            target_member_id: "also-invalid",
            target_member_name: "Friend",
            created_at: 1704067200000,
            expires_at: 1706745600000,
            claimed_by: nil,
            claimed_at: nil
        )
        
        XCTAssertNil(dto.toInviteToken())
    }
    
    func testConvexInviteTokenDTO_toInviteToken_Claimed_ReturnsClaimInfo() {
        let dto = ConvexInviteTokenDTO(
            id: "550e8400-e29b-41d4-a716-446655440000",
            creator_id: "user-123",
            creator_email: "test@example.com",
            creator_name: nil,
            creator_profile_image_url: nil,
            target_member_id: "661e8400-e29b-41d4-a716-446655440001",
            target_member_name: "Friend",
            created_at: 1704067200000,
            expires_at: 1706745600000,
            claimed_by: "claimer-456",
            claimed_at: 1705000000000
        )
        
        let token = dto.toInviteToken()
        
        XCTAssertNotNil(token)
        XCTAssertEqual(token?.claimedBy, "claimer-456")
        XCTAssertNotNil(token?.claimedAt)
    }
}
