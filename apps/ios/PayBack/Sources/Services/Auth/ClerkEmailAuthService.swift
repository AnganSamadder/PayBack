import Foundation
import ClerkKit

struct ClerkEmailUser: Sendable, Equatable {
    let id: String
    let email: String
    let firstName: String?
    let lastName: String?

    func authResult(fallbackEmail: String? = nil) -> EmailAuthSignInResult {
        EmailAuthSignInResult(
            uid: id,
            email: LiveClerkEmailAuthClient.resolveEmail(
                primaryEmail: email,
                fallbackEmail: fallbackEmail
            ),
            firstName: firstName,
            lastName: lastName
        )
    }
}

enum ClerkEmailSessionState: Sendable, Equatable {
    case none
    case inactive
    case active(ClerkEmailUser)
}

enum ClerkEmailAttempt: Sendable, Equatable {
    case complete(ClerkEmailUser?)
    case incomplete
}

enum ClerkEmailSignUpAttempt: Sendable, Equatable {
    case complete(ClerkEmailUser?)
    case needsVerification
    case unsupported
    case incomplete
}

enum ClerkEmailSignUpDisposition: Sendable, Equatable {
    case complete
    case sendEmailVerification
    case unsupported
    case incomplete
}

enum ClerkPasswordResetCheckpoint: Sendable {
    case requestCode
    case verifyCode
    case setPassword
}

enum ClerkPasswordResetStatusDisposition: Sendable, Equatable {
    case expected
    case requiresSignIn
    case invalid
}

enum ClerkPasswordResetCompletion: Sendable, Equatable {
    case authenticated(ClerkEmailUser)
    case requiresSignIn
}

@MainActor
protocol ClerkEmailAuthClient: Sendable {
    var sessionState: ClerkEmailSessionState { get }

    func signIn(email: String, password: String) async throws -> ClerkEmailAttempt
    func signUp(email: String, password: String, firstName: String, lastName: String?) async throws -> ClerkEmailSignUpAttempt
    func verifyCode(_ code: String) async throws -> ClerkEmailAttempt
    func beginPasswordReset(email: String) async throws
    func verifyPasswordResetCode(_ code: String) async throws
    func resendPasswordResetCode() async throws
    func completePasswordReset(newPassword: String) async throws -> ClerkPasswordResetCompletion
    func resendConfirmationEmail() async throws
    func signOut() async throws
    func deleteCurrentUser() async throws
}

@MainActor
struct LiveClerkEmailAuthClient: ClerkEmailAuthClient {
    nonisolated init() {}

    var sessionState: ClerkEmailSessionState {
        guard let session = Clerk.shared.session else { return .none }
        guard session.status == .active, let user = session.user else { return .inactive }
        return .active(Self.map(
            user,
            fallbackEmail: Clerk.shared.auth.currentSignUp?.emailAddress
        ))
    }

    func signIn(email: String, password: String) async throws -> ClerkEmailAttempt {
        let signIn = try await Clerk.shared.auth.signInWithPassword(
            identifier: email,
            password: password
        )
        guard signIn.status == .complete else { return .incomplete }
        return .complete(activeUser(fallbackEmail: email))
    }

    func signUp(
        email: String,
        password: String,
        firstName: String,
        lastName: String?
    ) async throws -> ClerkEmailSignUpAttempt {
        let signUp = try await Clerk.shared.auth.signUp(
            emailAddress: email,
            password: password,
            firstName: firstName,
            lastName: lastName
        )

        switch Self.signUpDisposition(
            status: signUp.status,
            missingFields: signUp.missingFields,
            unverifiedFields: signUp.unverifiedFields
        ) {
        case .sendEmailVerification:
            _ = try await signUp.sendEmailCode()
            return .needsVerification
        case .unsupported:
            return .unsupported
        case .incomplete:
            return .incomplete
        case .complete:
            return .complete(activeUser(fallbackEmail: signUp.emailAddress ?? email))
        }
    }

    func verifyCode(_ code: String) async throws -> ClerkEmailAttempt {
        guard let signUp = Clerk.shared.auth.currentSignUp else {
            throw PayBackError.authSessionMissing
        }
        let result = try await signUp.verifyEmailCode(code)
        guard result.status == .complete else { return .incomplete }
        return .complete(activeUser(fallbackEmail: result.emailAddress))
    }

    func beginPasswordReset(email: String) async throws {
        let signIn = try await Clerk.shared.auth.signIn(email)
        guard signIn.status == .needsFirstFactor,
              let emailFactor = signIn.supportedFirstFactors?.first(where: {
                  $0.strategy == .resetPasswordEmailCode
              }) else {
            throw PayBackError.authSessionMissing
        }

        let prepared = try await signIn.sendResetPasswordEmailCode(
            emailAddressId: emailFactor.emailAddressId
        )
        guard Self.passwordResetDisposition(prepared.status, after: .requestCode) == .expected,
              prepared.firstFactorVerification?.strategy == .resetPasswordEmailCode else {
            throw PayBackError.authSessionMissing
        }
    }

    func verifyPasswordResetCode(_ code: String) async throws {
        guard let signIn = Clerk.shared.auth.currentSignIn,
              signIn.status == .needsFirstFactor,
              signIn.firstFactorVerification?.strategy == .resetPasswordEmailCode else {
            throw PayBackError.authSessionMissing
        }

        let verified = try await signIn.verifyCode(code)
        guard Self.passwordResetDisposition(verified.status, after: .verifyCode) == .expected else {
            throw PayBackError.authSessionMissing
        }
    }

    func resendPasswordResetCode() async throws {
        guard let signIn = Clerk.shared.auth.currentSignIn,
              signIn.status == .needsFirstFactor,
              signIn.firstFactorVerification?.strategy == .resetPasswordEmailCode else {
            throw PayBackError.authSessionMissing
        }

        let prepared = try await signIn.sendResetPasswordEmailCode()
        guard Self.passwordResetDisposition(prepared.status, after: .requestCode) == .expected,
              prepared.firstFactorVerification?.strategy == .resetPasswordEmailCode else {
            throw PayBackError.authSessionMissing
        }
    }

    func completePasswordReset(newPassword: String) async throws -> ClerkPasswordResetCompletion {
        guard let signIn = Clerk.shared.auth.currentSignIn,
              signIn.status == .needsNewPassword else {
            throw PayBackError.authSessionMissing
        }

        let completed = try await signIn.resetPassword(
            newPassword: newPassword,
            signOutOfOtherSessions: true
        )
        switch Self.passwordResetDisposition(completed.status, after: .setPassword) {
        case .expected:
            guard let user = activeUser(fallbackEmail: completed.identifier ?? signIn.identifier) else {
                throw PayBackError.authSessionMissing
            }
            return .authenticated(user)
        case .requiresSignIn:
            return .requiresSignIn
        case .invalid:
            throw PayBackError.authSessionMissing
        }
    }

    func resendConfirmationEmail() async throws {
        guard let signUp = Clerk.shared.auth.currentSignUp else { return }
        _ = try await signUp.sendEmailCode()
    }

    func signOut() async throws {
        try await Clerk.shared.auth.signOut()
    }

    func deleteCurrentUser() async throws {
        guard case .active = sessionState, let user = Clerk.shared.session?.user else { return }
        try await user.delete()
    }

    private func activeUser(fallbackEmail: String?) -> ClerkEmailUser? {
        guard case .active(let user) = sessionState else { return nil }
        return ClerkEmailUser(
            id: user.id,
            email: Self.resolveEmail(primaryEmail: user.email, fallbackEmail: fallbackEmail),
            firstName: user.firstName,
            lastName: user.lastName
        )
    }

    private static func map(_ user: User, fallbackEmail: String?) -> ClerkEmailUser {
        ClerkEmailUser(
            id: user.id,
            email: resolveEmail(
                primaryEmail: user.primaryEmailAddress?.emailAddress,
                fallbackEmail: fallbackEmail
            ),
            firstName: user.firstName,
            lastName: user.lastName
        )
    }

    nonisolated static func resolveEmail(primaryEmail: String?, fallbackEmail: String?) -> String {
        if let primaryEmail,
           !primaryEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return primaryEmail
        }
        return fallbackEmail ?? ""
    }

    nonisolated static func passwordResetDisposition(
        _ status: SignIn.Status,
        after checkpoint: ClerkPasswordResetCheckpoint
    ) -> ClerkPasswordResetStatusDisposition {
        switch checkpoint {
        case .requestCode:
            return status == .needsFirstFactor ? .expected : .invalid
        case .verifyCode:
            return status == .needsNewPassword ? .expected : .invalid
        case .setPassword:
            switch status {
            case .complete:
                return .expected
            case .needsSecondFactor, .needsClientTrust:
                return .requiresSignIn
            case .needsIdentifier, .needsFirstFactor, .needsNewPassword, .unknown:
                return .invalid
            }
        }
    }

    nonisolated static func signUpDisposition(
        status: SignUp.Status,
        missingFields: [SignUp.Field],
        unverifiedFields: [SignUp.Field]
    ) -> ClerkEmailSignUpDisposition {
        switch status {
        case .complete:
            return .complete
        case .missingRequirements:
            guard missingFields.isEmpty,
                  Set(unverifiedFields) == Set([SignUp.Field.emailAddress]) else {
                return .unsupported
            }
            return .sendEmailVerification
        case .abandoned, .unknown:
            return .incomplete
        }
    }
}

@MainActor
final class ClerkEmailAuthService: EmailAuthService {
    private let client: any ClerkEmailAuthClient

    nonisolated init(client: any ClerkEmailAuthClient = LiveClerkEmailAuthClient()) {
        self.client = client
    }

    func signIn(email: String, password: String) async throws -> EmailAuthSignInResult {
        switch client.sessionState {
        case .active(let user) where user.email.localizedCaseInsensitiveCompare(email) == .orderedSame:
            return user.authResult(fallbackEmail: email)
        case .active, .inactive:
            try await client.signOut()
        case .none:
            break
        }

        switch try await client.signIn(email: email, password: password) {
        case .complete(let user):
            guard let user else { throw PayBackError.authSessionMissing }
            return user.authResult(fallbackEmail: email)
        case .incomplete:
            throw PayBackError.underlying(
                message: "This account requires an additional sign-in step that PayBack does not support yet."
            )
        }
    }

    func signUp(
        email: String,
        password: String,
        firstName: String,
        lastName: String?
    ) async throws -> SignUpResult {
        switch client.sessionState {
        case .active(let user) where user.email.localizedCaseInsensitiveCompare(email) == .orderedSame:
            return .complete(user.authResult(fallbackEmail: email))
        case .active, .inactive:
            try await client.signOut()
        case .none:
            break
        }

        switch try await client.signUp(
            email: email,
            password: password,
            firstName: firstName,
            lastName: lastName
        ) {
        case .complete(let user):
            guard let user else { throw PayBackError.authSessionMissing }
            return .complete(user.authResult(fallbackEmail: email))
        case .needsVerification:
            return .needsVerification(email: email)
        case .unsupported:
            throw PayBackError.underlying(
                message: "This sign-up requires an additional step that PayBack does not support yet."
            )
        case .incomplete:
            throw PayBackError.authSessionMissing
        }
    }

    func verifyCode(code: String) async throws -> EmailAuthSignInResult {
        if case .active(let user) = client.sessionState {
            return user.authResult()
        }

        switch try await client.verifyCode(code) {
        case .complete(let user):
            guard let user else { throw PayBackError.authSessionMissing }
            return user.authResult()
        case .incomplete:
            throw PayBackError.authInvalidCredentials(message: "Verification incomplete. Please try again.")
        }
    }

    func sendPasswordReset(email: String) async throws {
        switch client.sessionState {
        case .active, .inactive:
            try await client.signOut()
        case .none:
            break
        }
        try await client.beginPasswordReset(email: email)
    }

    func verifyPasswordResetCode(code: String) async throws {
        try await client.verifyPasswordResetCode(code)
    }

    func resendPasswordResetCode() async throws {
        try await client.resendPasswordResetCode()
    }

    func completePasswordReset(newPassword: String) async throws -> PasswordResetResult {
        switch try await client.completePasswordReset(newPassword: newPassword) {
        case .authenticated(let user):
            return .authenticated(user.authResult())
        case .requiresSignIn:
            return .requiresSignIn
        }
    }

    func resendConfirmationEmail(email: String) async throws {
        try await client.resendConfirmationEmail()
    }

    func signOut() async throws {
        try await client.signOut()
    }

    func deleteCurrentUser() async throws {
        try await client.deleteCurrentUser()
    }
}
