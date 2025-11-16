import Foundation
@testable import PayBack

/// Thread-safe mock Firebase Authentication for testing
/// Simulates Firebase Auth behavior without external dependencies
actor MockAuth {
    private var currentUser: MockUser?
    private var shouldFail: Bool = false
    private var failureError: Error?
    private var verificationCodes: [String: String] = [:] // verificationId -> code
    private var registeredUsers: [String: (password: String, displayName: String?)] = [:] // email -> (password, displayName)
    private var phoneUsers: [String: String] = [:] // phoneNumber -> uid
    
    // MARK: - Email Authentication
    
    /// Sign in with email and password
    func signIn(email: String, password: String) async throws -> MockUser {
        if shouldFail {
            throw failureError ?? MockAuthError.invalidCredentials
        }
        
        // Check if user exists and password matches
        guard let userInfo = registeredUsers[email.lowercased()],
              userInfo.password == password else {
            throw MockAuthError.invalidCredentials
        }
        
        let user = MockUser(
            uid: UUID().uuidString,
            email: email,
            phoneNumber: nil,
            displayName: userInfo.displayName
        )
        currentUser = user
        return user
    }
    
    /// Create new user with email and password
    func createUser(email: String, password: String, displayName: String? = nil) async throws -> MockUser {
        if shouldFail {
            throw failureError ?? MockAuthError.emailAlreadyInUse
        }
        
        // Check if email already registered
        if registeredUsers[email.lowercased()] != nil {
            throw MockAuthError.emailAlreadyInUse
        }
        
        // Validate password strength (at least 6 characters)
        if password.count < 6 {
            throw MockAuthError.weakPassword
        }
        
        // Register user
        registeredUsers[email.lowercased()] = (password, displayName)
        
        let user = MockUser(
            uid: UUID().uuidString,
            email: email,
            phoneNumber: nil,
            displayName: displayName
        )
        currentUser = user
        return user
    }
    
    // MARK: - Phone Authentication
    
    /// Send verification code to phone number
    func sendVerificationCode(phoneNumber: String) async throws -> String {
        if shouldFail {
            throw failureError ?? MockAuthError.networkError
        }
        
        let verificationId = UUID().uuidString
        let code = String(format: "%06d", Int.random(in: 0...999999))
        verificationCodes[verificationId] = code
        
        return verificationId
    }
    
    /// Sign in with phone verification
    func signInWithPhone(verificationId: String, code: String, phoneNumber: String) async throws -> MockUser {
        if shouldFail {
            throw failureError ?? MockAuthError.invalidVerificationCode
        }
        
        guard let expectedCode = verificationCodes[verificationId],
              expectedCode == code else {
            throw MockAuthError.invalidVerificationCode
        }
        
        // Get or create user for this phone number
        let uid: String
        if let existingUid = phoneUsers[phoneNumber] {
            uid = existingUid
        } else {
            uid = UUID().uuidString
            phoneUsers[phoneNumber] = uid
        }
        
        let user = MockUser(
            uid: uid,
            email: nil,
            phoneNumber: phoneNumber,
            displayName: nil
        )
        currentUser = user
        
        // Clean up used verification code
        verificationCodes.removeValue(forKey: verificationId)
        
        return user
    }
    
    // MARK: - Session Management
    
    /// Sign out current user
    func signOut() async throws {
        currentUser = nil
    }
    
    /// Get current authenticated user
    func getCurrentUser() async -> MockUser? {
        return currentUser
    }
    
    /// Set current user (for testing scenarios)
    func setCurrentUser(_ user: MockUser?) async {
        currentUser = user
    }
    
    // MARK: - Error Simulation
    
    /// Configure the mock to simulate failures
    func setShouldFail(_ fail: Bool, error: Error? = nil) async {
        shouldFail = fail
        failureError = error
    }
    
    // MARK: - Test Utilities
    
    /// Get verification code for testing (normally not exposed)
    func getVerificationCode(for verificationId: String) async -> String? {
        return verificationCodes[verificationId]
    }
    
    /// Pre-register a user for testing
    func preRegisterUser(email: String, password: String, displayName: String? = nil) async {
        registeredUsers[email.lowercased()] = (password, displayName)
    }
    
    /// Reset all mock state for test isolation
    func reset() async {
        currentUser = nil
        shouldFail = false
        failureError = nil
        verificationCodes.removeAll()
        registeredUsers.removeAll()
        phoneUsers.removeAll()
    }
}

/// Mock user representing an authenticated user
struct MockUser: Equatable {
    let uid: String
    let email: String?
    let phoneNumber: String?
    let displayName: String?
    
    init(uid: String, email: String? = nil, phoneNumber: String? = nil, displayName: String? = nil) {
        self.uid = uid
        self.email = email
        self.phoneNumber = phoneNumber
        self.displayName = displayName
    }
}

/// Errors that can be thrown by mock authentication operations
enum MockAuthError: LocalizedError {
    case invalidCredentials
    case emailAlreadyInUse
    case weakPassword
    case userDisabled
    case tooManyRequests
    case networkError
    case invalidVerificationCode
    case verificationFailed
    case userNotFound
    
    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Invalid email or password"
        case .emailAlreadyInUse:
            return "Email already in use"
        case .weakPassword:
            return "Password must be at least 6 characters"
        case .userDisabled:
            return "User account has been disabled"
        case .tooManyRequests:
            return "Too many requests, please try again later"
        case .networkError:
            return "Network error occurred"
        case .invalidVerificationCode:
            return "Invalid verification code"
        case .verificationFailed:
            return "Verification failed"
        case .userNotFound:
            return "User not found"
        }
    }
}
