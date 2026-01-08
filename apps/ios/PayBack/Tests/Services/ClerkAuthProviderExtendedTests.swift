import XCTest
@testable import PayBack

/// Extended tests for ClerkAuthProvider components
final class ClerkAuthProviderExtendedTests: XCTestCase {
    
    // MARK: - ClerkAuthResult Tests
    
    func testClerkAuthResult_Initialization() {
        let result = ClerkAuthResult(jwt: "test.jwt.token", userId: "user-123")
        
        XCTAssertEqual(result.jwt, "test.jwt.token")
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
        let longJwt = String(repeating: "a", count: 1000) + "." + String(repeating: "b", count: 1000) + "." + String(repeating: "c", count: 1000)
        let result = ClerkAuthResult(jwt: longJwt, userId: "user")
        
        XCTAssertEqual(result.jwt.count, 3002)
    }
    
    // MARK: - ClerkAuthError Tests
    
    func testClerkAuthError_NoSession_HasDescription() {
        let error = ClerkAuthError.noSession
        
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.lowercased().contains("session") ?? false)
    }
    
    func testClerkAuthError_NoToken_HasDescription() {
        let error = ClerkAuthError.noToken
        
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.lowercased().contains("token") ?? false)
    }
    
    func testClerkAuthError_LocalizedError_Conformance() {
        let noSession: Error = ClerkAuthError.noSession
        let noToken: Error = ClerkAuthError.noToken
        
        // Both should have localized descriptions
        XCTAssertNotNil(noSession.localizedDescription)
        XCTAssertNotNil(noToken.localizedDescription)
    }
    
    func testClerkAuthError_AllCases_HaveDescriptions() {
        let cases: [ClerkAuthError] = [.noSession, .noToken]
        
        for error in cases {
            XCTAssertNotNil(error.errorDescription, "Error \(error) should have a description")
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "Error \(error) should have non-empty description")
        }
    }
    
    // MARK: - ClerkAuthProvider Tests
    
    func testClerkAuthProvider_DefaultInit() {
        let provider = ClerkAuthProvider()
        // Should initialize without crashing
        XCTAssertNotNil(provider)
    }
    
    func testClerkAuthProvider_CustomJWTTemplate() {
        let provider = ClerkAuthProvider(jwtTemplate: "custom-template")
        // Should initialize without crashing
        XCTAssertNotNil(provider)
    }
    
    func testClerkAuthProvider_ExtractIdToken() {
        let provider = ClerkAuthProvider()
        let result = ClerkAuthResult(jwt: "my-jwt-token", userId: "user-123")
        
        let token = provider.extractIdToken(from: result)
        
        XCTAssertEqual(token, "my-jwt-token")
    }
    
    func testClerkAuthProvider_ExtractIdToken_ReturnsJWT() {
        let provider = ClerkAuthProvider(jwtTemplate: "custom")
        let testJwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        let result = ClerkAuthResult(jwt: testJwt, userId: "test-user")
        
        let extracted = provider.extractIdToken(from: result)
        
        XCTAssertEqual(extracted, testJwt)
    }
}
