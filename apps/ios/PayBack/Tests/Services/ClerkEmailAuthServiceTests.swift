import XCTest
import ClerkKit
@testable import PayBack

@MainActor
final class ClerkEmailAuthServiceTests: XCTestCase {
    private let requestedUser = ClerkEmailUser(
        id: "user-123",
        email: "person@example.com",
        firstName: "Test",
        lastName: "Person"
    )

    func testSignInWithMatchingActiveSessionReusesUser() async throws {
        let client = StubClerkEmailAuthClient(sessionState: .active(requestedUser))
        let service = ClerkEmailAuthService(client: client)

        let result = try await service.signIn(email: "PERSON@example.com", password: "unused")

        XCTAssertEqual(result.uid, requestedUser.id)
        XCTAssertEqual(client.signInCallCount, 0)
        XCTAssertEqual(client.signOutCallCount, 0)
    }

    func testSignInClearsInactiveSessionBeforeAuthenticating() async throws {
        let client = StubClerkEmailAuthClient(
            sessionState: .inactive,
            signInAttempt: .complete(requestedUser)
        )
        let service = ClerkEmailAuthService(client: client)

        let result = try await service.signIn(email: requestedUser.email, password: "password")

        XCTAssertEqual(result.uid, requestedUser.id)
        XCTAssertEqual(client.signOutCallCount, 1)
        XCTAssertEqual(client.signInCallCount, 1)
    }

    func testSignInClearsMismatchedActiveSessionBeforeAuthenticating() async throws {
        let otherUser = ClerkEmailUser(id: "other", email: "other@example.com", firstName: nil, lastName: nil)
        let client = StubClerkEmailAuthClient(
            sessionState: .active(otherUser),
            signInAttempt: .complete(requestedUser)
        )
        let service = ClerkEmailAuthService(client: client)

        _ = try await service.signIn(email: requestedUser.email, password: "password")

        XCTAssertEqual(client.signOutCallCount, 1)
        XCTAssertEqual(client.signInCallCount, 1)
    }

    func testCompletedSignInWithoutActiveUserThrowsSessionMissing() async {
        let client = StubClerkEmailAuthClient(signInAttempt: .complete(nil))
        let service = ClerkEmailAuthService(client: client)

        await assertThrowsPayBackError(.authSessionMissing) {
            try await service.signIn(email: self.requestedUser.email, password: "password")
        }
    }

    func testCompletedSignInUsesRequestedEmailWhenClerkUserHasNoPrimaryEmail() async throws {
        let userWithoutEmail = ClerkEmailUser(
            id: requestedUser.id,
            email: "",
            firstName: requestedUser.firstName,
            lastName: requestedUser.lastName
        )
        let service = ClerkEmailAuthService(
            client: StubClerkEmailAuthClient(signInAttempt: .complete(userWithoutEmail))
        )

        let result = try await service.signIn(email: requestedUser.email, password: "password")

        XCTAssertEqual(result.email, requestedUser.email)
    }

    func testIncompleteSignInReturnsActionableUnsupportedStepError() async {
        let service = ClerkEmailAuthService(client: StubClerkEmailAuthClient(signInAttempt: .incomplete))

        do {
            _ = try await service.signIn(email: requestedUser.email, password: "password")
            XCTFail("Expected sign-in to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("additional sign-in step"))
        }
    }

    func testSignUpReturnsEmailVerificationRequirement() async throws {
        let client = StubClerkEmailAuthClient(signUpAttempt: .needsVerification)
        let service = ClerkEmailAuthService(client: client)

        let result = try await service.signUp(
            email: requestedUser.email,
            password: "password",
            firstName: "Test",
            lastName: "Person"
        )

        guard case .needsVerification(let email) = result else {
            return XCTFail("Expected email verification")
        }
        XCTAssertEqual(email, requestedUser.email)
    }

    func testUnsupportedSignUpRequirementsReturnActionableError() async {
        let service = ClerkEmailAuthService(client: StubClerkEmailAuthClient(signUpAttempt: .unsupported))

        do {
            _ = try await service.signUp(
                email: requestedUser.email,
                password: "password",
                firstName: "Test",
                lastName: nil
            )
            XCTFail("Expected sign-up to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("additional step"))
        }
    }

    func testCompletedSignUpUsesRequestedEmailWhenClerkUserHasNoPrimaryEmail() async throws {
        let userWithoutEmail = ClerkEmailUser(
            id: requestedUser.id,
            email: "",
            firstName: requestedUser.firstName,
            lastName: requestedUser.lastName
        )
        let service = ClerkEmailAuthService(
            client: StubClerkEmailAuthClient(signUpAttempt: .complete(userWithoutEmail))
        )

        let result = try await service.signUp(
            email: requestedUser.email,
            password: "password",
            firstName: "Test",
            lastName: "Person"
        )

        guard case .complete(let user) = result else {
            return XCTFail("Expected completed sign-up")
        }
        XCTAssertEqual(user.email, requestedUser.email)
    }

    func testLiveClientClassifiesOnlyEmailVerificationAsSupported() {
        XCTAssertEqual(
            LiveClerkEmailAuthClient.signUpDisposition(
                status: .missingRequirements,
                missingFields: [],
                unverifiedFields: [.emailAddress]
            ),
            .sendEmailVerification
        )
        XCTAssertEqual(
            LiveClerkEmailAuthClient.signUpDisposition(
                status: .missingRequirements,
                missingFields: [.firstName],
                unverifiedFields: [.emailAddress]
            ),
            .unsupported
        )
        XCTAssertEqual(
            LiveClerkEmailAuthClient.signUpDisposition(
                status: .missingRequirements,
                missingFields: [],
                unverifiedFields: [.emailAddress, .phoneNumber]
            ),
            .unsupported
        )
        XCTAssertEqual(
            LiveClerkEmailAuthClient.signUpDisposition(
                status: .complete,
                missingFields: [],
                unverifiedFields: []
            ),
            .complete
        )
        XCTAssertEqual(
            LiveClerkEmailAuthClient.signUpDisposition(
                status: .abandoned,
                missingFields: [],
                unverifiedFields: []
            ),
            .incomplete
        )
    }

    func testLiveClientEmailResolutionPrefersPrimaryThenFallback() {
        XCTAssertEqual(
            LiveClerkEmailAuthClient.resolveEmail(
                primaryEmail: requestedUser.email,
                fallbackEmail: "fallback@example.com"
            ),
            requestedUser.email
        )
        XCTAssertEqual(
            LiveClerkEmailAuthClient.resolveEmail(
                primaryEmail: "  ",
                fallbackEmail: requestedUser.email
            ),
            requestedUser.email
        )
    }

    func testCompletedVerificationWithoutActiveUserThrowsSessionMissing() async {
        let client = StubClerkEmailAuthClient(verificationAttempt: .complete(nil))
        let service = ClerkEmailAuthService(client: client)

        await assertThrowsPayBackError(.authSessionMissing) {
            try await service.verifyCode(code: "123456")
        }
    }

    func testActiveSessionSkipsDuplicateVerification() async throws {
        let client = StubClerkEmailAuthClient(
            sessionState: .active(requestedUser),
            verificationAttempt: .incomplete
        )
        let service = ClerkEmailAuthService(client: client)

        let result = try await service.verifyCode(code: "123456")

        XCTAssertEqual(result.uid, requestedUser.id)
        XCTAssertEqual(client.verifyCallCount, 0)
    }

    func testResendAndSignOutPropagateClientFailures() async {
        let client = StubClerkEmailAuthClient()
        let service = ClerkEmailAuthService(client: client)
        client.resendError = StubError.expected

        do {
            try await service.resendConfirmationEmail(email: requestedUser.email)
            XCTFail("Expected resend to fail")
        } catch {
            XCTAssertTrue(error is StubError)
        }

        client.signOutError = StubError.expected
        do {
            try await service.signOut()
            XCTFail("Expected sign-out to fail")
        } catch {
            XCTAssertTrue(error is StubError)
        }
    }

    func testDeleteCurrentUserDelegatesToClient() async throws {
        let client = StubClerkEmailAuthClient(sessionState: .active(requestedUser))
        let service = ClerkEmailAuthService(client: client)

        try await service.deleteCurrentUser()

        XCTAssertEqual(client.deleteCallCount, 1)
    }

    func testPasswordResetUsesNativeEmailSequence() async throws {
        let client = StubClerkEmailAuthClient(sessionState: .inactive)
        let service = ClerkEmailAuthService(client: client)

        try await service.sendPasswordReset(email: requestedUser.email)
        try await service.verifyPasswordResetCode(code: "123456")
        let result = try await service.completePasswordReset(newPassword: "new-password")

        XCTAssertEqual(client.passwordResetEmails, [requestedUser.email])
        XCTAssertEqual(client.passwordResetCodes, ["123456"])
        XCTAssertEqual(client.newPasswords, ["new-password"])
        guard case .authenticated(let user) = result else {
            return XCTFail("Expected an authenticated reset result")
        }
        XCTAssertEqual(user.uid, requestedUser.id)
        XCTAssertEqual(user.email, requestedUser.email)
    }

    func testPasswordResetResendDelegatesToCurrentNativeAttempt() async throws {
        let client = StubClerkEmailAuthClient()
        let service = ClerkEmailAuthService(client: client)

        try await service.resendPasswordResetCode()

        XCTAssertEqual(client.passwordResetResendCallCount, 1)
    }

    func testPasswordResetReportsAcceptedPasswordWhenClerkNeedsAnotherSignInStep() async throws {
        let client = StubClerkEmailAuthClient()
        client.requiresSignInAfterPasswordReset = true
        let service = ClerkEmailAuthService(client: client)

        let result = try await service.completePasswordReset(newPassword: "new-password")

        guard case .requiresSignIn = result else {
            return XCTFail("Expected a safe sign-in recovery result")
        }
    }

    func testPasswordResetStatusGuardsAcceptOnlyExpectedClerkTransitions() {
        XCTAssertEqual(LiveClerkEmailAuthClient.passwordResetDisposition(.needsFirstFactor, after: .requestCode), .expected)
        XCTAssertEqual(LiveClerkEmailAuthClient.passwordResetDisposition(.needsNewPassword, after: .requestCode), .invalid)

        XCTAssertEqual(LiveClerkEmailAuthClient.passwordResetDisposition(.needsNewPassword, after: .verifyCode), .expected)
        XCTAssertEqual(LiveClerkEmailAuthClient.passwordResetDisposition(.complete, after: .verifyCode), .invalid)

        XCTAssertEqual(LiveClerkEmailAuthClient.passwordResetDisposition(.complete, after: .setPassword), .expected)
        XCTAssertEqual(LiveClerkEmailAuthClient.passwordResetDisposition(.needsSecondFactor, after: .setPassword), .requiresSignIn)
        XCTAssertEqual(LiveClerkEmailAuthClient.passwordResetDisposition(.needsClientTrust, after: .setPassword), .requiresSignIn)
    }

    private func assertThrowsPayBackError<T>(
        _ expected: PayBackError,
        operation: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected operation to throw", file: file, line: line)
        } catch let error as PayBackError {
            XCTAssertEqual(error.localizedDescription, expected.localizedDescription, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}

@MainActor
private final class StubClerkEmailAuthClient: ClerkEmailAuthClient {
    var sessionState: ClerkEmailSessionState
    var signInAttempt: ClerkEmailAttempt
    var signUpAttempt: ClerkEmailSignUpAttempt
    var verificationAttempt: ClerkEmailAttempt
    var passwordResetUser: ClerkEmailUser
    var resendError: Error?
    var signOutError: Error?
    var requiresSignInAfterPasswordReset = false

    private(set) var signInCallCount = 0
    private(set) var signOutCallCount = 0
    private(set) var verifyCallCount = 0
    private(set) var deleteCallCount = 0
    private(set) var passwordResetEmails: [String] = []
    private(set) var passwordResetCodes: [String] = []
    private(set) var newPasswords: [String] = []
    private(set) var passwordResetResendCallCount = 0

    init(
        sessionState: ClerkEmailSessionState = .none,
        signInAttempt: ClerkEmailAttempt = .incomplete,
        signUpAttempt: ClerkEmailSignUpAttempt = .incomplete,
        verificationAttempt: ClerkEmailAttempt = .incomplete,
        passwordResetUser: ClerkEmailUser = ClerkEmailUser(
            id: "user-123",
            email: "person@example.com",
            firstName: "Test",
            lastName: "Person"
        )
    ) {
        self.sessionState = sessionState
        self.signInAttempt = signInAttempt
        self.signUpAttempt = signUpAttempt
        self.verificationAttempt = verificationAttempt
        self.passwordResetUser = passwordResetUser
    }

    func signIn(email: String, password: String) async throws -> ClerkEmailAttempt {
        signInCallCount += 1
        return signInAttempt
    }

    func signUp(
        email: String,
        password: String,
        firstName: String,
        lastName: String?
    ) async throws -> ClerkEmailSignUpAttempt {
        signUpAttempt
    }

    func verifyCode(_ code: String) async throws -> ClerkEmailAttempt {
        verifyCallCount += 1
        return verificationAttempt
    }

    func resendConfirmationEmail() async throws {
        if let resendError { throw resendError }
    }

    func signOut() async throws {
        signOutCallCount += 1
        if let signOutError { throw signOutError }
        sessionState = .none
    }

    func deleteCurrentUser() async throws {
        deleteCallCount += 1
    }

    func beginPasswordReset(email: String) async throws {
        passwordResetEmails.append(email)
    }

    func verifyPasswordResetCode(_ code: String) async throws {
        passwordResetCodes.append(code)
    }

    func completePasswordReset(newPassword: String) async throws -> ClerkPasswordResetCompletion {
        newPasswords.append(newPassword)
        if requiresSignInAfterPasswordReset {
            return .requiresSignIn
        }
        sessionState = .active(passwordResetUser)
        return .authenticated(passwordResetUser)
    }

    func resendPasswordResetCode() async throws {
        passwordResetResendCallCount += 1
    }
}

private enum StubError: Error {
    case expected
}
