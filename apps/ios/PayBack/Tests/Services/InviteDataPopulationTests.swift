import XCTest
@testable import PayBack

@MainActor
final class InviteDataPopulationTests: XCTestCase {
    var sut: AppStore!
    var mockPersistence: MockPersistenceService!
    var mockAccountService: MockAccountServiceForAppStore!
    var mockExpenseCloudService: MockExpenseCloudServiceForAppStore!
    var mockGroupCloudService: MockGroupCloudServiceForAppStore!
    var mockLinkRequestService: MockLinkRequestServiceForAppStore!
    var mockInviteLinkService: MockInviteLinkServiceForTests!

    override func setUp() async throws {
        try await super.setUp()

        mockPersistence = MockPersistenceService()
        mockAccountService = MockAccountServiceForAppStore()
        mockExpenseCloudService = MockExpenseCloudServiceForAppStore()
        mockGroupCloudService = MockGroupCloudServiceForAppStore()
        mockLinkRequestService = MockLinkRequestServiceForAppStore()
        mockInviteLinkService = MockInviteLinkServiceForTests()

        sut = AppStore(
            persistence: mockPersistence,
            accountService: mockAccountService,
            expenseCloudService: mockExpenseCloudService,
            groupCloudService: mockGroupCloudService,
            linkRequestService: mockLinkRequestService,
            inviteLinkService: mockInviteLinkService,
            skipClerkInit: true
        )
    }

    override func tearDown() async throws {
        mockPersistence.reset()
        await mockAccountService.reset()
        await mockExpenseCloudService.reset()
        await mockGroupCloudService.reset()
        await mockLinkRequestService.reset()
        await mockInviteLinkService.reset()
        sut = nil
        try await super.tearDown()
    }

    func testClaimInviteToken_PopulatesGroupDataAutomatically() async throws {
        // Given
        let account = UserAccount(id: "test-user-id", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        // Initial state: No groups locally
        XCTAssertTrue(sut.groups.isEmpty)

        // Prepare the "Shared" group on the cloud mock
        // This simulates the group that the user will gain access to via the invite
        let sharedGroupId = UUID()
        let sharedGroup = SpendingGroup(
            id: sharedGroupId,
            name: "Shared Trip",
            members: [
                GroupMember(id: UUID(), name: "Creator"),
                GroupMember(id: UUID(), name: "Example User") // The user is a member on the cloud
            ]
        )
        // Add it to the cloud service ONLY (not local store)
        await mockGroupCloudService.addGroup(sharedGroup)

        // Prepare the invite token
        let tokenId = UUID()
        await mockInviteLinkService.addValidToken(
            tokenId: tokenId,
            targetMemberId: sharedGroup.members[1].id, // Matches Example User
            targetMemberName: "Example User",
            creatorEmail: "creator@example.com"
        )

        // When
        // Claim the token - this should link the account AND trigger a fetch
        try await sut.claimInviteToken(tokenId)

        // Then
        // Wait for the async fetch to complete
        // We use a small loop to wait because the fetch is fired inside a Task or async flow
        var receivedGroup = false
        for _ in 0..<10 {
            if !sut.groups.isEmpty {
                receivedGroup = true
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1s check
        }

        XCTAssertTrue(receivedGroup, "AppStore should have fetched the shared group after claiming the invite")
        XCTAssertEqual(sut.groups.first?.name, "Shared Trip")
        XCTAssertEqual(sut.groups.first?.id, sharedGroupId)
    }

    func testClaimInviteToken_PopulatesExpenseDataAutomatically() async throws {
        // Given
        let account = UserAccount(id: "test-user-id", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        XCTAssertTrue(sut.expenses.isEmpty)

        // Prepare cloud data
        let groupId = UUID()
        let creatorId = UUID()
        let userId = UUID()
        let split = ExpenseSplit(memberId: userId, amount: 50.0)
        let expense = Expense(
            groupId: groupId,
            description: "Shared Dinner",
            totalAmount: 100.0,
            paidByMemberId: creatorId,
            involvedMemberIds: [creatorId, userId],
            splits: [split]
        )

        await mockExpenseCloudService.addExpense(expense)

        // Prepare token
        let tokenId = UUID()
        await mockInviteLinkService.addValidToken(
            tokenId: tokenId,
            targetMemberId: userId,
            targetMemberName: "Example User",
            creatorEmail: "creator@example.com"
        )

        // When
        try await sut.claimInviteToken(tokenId)

        // Then
        var receivedExpense = false
        for _ in 0..<10 {
            if !sut.expenses.isEmpty {
                receivedExpense = true
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        XCTAssertTrue(receivedExpense, "AppStore should have fetched expenses after claiming")
        XCTAssertEqual(sut.expenses.first?.description, "Shared Dinner")
    }
}
