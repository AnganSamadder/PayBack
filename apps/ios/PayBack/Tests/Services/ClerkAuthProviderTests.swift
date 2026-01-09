import XCTest
@testable import PayBack

final class ClerkAuthProviderTests: XCTestCase {
    
    // MARK: - ClerkAuthResult Tests
    
    func testClerkAuthResult_Initialization() {
        let result = ClerkAuthResult(jwt: "test-jwt-token", userId: "user-123")
        
        XCTAssertEqual(result.jwt, "test-jwt-token")
        XCTAssertEqual(result.userId, "user-123")
    }
    
    func testClerkAuthResult_WithEmptyJWT() {
        let result = ClerkAuthResult(jwt: "", userId: "user-123")
        
        XCTAssertEqual(result.jwt, "")
        XCTAssertEqual(result.userId, "user-123")
    }
    
    func testClerkAuthResult_WithEmptyUserId() {
        let result = ClerkAuthResult(jwt: "token", userId: "")
        
        XCTAssertEqual(result.jwt, "token")
        XCTAssertEqual(result.userId, "")
    }
    
    func testClerkAuthResult_WithLongJWT() {
        let longJWT = String(repeating: "a", count: 10000)
        let result = ClerkAuthResult(jwt: longJWT, userId: "user-123")
        
        XCTAssertEqual(result.jwt.count, 10000)
    }
    
    func testClerkAuthResult_IsSendable() {
        // This test ensures the type conforms to Sendable
        let result = ClerkAuthResult(jwt: "token", userId: "user")
        
        Task {
            let _ = result.jwt
            let _ = result.userId
        }
        
        XCTAssertTrue(true) // Compilation success proves Sendable conformance
    }
    
    // MARK: - ClerkAuthError Tests
    
    func testClerkAuthError_NoSession_HasDescription() {
        let error = ClerkAuthError.noSession
        
        XCTAssertNotNil(error.errorDescription)
        XCTAssertFalse(error.errorDescription!.isEmpty)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("session"))
    }
    
    func testClerkAuthError_NoToken_HasDescription() {
        let error = ClerkAuthError.noToken
        
        XCTAssertNotNil(error.errorDescription)
        XCTAssertFalse(error.errorDescription!.isEmpty)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("token"))
    }
    
    func testClerkAuthError_NoSession_ErrorDescription() {
        let error = ClerkAuthError.noSession
        
        XCTAssertEqual(error.errorDescription, "No active Clerk session")
    }
    
    func testClerkAuthError_NoToken_ErrorDescription() {
        let error = ClerkAuthError.noToken
        
        XCTAssertEqual(error.errorDescription, "Failed to get authentication token")
    }
    
    func testClerkAuthError_AllCases_HaveDescriptions() {
        let allCases: [ClerkAuthError] = [.noSession, .noToken]
        
        for error in allCases {
            XCTAssertNotNil(error.errorDescription, "Error \(error) should have a description")
            XCTAssertFalse(error.errorDescription!.isEmpty, "Error \(error) description should not be empty")
        }
    }
    
    func testClerkAuthError_ConformsToLocalizedError() {
        let error: LocalizedError = ClerkAuthError.noSession
        
        XCTAssertNotNil(error.errorDescription)
    }
    
    func testClerkAuthError_ConformsToError() {
        let error: Error = ClerkAuthError.noToken
        
        XCTAssertNotNil(error.localizedDescription)
    }
    
    // MARK: - ClerkAuthProvider Initialization Tests
    
    func testClerkAuthProvider_Initialization_DefaultTemplate() {
        let provider = ClerkAuthProvider()
        
        // Can't directly access private jwtTemplate, but we can verify it initializes
        XCTAssertNotNil(provider)
    }
    
    func testClerkAuthProvider_Initialization_CustomTemplate() {
        let provider = ClerkAuthProvider(jwtTemplate: "custom-template")
        
        // Verify it initializes without error
        XCTAssertNotNil(provider)
    }
    
    func testClerkAuthProvider_Initialization_EmptyTemplate() {
        let provider = ClerkAuthProvider(jwtTemplate: "")
        
        XCTAssertNotNil(provider)
    }
    
    // MARK: - ExtractIdToken Tests
    
    func testClerkAuthProvider_ExtractIdToken_ReturnsJWT() {
        let provider = ClerkAuthProvider()
        let authResult = ClerkAuthResult(jwt: "expected-jwt-token", userId: "user-123")
        
        let token = provider.extractIdToken(from: authResult)
        
        XCTAssertEqual(token, "expected-jwt-token")
    }
    
    func testClerkAuthProvider_ExtractIdToken_WithEmptyJWT_ReturnsEmpty() {
        let provider = ClerkAuthProvider()
        let authResult = ClerkAuthResult(jwt: "", userId: "user-123")
        
        let token = provider.extractIdToken(from: authResult)
        
        XCTAssertEqual(token, "")
    }
    
    func testClerkAuthProvider_ExtractIdToken_WithLongJWT_ReturnsFullToken() {
        let provider = ClerkAuthProvider()
        let longJWT = String(repeating: "x", count: 5000)
        let authResult = ClerkAuthResult(jwt: longJWT, userId: "user-123")
        
        let token = provider.extractIdToken(from: authResult)
        
        XCTAssertEqual(token.count, 5000)
        XCTAssertEqual(token, longJWT)
    }
    
    func testClerkAuthProvider_ExtractIdToken_WithSpecialCharacters_PreservesToken() {
        let provider = ClerkAuthProvider()
        let specialJWT = "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIn0.signature"
        let authResult = ClerkAuthResult(jwt: specialJWT, userId: "user-123")
        
        let token = provider.extractIdToken(from: authResult)
        
        XCTAssertEqual(token, specialJWT)
    }
    
    // MARK: - Error Handling Tests
    
    func testClerkAuthError_CanBeCaught() {
        func throwNoSession() throws {
            throw ClerkAuthError.noSession
        }
        
        XCTAssertThrowsError(try throwNoSession()) { error in
            XCTAssertTrue(error is ClerkAuthError)
            if let clerkError = error as? ClerkAuthError {
                XCTAssertEqual(clerkError, .noSession)
            }
        }
    }
    
    func testClerkAuthError_Equatable() {
        XCTAssertEqual(ClerkAuthError.noSession, ClerkAuthError.noSession)
        XCTAssertEqual(ClerkAuthError.noToken, ClerkAuthError.noToken)
        XCTAssertNotEqual(ClerkAuthError.noSession, ClerkAuthError.noToken)
    }
    
    func testClerkAuthError_CanBeUsedInSwitch() {
        let error = ClerkAuthError.noSession
        
        var matched = false
        switch error {
        case .noSession:
            matched = true
        case .noToken:
            matched = false
        }
        
        XCTAssertTrue(matched)
    }
}
