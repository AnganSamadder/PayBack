import Foundation
import FirebaseAuth
import XCTest
@testable import PayBack

/// Helper for Firebase Auth emulator testing.
/// Provides authenticated test users for integration tests that require Firebase Auth.
final class FirebaseAuthTestHelper {
    
    // MARK: - Properties
    
    private let auth: Auth
    private let testEmail: String
    private let testPassword: String
    
    /// Default test user credentials
    static let defaultEmail = "test@example.com"
    static let defaultPassword = "TestPassword123!"
    
    // MARK: - Initialization
    
    init(
        auth: Auth = Auth.auth(),
        email: String = defaultEmail,
        password: String = defaultPassword
    ) {
        self.auth = auth
        self.testEmail = email
        self.testPassword = password
    }
    
    // MARK: - Setup & Teardown
    
    /// Configure Firebase Auth to use emulator and sign in test user.
    /// Call this in your test's setUp() method.
    @MainActor
    func signInTestUser() async throws {
        // Configure Auth to use emulator
        auth.useEmulator(withHost: "127.0.0.1", port: 9099)
        
        // Try to sign in with existing user
        do {
            try await auth.signIn(withEmail: testEmail, password: testPassword)
        } catch {
            // User doesn't exist, create it
            try await auth.createUser(withEmail: testEmail, password: testPassword)
        }
        
        // Verify we're signed in
        guard auth.currentUser != nil else {
            throw FirebaseAuthTestError.signInFailed
        }
    }
    
    /// Sign out the current user.
    /// Call this in your test's tearDown() method.
    func signOutTestUser() throws {
        try auth.signOut()
    }
    
    /// Create a new test user with custom credentials.
    /// Useful for testing multi-user scenarios.
    @MainActor
    func createUser(email: String, password: String) async throws -> User {
        let result = try await auth.createUser(withEmail: email, password: password)
        return result.user
    }
    
    /// Delete the current user account.
    /// Useful for cleanup in tests that create users.
    @MainActor
    func deleteCurrentUser() async throws {
        guard let user = auth.currentUser else {
            throw FirebaseAuthTestError.noUserSignedIn
        }
        try await user.delete()
    }
    
    // MARK: - Helpers
    
    /// Get the currently signed-in user, or nil if not signed in
    @MainActor
    var currentUser: User? {
        return auth.currentUser
    }
    
    /// Check if a user is currently signed in
    @MainActor
    var isSignedIn: Bool {
        return auth.currentUser != nil
    }
}

// MARK: - Error Types

enum FirebaseAuthTestError: LocalizedError {
    case signInFailed
    case noUserSignedIn
    
    var errorDescription: String? {
        switch self {
        case .signInFailed:
            return "Failed to sign in test user"
        case .noUserSignedIn:
            return "No user is currently signed in"
        }
    }
}

// MARK: - XCTestCase Extension

extension XCTestCase {
    
    /// Convenience method to set up Firebase Auth for tests.
    /// Returns a helper configured for emulator use.
    @MainActor
    func setupFirebaseAuthForTesting() async throws -> FirebaseAuthTestHelper {
        let helper = FirebaseAuthTestHelper()
        try await helper.signInTestUser()
        return helper
    }
}
