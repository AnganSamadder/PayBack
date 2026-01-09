import Foundation
import Clerk

@MainActor
final class ClerkEmailAuthService: EmailAuthService {
    nonisolated init() {}
    
    func signIn(email: String, password: String) async throws -> EmailAuthSignInResult {
        // First check if already signed in
        if let user = Clerk.shared.user {
            return EmailAuthSignInResult(
                uid: user.id,
                email: user.primaryEmailAddress?.emailAddress ?? email,
                firstName: user.firstName,
                lastName: user.lastName
            )
        }
        
        do {
            try await SignIn.create(
                strategy: .identifier(
                    email,
                    password: password
                )
            )
            
            // Reload Clerk state
            try await Clerk.shared.load()
            
            // Wait for session to be active
            if let user = Clerk.shared.user {
                return EmailAuthSignInResult(
                    uid: user.id,
                    email: user.primaryEmailAddress?.emailAddress ?? email,
                    firstName: user.firstName,
                    lastName: user.lastName
                )
            }
            throw PayBackError.authSessionMissing
        } catch {
            // Check if error is "session_exists" - user is already signed in
            let errorDescription = String(describing: error)
            if errorDescription.contains("session_exists") || errorDescription.contains("already signed in") {
                // Reload Clerk and return the existing user
                try await Clerk.shared.load()
                if let user = Clerk.shared.user {
                    return EmailAuthSignInResult(
                        uid: user.id,
                        email: user.primaryEmailAddress?.emailAddress ?? email,
                        firstName: user.firstName,
                        lastName: user.lastName
                    )
                }
            }
            throw mapClerkError(error)
        }
    }
    
    func signUp(email: String, password: String, firstName: String, lastName: String?) async throws -> SignUpResult {
        // First check if already signed in
        if let user = Clerk.shared.user {
            return .complete(EmailAuthSignInResult(
                uid: user.id,
                email: user.primaryEmailAddress?.emailAddress ?? email,
                firstName: user.firstName,
                lastName: user.lastName
            ))
        }
        
        do {
            // 1. Create Sign Up with firstName and lastName directly
            let signUp = try await SignUp.create(
                strategy: .standard(
                    emailAddress: email,
                    password: password
                )
            )
            
            // 2. Update First/Last name using UpdateParams
            let updateParams = SignUp.UpdateParams(
                firstName: firstName,
                lastName: lastName
            )
            _ = try await signUp.update(params: updateParams)
            
            // 3. Check if verification is required
            if signUp.status != .complete {
                // Email verification is required - prepare it
                try await signUp.prepareVerification(strategy: .emailCode)
                // Return needsVerification to show the code entry screen
                return .needsVerification(email: email)
            }
            
            // Sign-up complete without verification - user is now signed in
            try await Clerk.shared.load()
            if let user = Clerk.shared.user {
                return .complete(EmailAuthSignInResult(
                    uid: user.id,
                    email: user.primaryEmailAddress?.emailAddress ?? email,
                    firstName: user.firstName,
                    lastName: user.lastName
                ))
            }
            throw PayBackError.authSessionMissing
        } catch let error as PayBackError {
            throw error
        } catch {
            // Check if error is "session_exists" - user is already signed in
            let errorDescription = String(describing: error)
            if errorDescription.contains("session_exists") || errorDescription.contains("already signed in") {
                try await Clerk.shared.load()
                if let user = Clerk.shared.user {
                    return .complete(EmailAuthSignInResult(
                        uid: user.id,
                        email: user.primaryEmailAddress?.emailAddress ?? email,
                        firstName: user.firstName,
                        lastName: user.lastName
                    ))
                }
            }
            throw mapClerkError(error)
        }
    }
    
    func verifyCode(code: String) async throws -> EmailAuthSignInResult {
        // First check if already signed in (from a previous verification)
        if let user = Clerk.shared.user {
            return EmailAuthSignInResult(
                uid: user.id,
                email: user.primaryEmailAddress?.emailAddress ?? "",
                firstName: user.firstName,
                lastName: user.lastName
            )
        }
        
        // Attempt verification with the provided code
        guard let signUp = Clerk.shared.client?.signUp else {
            throw PayBackError.authSessionMissing
        }
        
        do {
            let result = try await signUp.attemptVerification(strategy: .emailCode(code: code))
            
            if result.status == .complete {
                // Verification successful - user should now be signed in
                // Reload Clerk state and check for user (may need multiple attempts)
                for _ in 0..<5 {
                    try await Clerk.shared.load()
                    if let user = Clerk.shared.user {
                        return EmailAuthSignInResult(
                            uid: user.id,
                            email: user.primaryEmailAddress?.emailAddress ?? signUp.emailAddress ?? "",
                            firstName: user.firstName,
                            lastName: user.lastName
                        )
                    }
                }
                
                // Session not available after retries
                throw PayBackError.authSessionMissing
            }
            
            throw PayBackError.authInvalidCredentials(message: "Verification incomplete. Please try again.")
        } catch let error as PayBackError {
            throw error
        } catch {
            // Check if error is "session_exists" - verification already completed
            let errorDescription = String(describing: error)
            if errorDescription.contains("session_exists") || errorDescription.contains("already signed in") {
                try await Clerk.shared.load()
                if let user = Clerk.shared.user {
                    return EmailAuthSignInResult(
                        uid: user.id,
                        email: user.primaryEmailAddress?.emailAddress ?? "",
                        firstName: user.firstName,
                        lastName: user.lastName
                    )
                }
            }
            throw mapClerkError(error)
        }
    }
    
    func sendPasswordReset(email: String) async throws {
        throw PayBackError.underlying(message: "Password reset via Clerk requires additional configuration.")
    }
    
    func resendConfirmationEmail(email: String) async throws {
        if let signUp = Clerk.shared.client?.signUp {
            try await signUp.prepareVerification(strategy: .emailCode)
        }
    }
    
    nonisolated func signOut() throws {
        Task { @MainActor in
            try await Clerk.shared.signOut()
        }
    }
    
    private func mapClerkError(_ error: Error) -> Error {
        print("[ClerkEmailAuthService] Error: \(error)")
        return error
    }
}
