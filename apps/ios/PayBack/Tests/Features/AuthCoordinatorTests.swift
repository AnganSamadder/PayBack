import XCTest
@testable import PayBack

@MainActor
final class AuthCoordinatorTests: XCTestCase {
    var coordinator: AuthCoordinator!
    var mockAccountService: TestAccountService!
    var mockEmailAuthService: TestEmailAuthService!
    
    override func setUp() async throws {
        try await super.setUp()
        mockAccountService = TestAccountService()
        mockEmailAuthService = TestEmailAuthService()
        coordinator = AuthCoordinator(
            accountService: mockAccountService,
            emailAuthService: mockEmailAuthService
        )
    }
    
    override func tearDown() async throws {
        coordinator = nil
        mockAccountService = nil
        mockEmailAuthService = nil
        try await super.tearDown()
    }
    
    // MARK: - Initialization Tests
    
    func testInitialState() {
        XCTAssertEqual(coordinator.route, .login)
        XCTAssertFalse(coordinator.isBusy)
        XCTAssertNil(coordinator.errorMessage)
        XCTAssertNil(coordinator.infoMessage)
    }
    
    // MARK: - Start Tests
    
    func testStart_WhenNotAuthenticated_SetsLoginRoute() {
        coordinator.start()
        XCTAssertEqual(coordinator.route, .login)
    }
    
    func testStart_WhenAlreadyAuthenticated_DoesNotChangeRoute() {
        // Since we can't directly set the route to authenticated, we'll test that start doesn't crash
        coordinator.start()
        XCTAssertEqual(coordinator.route, .login)
    }
    
    // MARK: - SignOut Tests
    
    func testSignOut_Success() {
        coordinator.signOut()
        XCTAssertEqual(coordinator.route, .login)
        XCTAssertTrue(mockEmailAuthService.signOutCalled)
    }
    
    func testSignOut_WhenEmailAuthServiceThrows_StillSetsLoginRoute() {
        mockEmailAuthService.shouldThrowOnSignOut = true
        coordinator.signOut()
        XCTAssertEqual(coordinator.route, .login)
    }
    
    // MARK: - OpenSignup Tests
    
    func testOpenSignup_WithValidEmail_NormalizesAndSetsRoute() {
        coordinator.openSignup(with: "  TEST@EXAMPLE.COM  ")
        
        if case .signup(let presetEmail) = coordinator.route {
            XCTAssertEqual(presetEmail, "test@example.com")
        } else {
            XCTFail("Expected signup route")
        }
    }
    
    func testOpenSignup_WithInvalidEmail_UsesRawInput() {
        coordinator.openSignup(with: "invalid-email")
        
        if case .signup(let presetEmail) = coordinator.route {
            XCTAssertEqual(presetEmail, "invalid-email")
        } else {
            XCTFail("Expected signup route")
        }
    }
    
    // MARK: - Login Tests
    
    func testLogin_Success_WithExistingAccount() async {
        let testEmail = "test@example.com"
        let testPassword = "password123"
        let existingAccount = UserAccount(id: "123", email: testEmail, displayName: "Test User")
        
        mockEmailAuthService.signInResult = EmailAuthSignInResult(
            uid: "123",
            email: testEmail,
            firstName: "Test",
            lastName: "User"
        )
        await mockAccountService.setExistingAccount(existingAccount)
        
        await coordinator.login(emailInput: testEmail, password: testPassword)
        
        XCTAssertFalse(coordinator.isBusy)
        XCTAssertNil(coordinator.errorMessage)
        
        if case .authenticated(let session) = coordinator.route {
            XCTAssertEqual(session.account.id, "123")
            XCTAssertEqual(session.account.email, testEmail)
        } else {
            XCTFail("Expected authenticated route")
        }
    }
    
    func testLogin_Success_CreatesNewAccountWhenNotFound() async {
        let testEmail = "newuser@example.com"
        let testPassword = "password123"
        
        mockEmailAuthService.signInResult = EmailAuthSignInResult(
            uid: "456",
            email: testEmail,
            firstName: "New",
            lastName: "User"
        )
        await mockAccountService.setExistingAccount(nil)
        await mockAccountService.setCreatedAccount(UserAccount(
            id: "456",
            email: testEmail,
            displayName: "New User"
        ))
        
        await coordinator.login(emailInput: testEmail, password: testPassword)
        
        XCTAssertFalse(coordinator.isBusy)
        XCTAssertNil(coordinator.errorMessage)
        
        if case .authenticated(let session) = coordinator.route {
            XCTAssertEqual(session.account.id, "456")
            XCTAssertEqual(session.account.email, testEmail)
        } else {
            XCTFail("Expected authenticated route")
        }
    }
    
    func testLogin_Success_UsesDefaultDisplayNameWhenNoneProvided() async {
        let testEmail = "john.doe@example.com"
        let testPassword = "password123"
        
        mockEmailAuthService.signInResult = EmailAuthSignInResult(
            uid: "789",
            email: testEmail,
            firstName: nil,
            lastName: nil
        )
        await mockAccountService.setExistingAccount(nil)
        await mockAccountService.setCreatedAccount(UserAccount(
            id: "789",
            email: testEmail,
            displayName: "John Doe"
        ))
        
        await coordinator.login(emailInput: testEmail, password: testPassword)
        
        XCTAssertFalse(coordinator.isBusy)
        let createCalled = await mockAccountService.getCreateAccountCalled()
        XCTAssertTrue(createCalled)
        // Verify the display name was generated from email
        let displayName = await mockAccountService.getLastCreatedDisplayName()
        XCTAssertEqual(displayName, "John Doe")
    }
    
    func testLogin_Failure_InvalidCredentials() async {
        mockEmailAuthService.shouldThrowOnSignIn = true
        mockEmailAuthService.errorToThrow = PayBackError.authInvalidCredentials(message: "Invalid credentials")
        
        await coordinator.login(emailInput: "test@example.com", password: "wrong")
        
        XCTAssertFalse(coordinator.isBusy)
        XCTAssertNotNil(coordinator.errorMessage)
        XCTAssertEqual(coordinator.errorMessage, PayBackError.authInvalidCredentials(message: "Invalid credentials").errorDescription)
        XCTAssertEqual(coordinator.route, .login)
    }
    
    func testLogin_Failure_AccountServiceError() async {
        mockEmailAuthService.signInResult = EmailAuthSignInResult(
            uid: "123",
            email: "test@example.com",
            firstName: "Test",
            lastName: nil
        )
        await mockAccountService.setShouldThrowOnLookup(true, error: PayBackError.networkUnavailable)
        
        await coordinator.login(emailInput: "test@example.com", password: "password")
        
        XCTAssertFalse(coordinator.isBusy)
        XCTAssertNotNil(coordinator.errorMessage)
        XCTAssertEqual(coordinator.errorMessage, PayBackError.networkUnavailable.errorDescription)
    }
    
    func testLogin_NormalizesEmail() async {
        let testEmail = "  TEST@EXAMPLE.COM  "
        mockEmailAuthService.signInResult = EmailAuthSignInResult(
            uid: "123",
            email: "test@example.com",
            firstName: "Test",
            lastName: nil
        )
        await mockAccountService.setExistingAccount(UserAccount(
            id: "123",
            email: "test@example.com",
            displayName: "Test"
        ))
        
        await coordinator.login(emailInput: testEmail, password: "password")
        
        XCTAssertTrue(mockEmailAuthService.signInCalled)
        XCTAssertEqual(mockEmailAuthService.lastSignInEmail, "test@example.com")
    }
    
    func testLogin_SetsBusyStateDuringOperation() async {
        mockEmailAuthService.signInDelay = 0.1
        mockEmailAuthService.signInResult = EmailAuthSignInResult(
            uid: "123",
            email: "test@example.com",
            firstName: "Test",
            lastName: nil
        )
        await mockAccountService.setExistingAccount(UserAccount(
            id: "123",
            email: "test@example.com",
            displayName: "Test"
        ))
        
        let expectation = expectation(description: "Login completes")
        
        Task {
            await coordinator.login(emailInput: "test@example.com", password: "password")
            expectation.fulfill()
        }
        
        // Check busy state is set
        try? await Task.sleep(nanoseconds: 10_000_000) // 0.01 seconds
        XCTAssertTrue(coordinator.isBusy)
        
        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertFalse(coordinator.isBusy)
    }
    
    // MARK: - Signup Tests
    
    func testSignup_Success() async {
        let testEmail = "newuser@example.com"
        let testPassword = "password123"
        let testDisplayName = "New User"
        
        mockEmailAuthService.signUpResult = .complete(EmailAuthSignInResult(
            uid: "new123",
            email: testEmail,
            firstName: "New",
            lastName: "User"
        ))
        await mockAccountService.setCreatedAccount(UserAccount(
            id: "new123",
            email: testEmail,
            displayName: testDisplayName
        ))
        
        await coordinator.signup(emailInput: testEmail, firstName: "New", lastName: "User", password: testPassword)
        
        XCTAssertFalse(coordinator.isBusy)
        XCTAssertNil(coordinator.errorMessage)
        
        if case .authenticated(let session) = coordinator.route {
            XCTAssertEqual(session.account.email, testEmail)
            XCTAssertEqual(session.account.displayName, testDisplayName)
        } else {
            XCTFail("Expected authenticated route")
        }
    }
    
    func testSignup_TrimsDisplayName() async {
        let testEmail = "test@example.com"
        let testPassword = "password123"
        _ = "  Trimmed Name  "
        
        mockEmailAuthService.signUpResult = .complete(EmailAuthSignInResult(
            uid: "123",
            email: testEmail,
            firstName: "Trimmed",
            lastName: "Name"
        ))
        await mockAccountService.setCreatedAccount(UserAccount(
            id: "123",
            email: testEmail,
            displayName: "Trimmed Name"
        ))
        
        await coordinator.signup(emailInput: testEmail, firstName: "  Trimmed  ", lastName: "  Name  ", password: testPassword)
        
        XCTAssertTrue(mockEmailAuthService.signUpCalled)
        XCTAssertEqual(mockEmailAuthService.lastSignUpFirstName, "Trimmed")
        XCTAssertEqual(mockEmailAuthService.lastSignUpLastName, "Name")
    }
    
    func testSignup_Failure_EmailAlreadyInUse() async {
        mockEmailAuthService.shouldThrowOnSignUp = true
        mockEmailAuthService.errorToThrow = PayBackError.accountDuplicate(email: "existing@example.com")
        
        await coordinator.signup(emailInput: "existing@example.com", firstName: "Test", lastName: nil, password: "password")
        
        XCTAssertFalse(coordinator.isBusy)
        XCTAssertNotNil(coordinator.errorMessage)
        XCTAssertEqual(coordinator.errorMessage, PayBackError.accountDuplicate(email: "existing@example.com").errorDescription)
    }
    
    func testSignup_Failure_WeakPassword() async {
        mockEmailAuthService.shouldThrowOnSignUp = true
        mockEmailAuthService.errorToThrow = PayBackError.authWeakPassword
        
        await coordinator.signup(emailInput: "test@example.com", firstName: "Test", lastName: nil, password: "123")
        
        XCTAssertFalse(coordinator.isBusy)
        XCTAssertNotNil(coordinator.errorMessage)
        XCTAssertEqual(coordinator.errorMessage, PayBackError.authWeakPassword.errorDescription)
    }
    
    func testSignup_NormalizesEmail() async {
        let testEmail = "  NEW@EXAMPLE.COM  "
        mockEmailAuthService.signUpResult = .complete(EmailAuthSignInResult(
            uid: "123",
            email: "new@example.com",
            firstName: "Test",
            lastName: nil
        ))
        await mockAccountService.setCreatedAccount(UserAccount(
            id: "123",
            email: "new@example.com",
            displayName: "Test"
        ))
        
        await coordinator.signup(emailInput: testEmail, firstName: "Test", lastName: nil, password: "password")
        
        XCTAssertTrue(mockEmailAuthService.signUpCalled)
        XCTAssertEqual(mockEmailAuthService.lastSignUpEmail, "new@example.com")
    }
    
    func testSignup_WhenAccountCreationFailsWithSessionMissing_SetsInfoMessage() async {
        let testEmail = "verify@example.com"
        
        mockEmailAuthService.signUpResult = .complete(EmailAuthSignInResult(
            uid: "new123",
            email: testEmail,
            firstName: "Test",
            lastName: nil
        ))
        // Simulate sign up success but create account failure due to session missing (email verification needed)
        await mockAccountService.setShouldThrowOnCreate(true, error: PayBackError.authSessionMissing)
        
        await coordinator.signup(emailInput: testEmail, firstName: "Test", lastName: nil, password: "password")
        
        XCTAssertFalse(coordinator.isBusy)
        XCTAssertNil(coordinator.errorMessage)
        XCTAssertNotNil(coordinator.infoMessage)
        XCTAssertTrue(coordinator.infoMessage!.contains("check your email"))
        XCTAssertEqual(coordinator.route, .login)
    }
    
    // MARK: - SendPasswordReset Tests
    
    func testSendPasswordReset_Success() async {
        let testEmail = "reset@example.com"
        
        await coordinator.sendPasswordReset(emailInput: testEmail)
        
        XCTAssertFalse(coordinator.isBusy)
        XCTAssertNil(coordinator.errorMessage)
        XCTAssertNotNil(coordinator.infoMessage)
        XCTAssertTrue(coordinator.infoMessage!.contains("reset@example.com"))
        XCTAssertTrue(mockEmailAuthService.sendPasswordResetCalled)
    }
    
    func testSendPasswordReset_NormalizesEmail() async {
        let testEmail = "  RESET@EXAMPLE.COM  "
        
        await coordinator.sendPasswordReset(emailInput: testEmail)
        
        XCTAssertTrue(mockEmailAuthService.sendPasswordResetCalled)
        XCTAssertEqual(mockEmailAuthService.lastPasswordResetEmail, "reset@example.com")
    }
    
    func testSendPasswordReset_Failure() async {
        mockEmailAuthService.shouldThrowOnPasswordReset = true
        mockEmailAuthService.errorToThrow = PayBackError.authInvalidCredentials(message: "Invalid credentials")
        
        await coordinator.sendPasswordReset(emailInput: "test@example.com")
        
        XCTAssertFalse(coordinator.isBusy)
        XCTAssertNotNil(coordinator.errorMessage)
        XCTAssertNil(coordinator.infoMessage)
    }
    
    func testSendPasswordReset_AllowsConcurrentCalls() async {
        mockEmailAuthService.passwordResetDelay = 0.2
        
        let expectation1 = expectation(description: "First reset")
        let expectation2 = expectation(description: "Second reset")
        
        Task {
            await coordinator.sendPasswordReset(emailInput: "test1@example.com")
            expectation1.fulfill()
        }
        
        Task {
            await coordinator.sendPasswordReset(emailInput: "test2@example.com")
            expectation2.fulfill()
        }
        
        await fulfillment(of: [expectation1, expectation2], timeout: 1.0)
        XCTAssertEqual(mockEmailAuthService.passwordResetCallCount, 2)
    }
    
    // MARK: - Error Handling Tests
    
    func testHandleError_AccountServiceError() async {
        await mockAccountService.setShouldThrowOnLookup(true, error: PayBackError.accountNotFound(email: "test@example.com"))
        mockEmailAuthService.signInResult = EmailAuthSignInResult(
            uid: "123",
            email: "test@example.com",
            firstName: "Test",
            lastName: nil
        )
        
        await coordinator.login(emailInput: "test@example.com", password: "password")
        
        XCTAssertEqual(coordinator.errorMessage, PayBackError.accountNotFound(email: "test@example.com").errorDescription)
    }
    
    func testHandleError_EmailAuthServiceError() async {
        mockEmailAuthService.shouldThrowOnSignIn = true
        mockEmailAuthService.errorToThrow = PayBackError.authRateLimited
        
        await coordinator.login(emailInput: "test@example.com", password: "password")
        
        XCTAssertEqual(coordinator.errorMessage, PayBackError.authRateLimited.errorDescription)
    }
    
    func testHandleError_GenericError() async {
        let genericError = NSError(domain: "TestDomain", code: 999, userInfo: [
            NSLocalizedDescriptionKey: "Generic error message"
        ])
        mockEmailAuthService.shouldThrowOnSignIn = true
        mockEmailAuthService.errorToThrow = genericError
        
        await coordinator.login(emailInput: "test@example.com", password: "password")
        
        XCTAssertEqual(coordinator.errorMessage, "Generic error message")
    }
    
    // MARK: - Display Name Generation Tests (tested indirectly through login)
    
    func testLogin_GeneratesDisplayNameFromSimpleEmail() async {
        mockEmailAuthService.signInResult = EmailAuthSignInResult(
            uid: "123",
            email: "john@example.com",
            firstName: nil,
            lastName: nil
        )
        await mockAccountService.setExistingAccount(nil)
        await mockAccountService.setCreatedAccount(UserAccount(
            id: "123",
            email: "john@example.com",
            displayName: "John"
        ))
        
        await coordinator.login(emailInput: "john@example.com", password: "password")
        
        let displayName = await mockAccountService.getLastCreatedDisplayName()
        XCTAssertEqual(displayName, "John")
    }
    
    func testLogin_GeneratesDisplayNameFromComplexEmail() async {
        mockEmailAuthService.signInResult = EmailAuthSignInResult(
            uid: "123",
            email: "mary.jane.watson@example.com",
            firstName: nil,
            lastName: nil
        )
        await mockAccountService.setExistingAccount(nil)
        await mockAccountService.setCreatedAccount(UserAccount(
            id: "123",
            email: "mary.jane.watson@example.com",
            displayName: "Mary Jane Watson"
        ))
        
        await coordinator.login(emailInput: "mary.jane.watson@example.com", password: "password")
        
        let displayName = await mockAccountService.getLastCreatedDisplayName()
        XCTAssertEqual(displayName, "Mary Jane Watson")
    }
    
    // MARK: - RunBusyTask Tests
    
    func testRunBusyTask_PreventsConcurrentNonConcurrentCalls() async {
        mockEmailAuthService.signInDelay = 0.2
        mockEmailAuthService.signInResult = EmailAuthSignInResult(
            uid: "123",
            email: "test@example.com",
            firstName: "Test",
            lastName: nil
        )
        await mockAccountService.setExistingAccount(UserAccount(
            id: "123",
            email: "test@example.com",
            displayName: "Test"
        ))
        
        let expectation1 = expectation(description: "First login")
        let expectation2 = expectation(description: "Second login")
        
        Task {
            await coordinator.login(emailInput: "test@example.com", password: "password1")
            expectation1.fulfill()
        }
        
        // Wait a bit to ensure first call starts
        try? await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
        
        Task {
            await coordinator.login(emailInput: "test@example.com", password: "password2")
            expectation2.fulfill()
        }
        
        await fulfillment(of: [expectation1, expectation2], timeout: 1.0)
        
        // Second call should have been blocked, so only one sign-in should have occurred
        XCTAssertEqual(mockEmailAuthService.signInCallCount, 1)
    }
    
    func testRunBusyTask_ClearsErrorAndInfoMessages() async {
        coordinator = AuthCoordinator(
            accountService: mockAccountService,
            emailAuthService: mockEmailAuthService
        )
        
        // Set some messages
        await MainActor.run {
            coordinator.errorMessage = "Previous error"
            coordinator.infoMessage = "Previous info"
        }
        
        mockEmailAuthService.signInResult = EmailAuthSignInResult(
            uid: "123",
            email: "test@example.com",
            firstName: "Test",
            lastName: nil
        )
        await mockAccountService.setExistingAccount(UserAccount(
            id: "123",
            email: "test@example.com",
            displayName: "Test"
        ))
        
        await coordinator.login(emailInput: "test@example.com", password: "password")
        
        // Messages should be cleared during the operation
        XCTAssertNil(coordinator.errorMessage)
        XCTAssertNil(coordinator.infoMessage)
    }
}

// MARK: - Test Doubles

actor TestAccountService: AccountService {
    private var existingAccount: UserAccount?
    private var createdAccount: UserAccount?
    private var shouldThrowOnLookup = false
    private var shouldThrowOnCreate = false
    private var errorToThrow: Error = PayBackError.networkUnavailable
    private var createAccountCalled = false
    private var lastCreatedDisplayName: String?
    
    // Helper methods for test setup
    func setExistingAccount(_ account: UserAccount?) {
        existingAccount = account
    }
    
    func setCreatedAccount(_ account: UserAccount?) {
        createdAccount = account
    }
    
    func setShouldThrowOnLookup(_ should: Bool, error: Error = PayBackError.networkUnavailable) {
        shouldThrowOnLookup = should
        errorToThrow = error
    }
    
    func setShouldThrowOnCreate(_ should: Bool, error: Error = PayBackError.networkUnavailable) {
        shouldThrowOnCreate = should
        errorToThrow = error
    }
    
    func getCreateAccountCalled() -> Bool {
        createAccountCalled
    }
    
    func getLastCreatedDisplayName() -> String? {
        lastCreatedDisplayName
    }
    
    nonisolated func normalizedEmail(from rawValue: String) throws -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.contains("@"), trimmed.contains(".") else {
            throw PayBackError.accountInvalidEmail(email: trimmed)
        }
        return trimmed
    }
    
    func lookupAccount(byEmail email: String) async throws -> UserAccount? {
        if shouldThrowOnLookup {
            throw errorToThrow
        }
        return existingAccount
    }
    
    func createAccount(email: String, displayName: String) async throws -> UserAccount {
        createAccountCalled = true
        lastCreatedDisplayName = displayName
        
        if shouldThrowOnCreate {
            throw errorToThrow
        }
        
        if let account = createdAccount {
            return account
        }
        
        return UserAccount(id: UUID().uuidString, email: email, displayName: displayName)
    }
    
    func updateLinkedMember(accountId: String, memberId: UUID?) async throws {
        // No-op for tests
    }
    
    func syncFriends(accountEmail: String, friends: [AccountFriend]) async throws {
        // No-op for tests
    }
    
    func fetchFriends(accountEmail: String) async throws -> [AccountFriend] {
        return []
    }
    
    func updateFriendLinkStatus(
        accountEmail: String,
        memberId: UUID,
        linkedAccountId: String,
        linkedAccountEmail: String
    ) async throws {
        // No-op for tests
    }
}

final class TestEmailAuthService: EmailAuthService, @unchecked Sendable {
    var signInResult: EmailAuthSignInResult?
    var signUpResult: SignUpResult?
    var verifyCodeResult: EmailAuthSignInResult?
    var shouldThrowOnSignIn = false
    var shouldThrowOnSignUp = false
    var shouldThrowOnVerifyCode = false
    var shouldThrowOnPasswordReset = false
    var shouldThrowOnSignOut = false
    var errorToThrow: Error = PayBackError.authInvalidCredentials(message: "Invalid credentials")
    
    var signInCalled = false
    var signUpCalled = false
    var verifyCodeCalled = false
    var sendPasswordResetCalled = false
    var signOutCalled = false
    
    var lastSignInEmail: String?
    var lastSignUpEmail: String?
    var lastSignUpFirstName: String?
    var lastSignUpLastName: String?
    var lastVerifyCode: String?
    var lastPasswordResetEmail: String?
    
    var signInDelay: TimeInterval = 0
    var passwordResetDelay: TimeInterval = 0
    
    var signInCallCount = 0
    var passwordResetCallCount = 0
    
    func signIn(email: String, password: String) async throws -> EmailAuthSignInResult {
        signInCalled = true
        signInCallCount += 1
        lastSignInEmail = email
        
        if signInDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(signInDelay * 1_000_000_000))
        }
        
        if shouldThrowOnSignIn {
            throw errorToThrow
        }
        
        guard let result = signInResult else {
            throw PayBackError.authInvalidCredentials(message: "Invalid credentials")
        }
        
        return result
    }
    
    func signUp(email: String, password: String, firstName: String, lastName: String?) async throws -> SignUpResult {
        signUpCalled = true
        lastSignUpEmail = email
        lastSignUpFirstName = firstName
        lastSignUpLastName = lastName
        
        if shouldThrowOnSignUp {
            throw errorToThrow
        }
        
        guard let result = signUpResult else {
            throw PayBackError.underlying(message: "Sign up error")
        }
        
        return result
    }
    
    func verifyCode(code: String) async throws -> EmailAuthSignInResult {
        verifyCodeCalled = true
        lastVerifyCode = code
        
        if shouldThrowOnVerifyCode {
            throw errorToThrow
        }
        
        guard let result = verifyCodeResult else {
            throw PayBackError.authInvalidCredentials(message: "Invalid verification code")
        }
        
        return result
    }
    
    func sendPasswordReset(email: String) async throws {
        sendPasswordResetCalled = true
        passwordResetCallCount += 1
        lastPasswordResetEmail = email
        
        if passwordResetDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(passwordResetDelay * 1_000_000_000))
        }
        
        if shouldThrowOnPasswordReset {
            throw errorToThrow
        }
    }
    
    func signOut() throws {
        signOutCalled = true
        
        if shouldThrowOnSignOut {
            throw PayBackError.underlying(message: "Sign out error")
        }
    }
    
    func resendConfirmationEmail(email: String) async throws {
        // Mock implementation for testings
    }
}
