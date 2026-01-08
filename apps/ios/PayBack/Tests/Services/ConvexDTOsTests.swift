import XCTest
@testable import PayBack

/// Comprehensive tests for Convex DTO mapping logic
final class ConvexDTOsTests: XCTestCase {
    
    // MARK: - ConvexExpenseDTO Tests
    
    func testConvexExpenseDTO_toExpense_MapsAllFields() {
        let dto = ConvexExpenseDTO(
            id: "550e8400-e29b-41d4-a716-446655440001",
            group_id: "550e8400-e29b-41d4-a716-446655440002",
            description: "Dinner",
            date: 1704067200000, // 2024-01-01 00:00:00 UTC in ms
            total_amount: 100.50,
            paid_by_member_id: "550e8400-e29b-41d4-a716-446655440003",
            involved_member_ids: ["550e8400-e29b-41d4-a716-446655440003", "550e8400-e29b-41d4-a716-446655440004"],
            splits: [
                ConvexSplitDTO(id: "550e8400-e29b-41d4-a716-446655440005", member_id: "550e8400-e29b-41d4-a716-446655440003", amount: 50.25, is_settled: false),
                ConvexSplitDTO(id: "550e8400-e29b-41d4-a716-446655440006", member_id: "550e8400-e29b-41d4-a716-446655440004", amount: 50.25, is_settled: true)
            ],
            is_settled: false,
            owner_email: "owner@test.com",
            owner_account_id: "owner-account-id",
            participant_member_ids: nil,
            participants: nil
        )
        
        let expense = dto.toExpense()
        
        XCTAssertEqual(expense.id.uuidString.uppercased(), "550E8400-E29B-41D4-A716-446655440001")
        XCTAssertEqual(expense.groupId.uuidString.uppercased(), "550E8400-E29B-41D4-A716-446655440002")
        XCTAssertEqual(expense.description, "Dinner")
        XCTAssertEqual(expense.totalAmount, 100.50)
        XCTAssertEqual(expense.isSettled, false)
        XCTAssertEqual(expense.involvedMemberIds.count, 2)
        XCTAssertEqual(expense.splits.count, 2)
    }
    
    func testConvexExpenseDTO_toExpense_InvalidUUID_GeneratesNewUUID() {
        let dto = ConvexExpenseDTO(
            id: "invalid-uuid",
            group_id: "also-invalid",
            description: "Test",
            date: 1704067200000,
            total_amount: 50.0,
            paid_by_member_id: "invalid",
            involved_member_ids: [],
            splits: [],
            is_settled: false,
            owner_email: nil,
            owner_account_id: nil,
            participant_member_ids: nil,
            participants: nil
        )
        
        let expense = dto.toExpense()
        
        // Should generate new UUIDs for invalid strings
        XCTAssertNotNil(expense.id)
        XCTAssertNotNil(expense.groupId)
        XCTAssertNotNil(expense.paidByMemberId)
    }
    
    func testConvexExpenseDTO_toExpense_DateConversion() {
        let dto = ConvexExpenseDTO(
            id: "550e8400-e29b-41d4-a716-446655440001",
            group_id: "550e8400-e29b-41d4-a716-446655440002",
            description: "Test",
            date: 1704067200000, // 2024-01-01 00:00:00 UTC
            total_amount: 10.0,
            paid_by_member_id: "550e8400-e29b-41d4-a716-446655440003",
            involved_member_ids: [],
            splits: [],
            is_settled: false,
            owner_email: nil,
            owner_account_id: nil,
            participant_member_ids: nil,
            participants: nil
        )
        
        let expense = dto.toExpense()
        
        // Verify date is correctly converted from ms to Date
        XCTAssertEqual(expense.date.timeIntervalSince1970, 1704067200.0, accuracy: 1.0)
    }
    
    // MARK: - ConvexSplitDTO Tests
    
    func testConvexSplitDTO_toExpenseSplit_MapsAllFields() {
        let dto = ConvexSplitDTO(
            id: "550e8400-e29b-41d4-a716-446655440001",
            member_id: "550e8400-e29b-41d4-a716-446655440002",
            amount: 75.50,
            is_settled: true
        )
        
        let split = dto.toExpenseSplit()
        
        XCTAssertEqual(split.id.uuidString.uppercased(), "550E8400-E29B-41D4-A716-446655440001")
        XCTAssertEqual(split.memberId.uuidString.uppercased(), "550E8400-E29B-41D4-A716-446655440002")
        XCTAssertEqual(split.amount, 75.50)
        XCTAssertEqual(split.isSettled, true)
    }
    
    func testConvexSplitDTO_toExpenseSplit_ZeroAmount() {
        let dto = ConvexSplitDTO(
            id: "550e8400-e29b-41d4-a716-446655440001",
            member_id: "550e8400-e29b-41d4-a716-446655440002",
            amount: 0.0,
            is_settled: false
        )
        
        let split = dto.toExpenseSplit()
        XCTAssertEqual(split.amount, 0.0)
    }
    
    func testConvexSplitDTO_toExpenseSplit_NegativeAmount() {
        let dto = ConvexSplitDTO(
            id: "550e8400-e29b-41d4-a716-446655440001",
            member_id: "550e8400-e29b-41d4-a716-446655440002",
            amount: -25.0,
            is_settled: false
        )
        
        let split = dto.toExpenseSplit()
        XCTAssertEqual(split.amount, -25.0)
    }
    
    // MARK: - ConvexParticipantDTO Tests
    
    func testConvexParticipantDTO_toExpenseParticipant_FullyPopulated() {
        let dto = ConvexParticipantDTO(
            member_id: "550e8400-e29b-41d4-a716-446655440001",
            name: "John Doe",
            linked_account_id: "account-123",
            linked_account_email: "john@example.com"
        )
        
        let participant = dto.toExpenseParticipant()
        
        XCTAssertEqual(participant.name, "John Doe")
        XCTAssertEqual(participant.linkedAccountId, "account-123")
        XCTAssertEqual(participant.linkedAccountEmail, "john@example.com")
    }
    
    func testConvexParticipantDTO_toExpenseParticipant_NoLinkedAccount() {
        let dto = ConvexParticipantDTO(
            member_id: "550e8400-e29b-41d4-a716-446655440001",
            name: "Jane Doe",
            linked_account_id: nil,
            linked_account_email: nil
        )
        
        let participant = dto.toExpenseParticipant()
        
        XCTAssertEqual(participant.name, "Jane Doe")
        XCTAssertNil(participant.linkedAccountId)
        XCTAssertNil(participant.linkedAccountEmail)
    }
    
    // MARK: - ConvexGroupDTO Tests
    
    func testConvexGroupDTO_toSpendingGroup_MapsAllFields() {
        let dto = ConvexGroupDTO(
            id: "550e8400-e29b-41d4-a716-446655440001",
            name: "Roommates",
            created_at: 1704067200000,
            members: [
                ConvexGroupMemberDTO(id: "550e8400-e29b-41d4-a716-446655440002", name: "Alice"),
                ConvexGroupMemberDTO(id: "550e8400-e29b-41d4-a716-446655440003", name: "Bob")
            ],
            is_direct: false,
            is_payback_generated_mock_data: false
        )
        
        let group = dto.toSpendingGroup()
        
        XCTAssertNotNil(group)
        XCTAssertEqual(group?.name, "Roommates")
        XCTAssertEqual(group?.members.count, 2)
        XCTAssertEqual(group?.isDirect, false)
        XCTAssertEqual(group?.isDebug, false)
    }
    
    func testConvexGroupDTO_toSpendingGroup_DirectGroup() {
        let dto = ConvexGroupDTO(
            id: "550e8400-e29b-41d4-a716-446655440001",
            name: "Friend",
            created_at: 1704067200000,
            members: [
                ConvexGroupMemberDTO(id: "550e8400-e29b-41d4-a716-446655440002", name: "Me"),
                ConvexGroupMemberDTO(id: "550e8400-e29b-41d4-a716-446655440003", name: "Friend")
            ],
            is_direct: true,
            is_payback_generated_mock_data: nil
        )
        
        let group = dto.toSpendingGroup()
        
        XCTAssertEqual(group?.isDirect, true)
        XCTAssertEqual(group?.isDebug, false) // nil defaults to false
    }
    
    func testConvexGroupDTO_toSpendingGroup_DebugGroup() {
        let dto = ConvexGroupDTO(
            id: "550e8400-e29b-41d4-a716-446655440001",
            name: "Test Group",
            created_at: 1704067200000,
            members: [],
            is_direct: nil,
            is_payback_generated_mock_data: true
        )
        
        let group = dto.toSpendingGroup()
        
        XCTAssertEqual(group?.isDirect, false)
        XCTAssertEqual(group?.isDebug, true)
    }
    
    func testConvexGroupDTO_toSpendingGroup_InvalidUUID_ReturnsNil() {
        let dto = ConvexGroupDTO(
            id: "not-a-valid-uuid",
            name: "Test",
            created_at: 1704067200000,
            members: [],
            is_direct: nil,
            is_payback_generated_mock_data: nil
        )
        
        let group = dto.toSpendingGroup()
        XCTAssertNil(group)
    }
    
    // MARK: - ConvexGroupMemberDTO Tests
    
    func testConvexGroupMemberDTO_toGroupMember_Success() {
        let dto = ConvexGroupMemberDTO(
            id: "550e8400-e29b-41d4-a716-446655440001",
            name: "Member Name"
        )
        
        let member = dto.toGroupMember()
        
        XCTAssertNotNil(member)
        XCTAssertEqual(member?.name, "Member Name")
    }
    
    func testConvexGroupMemberDTO_toGroupMember_InvalidUUID_ReturnsNil() {
        let dto = ConvexGroupMemberDTO(
            id: "invalid",
            name: "Name"
        )
        
        let member = dto.toGroupMember()
        XCTAssertNil(member)
    }
    
    func testConvexGroupMemberDTO_toGroupMember_EmptyName() {
        let dto = ConvexGroupMemberDTO(
            id: "550e8400-e29b-41d4-a716-446655440001",
            name: ""
        )
        
        let member = dto.toGroupMember()
        
        XCTAssertNotNil(member)
        XCTAssertEqual(member?.name, "")
    }
    
    // MARK: - ConvexAccountFriendDTO Tests
    
    func testConvexAccountFriendDTO_toAccountFriend_FullyLinked() {
        let dto = ConvexAccountFriendDTO(
            member_id: "550e8400-e29b-41d4-a716-446655440001",
            name: "Best Friend",
            nickname: "BFF",
            has_linked_account: true,
            linked_account_id: "account-123",
            linked_account_email: "friend@test.com"
        )
        
        let friend = dto.toAccountFriend()
        
        XCTAssertNotNil(friend)
        XCTAssertEqual(friend?.name, "Best Friend")
        XCTAssertEqual(friend?.nickname, "BFF")
        XCTAssertEqual(friend?.hasLinkedAccount, true)
        XCTAssertEqual(friend?.linkedAccountId, "account-123")
        XCTAssertEqual(friend?.linkedAccountEmail, "friend@test.com")
    }
    
    func testConvexAccountFriendDTO_toAccountFriend_Unlinked() {
        let dto = ConvexAccountFriendDTO(
            member_id: "550e8400-e29b-41d4-a716-446655440001",
            name: "Unlinked Friend",
            nickname: nil,
            has_linked_account: nil,
            linked_account_id: nil,
            linked_account_email: nil
        )
        
        let friend = dto.toAccountFriend()
        
        XCTAssertNotNil(friend)
        XCTAssertEqual(friend?.hasLinkedAccount, false)
        XCTAssertNil(friend?.linkedAccountId)
    }
    
    func testConvexAccountFriendDTO_toAccountFriend_InvalidMemberId() {
        let dto = ConvexAccountFriendDTO(
            member_id: "not-valid",
            name: "Friend",
            nickname: nil,
            has_linked_account: nil,
            linked_account_id: nil,
            linked_account_email: nil
        )
        
        let friend = dto.toAccountFriend()
        XCTAssertNil(friend)
    }
    
    // MARK: - ConvexUserAccountDTO Tests
    
    func testConvexUserAccountDTO_toUserAccount_FullyPopulated() {
        let dto = ConvexUserAccountDTO(
            id: "account-id-123",
            email: "user@example.com",
            display_name: "User Name"
        )
        
        let account = dto.toUserAccount()
        
        XCTAssertEqual(account.id, "account-id-123")
        XCTAssertEqual(account.email, "user@example.com")
        XCTAssertEqual(account.displayName, "User Name")
    }
    
    func testConvexUserAccountDTO_toUserAccount_MinimalFields() {
        let dto = ConvexUserAccountDTO(
            id: "account-id",
            email: "minimal@test.com",
            display_name: nil
        )
        
        let account = dto.toUserAccount()
        
        XCTAssertEqual(account.id, "account-id")
        XCTAssertEqual(account.email, "minimal@test.com")
        XCTAssertEqual(account.displayName, "minimal@test.com") // Falls back to email
    }
    
    // MARK: - ConvexLinkRequestDTO Tests
    
    func testConvexLinkRequestDTO_toLinkRequest_Pending() {
        let dto = ConvexLinkRequestDTO(
            id: "550e8400-e29b-41d4-a716-446655440001",
            requester_id: "requester-account",
            requester_email: "requester@test.com",
            requester_name: "Requester Name",
            recipient_email: "recipient@test.com",
            target_member_id: "550e8400-e29b-41d4-a716-446655440002",
            target_member_name: "Target Member",
            status: "pending",
            created_at: 1704067200000,
            expires_at: 1704672000000,
            rejected_at: nil
        )
        
        let request = dto.toLinkRequest()
        
        XCTAssertNotNil(request)
        XCTAssertEqual(request?.requesterEmail, "requester@test.com")
        XCTAssertEqual(request?.recipientEmail, "recipient@test.com")
        XCTAssertEqual(request?.status, .pending)
    }
    
    func testConvexLinkRequestDTO_toLinkRequest_Accepted() {
        let dto = ConvexLinkRequestDTO(
            id: "550e8400-e29b-41d4-a716-446655440001",
            requester_id: "requester-account",
            requester_email: "requester@test.com",
            requester_name: "Requester",
            recipient_email: "recipient@test.com",
            target_member_id: "550e8400-e29b-41d4-a716-446655440002",
            target_member_name: "Target",
            status: "accepted",
            created_at: 1704067200000,
            expires_at: 1704672000000,
            rejected_at: nil
        )
        
        let request = dto.toLinkRequest()
        XCTAssertEqual(request?.status, .accepted)
    }
    
    func testConvexLinkRequestDTO_toLinkRequest_InvalidStatus_ReturnsNil() {
        let dto = ConvexLinkRequestDTO(
            id: "550e8400-e29b-41d4-a716-446655440001",
            requester_id: "requester-account",
            requester_email: "requester@test.com",
            requester_name: "Requester",
            recipient_email: "recipient@test.com",
            target_member_id: "550e8400-e29b-41d4-a716-446655440002",
            target_member_name: "Target",
            status: "unknown_status",
            created_at: 1704067200000,
            expires_at: 1704672000000,
            rejected_at: nil
        )
        
        let request = dto.toLinkRequest()
        XCTAssertNil(request)
    }
    
    func testConvexLinkRequestDTO_toLinkRequest_InvalidUUID_ReturnsNil() {
        let dto = ConvexLinkRequestDTO(
            id: "not-valid",
            requester_id: "requester-account",
            requester_email: "requester@test.com",
            requester_name: "Requester",
            recipient_email: "recipient@test.com",
            target_member_id: "also-not-valid",
            target_member_name: "Target",
            status: "pending",
            created_at: 1704067200000,
            expires_at: 1704672000000,
            rejected_at: nil
        )
        
        let request = dto.toLinkRequest()
        XCTAssertNil(request)
    }
    
    // MARK: - ConvexInviteTokenDTO Tests
    
    func testConvexInviteTokenDTO_toInviteToken_Unclaimed() {
        let dto = ConvexInviteTokenDTO(
            id: "550e8400-e29b-41d4-a716-446655440001",
            creator_id: "creator-account",
            creator_email: "creator@test.com",
            target_member_id: "550e8400-e29b-41d4-a716-446655440002",
            target_member_name: "Target Member",
            created_at: 1704067200000,
            expires_at: 1704153600000,
            claimed_by: nil,
            claimed_at: nil
        )
        
        let token = dto.toInviteToken()
        
        XCTAssertNotNil(token)
        XCTAssertEqual(token?.creatorEmail, "creator@test.com")
        XCTAssertNil(token?.claimedBy)
        XCTAssertNil(token?.claimedAt)
    }
    
    func testConvexInviteTokenDTO_toInviteToken_Claimed() {
        let dto = ConvexInviteTokenDTO(
            id: "550e8400-e29b-41d4-a716-446655440001",
            creator_id: "creator-account",
            creator_email: "creator@test.com",
            target_member_id: "550e8400-e29b-41d4-a716-446655440002",
            target_member_name: "Target Member",
            created_at: 1704067200000,
            expires_at: 1704153600000,
            claimed_by: "claimer-id",
            claimed_at: 1704100000000
        )
        
        let token = dto.toInviteToken()
        
        XCTAssertNotNil(token)
        XCTAssertEqual(token?.claimedBy, "claimer-id")
        XCTAssertNotNil(token?.claimedAt)
    }
    
    func testConvexInviteTokenDTO_toInviteToken_InvalidUUID_ReturnsNil() {
        let dto = ConvexInviteTokenDTO(
            id: "invalid",
            creator_id: "creator-account",
            creator_email: "creator@test.com",
            target_member_id: "invalid",
            target_member_name: "Target",
            created_at: 1704067200000,
            expires_at: 1704153600000,
            claimed_by: nil,
            claimed_at: nil
        )
        
        let token = dto.toInviteToken()
        XCTAssertNil(token)
    }
    
    // MARK: - Decodable Tests
    
    func testConvexExpenseDTO_Decodable() throws {
        let json = """
        {
            "id": "550e8400-e29b-41d4-a716-446655440001",
            "group_id": "550e8400-e29b-41d4-a716-446655440002",
            "description": "Test Expense",
            "date": 1704067200000,
            "total_amount": 50.0,
            "paid_by_member_id": "550e8400-e29b-41d4-a716-446655440003",
            "involved_member_ids": [],
            "splits": [],
            "is_settled": false,
            "owner_email": null,
            "owner_account_id": null,
            "participant_member_ids": null,
            "participants": null
        }
        """
        
        let data = json.data(using: .utf8)!
        let dto = try JSONDecoder().decode(ConvexExpenseDTO.self, from: data)
        
        XCTAssertEqual(dto.description, "Test Expense")
        XCTAssertEqual(dto.total_amount, 50.0)
    }
    
    func testConvexGroupDTO_Decodable() throws {
        let json = """
        {
            "id": "550e8400-e29b-41d4-a716-446655440001",
            "name": "Test Group",
            "created_at": 1704067200000,
            "members": [{"id": "550e8400-e29b-41d4-a716-446655440002", "name": "Member"}],
            "is_direct": false,
            "is_payback_generated_mock_data": false
        }
        """
        
        let data = json.data(using: .utf8)!
        let dto = try JSONDecoder().decode(ConvexGroupDTO.self, from: data)
        
        XCTAssertEqual(dto.name, "Test Group")
        XCTAssertEqual(dto.members.count, 1)
    }
}
