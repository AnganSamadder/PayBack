import XCTest
@testable import PayBack

final class DependenciesTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        // Reset dependencies before each test
        Dependencies.reset()
    }
    
    override func tearDown() {
        Dependencies.reset()
        super.tearDown()
    }
    
    // MARK: - Reset Tests
    
    func testReset_ClearsConvexClient() {
        // After reset, no Convex client should be set
        Dependencies.reset()
        XCTAssertNil(Dependencies.getConvexClient())
    }
    
    func testReset_CanBeCalledMultipleTimes() {
        Dependencies.reset()
        Dependencies.reset()
        Dependencies.reset()
        
        // Should not crash
        XCTAssertNotNil(Dependencies.current)
    }
    
    func testReset_ResetsCurrent() {
        let beforeReset = Dependencies.current
        Dependencies.reset()
        let afterReset = Dependencies.current
        
        // Current should be a new instance
        XCTAssertNotNil(afterReset)
        XCTAssertFalse(beforeReset === afterReset)
    }
    
    // MARK: - Default Service Access Tests
    
    func testCurrentInstance_HasAccountService() {
        XCTAssertNotNil(Dependencies.current.accountService)
    }
    
    func testCurrentInstance_HasEmailAuthService() {
        XCTAssertNotNil(Dependencies.current.emailAuthService)
    }
    
    func testCurrentInstance_HasLinkRequestService() {
        XCTAssertNotNil(Dependencies.current.linkRequestService)
    }
    
    func testCurrentInstance_HasInviteLinkService() {
        XCTAssertNotNil(Dependencies.current.inviteLinkService)
    }
    
    func testCurrentInstance_HasExpenseService() {
        XCTAssertNotNil(Dependencies.current.expenseService)
    }
    
    func testCurrentInstance_HasGroupService() {
        XCTAssertNotNil(Dependencies.current.groupService)
    }
    
    // MARK: - Mock Factory Tests
    
    func testMock_ReturnsValidDependencies() {
        let deps = Dependencies.mock()
        
        XCTAssertNotNil(deps.accountService)
        XCTAssertNotNil(deps.emailAuthService)
        XCTAssertNotNil(deps.linkRequestService)
        XCTAssertNotNil(deps.inviteLinkService)
    }
    
    func testMock_WithCustomAccountService_UsesProvidedService() async throws {
        let mockAccountService = MockAccountService()
        _ = try await mockAccountService.createAccount(email: "test@test.com", displayName: "Test")
        
        let deps = Dependencies.mock(accountService: mockAccountService)
        
        let account = try await deps.accountService.lookupAccount(byEmail: "test@test.com")
        XCTAssertNotNil(account)
        XCTAssertEqual(account?.email, "test@test.com")
    }
    
    func testMock_WithCustomEmailAuthService_UsesProvidedService() {
        let mockEmailAuthService = MockEmailAuthService()
        let deps = Dependencies.mock(emailAuthService: mockEmailAuthService)
        
        XCTAssertNotNil(deps.emailAuthService)
    }
    
    // MARK: - Custom Initialization Tests
    
    func testInit_WithCustomServices_UsesProvidedServices() async throws {
        let mockAccountService = MockAccountService()
        let mockEmailAuthService = MockEmailAuthService()
        
        let deps = Dependencies(
            accountService: mockAccountService,
            emailAuthService: mockEmailAuthService
        )
        
        XCTAssertNotNil(deps.accountService)
        XCTAssertNotNil(deps.emailAuthService)
        
        // Verify it's actually using our mock
        let account = try await deps.accountService.createAccount(email: "custom@test.com", displayName: "Custom")
        XCTAssertEqual(account.email, "custom@test.com")
    }
    
    func testInit_WithNilServices_UsesDefaults() {
        let deps = Dependencies()
        
        // Should have default services (MockAccountService when no Convex client)
        XCTAssertNotNil(deps.accountService)
        XCTAssertNotNil(deps.emailAuthService)
        XCTAssertNotNil(deps.expenseService)
        XCTAssertNotNil(deps.groupService)
    }
    
    // MARK: - Convex Client Tests
    
    func testGetConvexClient_WhenNotConfigured_ReturnsNil() {
        Dependencies.reset()
        XCTAssertNil(Dependencies.getConvexClient())
    }
    
    // MARK: - Thread Safety Tests
    
    func testConcurrentAccess_DoesNotCrash() async {
        // Access services concurrently
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    _ = Dependencies.current.accountService
                    _ = Dependencies.current.emailAuthService
                    _ = Dependencies.current.linkRequestService
                    _ = Dependencies.current.inviteLinkService
                }
            }
        }
        
        XCTAssertTrue(true) // If we get here, no crash occurred
    }
    
    func testConcurrentReset_DoesNotCrash() async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    Dependencies.reset()
                }
            }
        }
        
        XCTAssertNotNil(Dependencies.current)
    }
    
    // MARK: - Mock Service Behavior Tests
    
    func testMockAccountService_WorksWithDependenciesMock() async throws {
        let deps = Dependencies.mock()
        
        // The mock account service should be functional
        let account = try await deps.accountService.createAccount(
            email: "deps-test@example.com",
            displayName: "Deps Test"
        )
        
        XCTAssertEqual(account.email, "deps-test@example.com")
        XCTAssertEqual(account.displayName, "Deps Test")
    }
    
    func testMockAccountService_CanLookupCreatedAccount() async throws {
        let deps = Dependencies.mock()
        
        _ = try await deps.accountService.createAccount(
            email: "lookup@example.com",
            displayName: "Lookup Test"
        )
        
        let found = try await deps.accountService.lookupAccount(byEmail: "lookup@example.com")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.email, "lookup@example.com")
    }
    
    func testMockAccountService_IsActorIsolated() async throws {
        let deps = Dependencies.mock()
        
        // These operations should be safe to call concurrently
        async let account1 = deps.accountService.createAccount(email: "user1@test.com", displayName: "User 1")
        async let account2 = deps.accountService.createAccount(email: "user2@test.com", displayName: "User 2")
        
        let results = try await [account1, account2]
        XCTAssertEqual(results.count, 2)
    }
}
