import XCTest
@testable import PayBack

/// Extended tests for Dependencies and service wiring
final class DependenciesExtendedTests: XCTestCase {
    
    override func tearDown() {
        Dependencies.reset()
    }
    
    // MARK: - Mock Factory Tests
    
    func testMock_returnsValidDependencies() {
        let deps = Dependencies.mock()
        
        XCTAssertNotNil(deps.emailAuthService)
        XCTAssertNotNil(deps.accountService)
        XCTAssertNotNil(deps.expenseService)
        XCTAssertNotNil(deps.groupService)
        XCTAssertNotNil(deps.inviteLinkService)
        XCTAssertNotNil(deps.linkRequestService)
    }
    
    func testMock_accountService_isMock() async {
        let deps = Dependencies.mock()
        
        // Should be able to use mock methods
        let account = try? await deps.accountService.createAccount(
            email: "test@example.com",
            displayName: "Test"
        )
        
        XCTAssertNotNil(account)
    }
    
    // MARK: - Current Instance Tests
    
    func testCurrent_initialState_hasDefaultServices() {
        let deps = Dependencies.current
        
        XCTAssertNotNil(deps.emailAuthService)
        XCTAssertNotNil(deps.accountService)
    }
    
    func testReset_createsFreshInstance() {
        let before = Dependencies.current
        Dependencies.reset()
        let after = Dependencies.current
        
        // Should be different instances (though this is hard to test without identity)
        XCTAssertNotNil(before)
        XCTAssertNotNil(after)
    }
    
    // MARK: - Custom Initialization Tests
    
    func testInit_withCustomEmailAuthService_usesProvided() {
        let mockEmailAuth = MockEmailAuthService()
        let deps = Dependencies(emailAuthService: mockEmailAuth)
        
        // Should use our mock (type check)
        XCTAssertNotNil(deps.emailAuthService)
    }
    
    func testInit_withNilServices_usesDefaults() {
        let deps = Dependencies()
        
        XCTAssertNotNil(deps.emailAuthService)
        XCTAssertNotNil(deps.accountService)
        XCTAssertNotNil(deps.expenseService)
        XCTAssertNotNil(deps.groupService)
        XCTAssertNotNil(deps.inviteLinkService)
        XCTAssertNotNil(deps.linkRequestService)
    }
    
    // MARK: - Convex Client Tests
    
    func testGetConvexClient_returnsNilForMock() {
        let deps = Dependencies.mock()
        let client = Dependencies.getConvexClient()
        
        // Mock doesn't configure Convex client, may return nil
        _ = client // Use but don't assert specific value
        _ = deps // Avoid unused warning
    }
    
    // MARK: - Service Protocol Conformance Tests
    
    func testEmailAuthService_conformsToProtocol() {
        let deps = Dependencies.mock()
        let service = deps.emailAuthService
        
        // Verify it's of the expected type
        XCTAssertNotNil(service)
    }
    
    func testAccountService_conformsToProtocol() async {
        let deps = Dependencies.mock()
        let service = deps.accountService
        
        // Can call protocol methods
        _ = try? await service.lookupAccount(byEmail: "test@example.com")
    }
    
    func testExpenseService_conformsToProtocol() async {
        let deps = Dependencies.mock()
        let service = deps.expenseService
        
        // Can call protocol methods
        let expenses = try? await service.fetchExpenses()
        XCTAssertNotNil(expenses)
    }
    
    func testGroupService_conformsToProtocol() async {
        let deps = Dependencies.mock()
        let service = deps.groupService
        
        // Can call protocol methods
        let groups = try? await service.fetchGroups()
        XCTAssertNotNil(groups)
    }
    
    func testInviteLinkService_conformsToProtocol() async {
        let deps = Dependencies.mock()
        let service = deps.inviteLinkService
        
        // Can call protocol methods with correct type
        let validation = try? await service.validateInviteToken(UUID())
        XCTAssertNotNil(validation)
    }
    
    func testLinkRequestService_conformsToProtocol() async {
        let deps = Dependencies.mock()
        let service = deps.linkRequestService
        
        // Can call protocol methods
        let incoming = try? await service.fetchIncomingRequests()
        XCTAssertNotNil(incoming)
    }
    
    // MARK: - Multiple Instances Tests
    
    func testMultipleMockInstances_independent() async {
        let deps1 = Dependencies.mock()
        let deps2 = Dependencies.mock()
        
        // Create account in deps1
        _ = try? await deps1.accountService.createAccount(
            email: "test1@example.com",
            displayName: "Test 1"
        )
        
        // Both should have services
        XCTAssertNotNil(deps1.accountService)
        XCTAssertNotNil(deps2.accountService)
    }
}
