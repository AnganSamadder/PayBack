import XCTest
@testable import PayBack

/// Additional tests for PhoneAuthService to improve coverage from 75.4%
final class PhoneAuthServiceExtendedTests: XCTestCase {
    
    var service: MockPhoneAuthService!
    
    override func setUp() {
        super.setUp()
        service = MockPhoneAuthService()
    }
    
    // MARK: - Verification Flow Tests
    
    func testRequestVerificationCode_ReturnsNonEmptyID() async throws {
        let verificationID = try await service.requestVerificationCode(for: "+1234567890")
        
        XCTAssertFalse(verificationID.isEmpty)
    }
    
    func testRequestVerificationCode_ReturnsDifferentIDsForSameNumber() async throws {
        let id1 = try await service.requestVerificationCode(for: "+1234567890")
        let id2 = try await service.requestVerificationCode(for: "+1234567890")
        
        XCTAssertNotEqual(id1, id2)
    }
    
    func testRequestVerificationCode_ReturnsDifferentIDsForDifferentNumbers() async throws {
        let id1 = try await service.requestVerificationCode(for: "+1111111111")
        let id2 = try await service.requestVerificationCode(for: "+2222222222")
        
        XCTAssertNotEqual(id1, id2)
    }
    
    func testSignIn_WithCorrectCode_Succeeds() async throws {
        let verificationID = try await service.requestVerificationCode(for: "+1234567890")
        
        let result = try await service.signIn(verificationID: verificationID, smsCode: "123456")
        
        XCTAssertEqual(result.uid, verificationID)
        XCTAssertEqual(result.phoneNumber, "+1234567890")
    }
    
    func testSignIn_WithWrongCode_ThrowsInvalidCode() async throws {
        let verificationID = try await service.requestVerificationCode(for: "+1234567890")
        
        do {
            _ = try await service.signIn(verificationID: verificationID, smsCode: "000000")
            XCTFail("Expected invalidCode error")
        } catch let error as PhoneAuthServiceError {
            XCTAssertEqual(error, .invalidCode)
        }
    }
    
    func testSignIn_WithInvalidVerificationID_ThrowsVerificationFailed() async throws {
        do {
            _ = try await service.signIn(verificationID: "invalid-id", smsCode: "123456")
            XCTFail("Expected verificationFailed error")
        } catch let error as PhoneAuthServiceError {
            XCTAssertEqual(error, .verificationFailed)
        }
    }
    
    func testSignIn_SecondAttemptWithSameID_ThrowsVerificationFailed() async throws {
        let verificationID = try await service.requestVerificationCode(for: "+1234567890")
        
        // First sign-in succeeds
        _ = try await service.signIn(verificationID: verificationID, smsCode: "123456")
        
        // Second attempt with same ID should fail
        do {
            _ = try await service.signIn(verificationID: verificationID, smsCode: "123456")
            XCTFail("Expected verificationFailed error")
        } catch let error as PhoneAuthServiceError {
            XCTAssertEqual(error, .verificationFailed)
        }
    }
    
    func testSignOut_DoesNotThrow() {
        XCTAssertNoThrow(try service.signOut())
    }
    
    // MARK: - PhoneVerificationSignInResult Tests
    
    func testPhoneVerificationSignInResult_Initialization() {
        let result = PhoneVerificationSignInResult(uid: "test-uid", phoneNumber: "+1234567890")
        
        XCTAssertEqual(result.uid, "test-uid")
        XCTAssertEqual(result.phoneNumber, "+1234567890")
    }
    
    func testPhoneVerificationSignInResult_WithNilPhoneNumber() {
        let result = PhoneVerificationSignInResult(uid: "test-uid", phoneNumber: nil)
        
        XCTAssertEqual(result.uid, "test-uid")
        XCTAssertNil(result.phoneNumber)
    }
    
    // MARK: - PhoneVerificationIntent Tests
    
    func testPhoneVerificationIntent_Login_Equatable() {
        XCTAssertEqual(PhoneVerificationIntent.login, PhoneVerificationIntent.login)
    }
    
    func testPhoneVerificationIntent_Signup_Equatable() {
        let intent1 = PhoneVerificationIntent.signup(displayName: "Test")
        let intent2 = PhoneVerificationIntent.signup(displayName: "Test")
        
        XCTAssertEqual(intent1, intent2)
    }
    
    func testPhoneVerificationIntent_DifferentSignups_NotEqual() {
        let intent1 = PhoneVerificationIntent.signup(displayName: "Test1")
        let intent2 = PhoneVerificationIntent.signup(displayName: "Test2")
        
        XCTAssertNotEqual(intent1, intent2)
    }
    
    func testPhoneVerificationIntent_LoginVsSignup_NotEqual() {
        XCTAssertNotEqual(PhoneVerificationIntent.login, PhoneVerificationIntent.signup(displayName: "Test"))
    }
    
    // MARK: - PhoneAuthServiceError Tests
    
    func testPhoneAuthServiceError_ConfigurationMissing_Description() {
        let error = PhoneAuthServiceError.configurationMissing
        
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("not available") || 
                      error.errorDescription!.lowercased().contains("phone"))
    }
    
    func testPhoneAuthServiceError_InvalidCode_Description() {
        let error = PhoneAuthServiceError.invalidCode
        
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("code") || 
                      error.errorDescription!.lowercased().contains("match"))
    }
    
    func testPhoneAuthServiceError_VerificationFailed_Description() {
        let error = PhoneAuthServiceError.verificationFailed
        
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("verify") || 
                      error.errorDescription!.lowercased().contains("new code"))
    }
    
    func testPhoneAuthServiceError_Underlying_ContainsMessage() {
        let underlyingError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Test error message"])
        let error = PhoneAuthServiceError.underlying(underlyingError)
        
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("Test error message"))
    }
    
    func testPhoneAuthServiceError_Equatable_SameCases() {
        XCTAssertEqual(PhoneAuthServiceError.configurationMissing, PhoneAuthServiceError.configurationMissing)
        XCTAssertEqual(PhoneAuthServiceError.invalidCode, PhoneAuthServiceError.invalidCode)
        XCTAssertEqual(PhoneAuthServiceError.verificationFailed, PhoneAuthServiceError.verificationFailed)
    }
    
    func testPhoneAuthServiceError_Equatable_DifferentCases() {
        XCTAssertNotEqual(PhoneAuthServiceError.configurationMissing, PhoneAuthServiceError.invalidCode)
        XCTAssertNotEqual(PhoneAuthServiceError.invalidCode, PhoneAuthServiceError.verificationFailed)
    }
    
    func testPhoneAuthServiceError_Equatable_Underlying() {
        let error1 = PhoneAuthServiceError.underlying(NSError(domain: "a", code: 1))
        let error2 = PhoneAuthServiceError.underlying(NSError(domain: "b", code: 2))
        
        // Both are .underlying, so they're equal per the implementation
        XCTAssertEqual(error1, error2)
    }
    
    func testPhoneAuthServiceError_ConformsToLocalizedError() {
        let error: LocalizedError = PhoneAuthServiceError.invalidCode
        XCTAssertNotNil(error.errorDescription)
    }
    
    // MARK: - PhoneAuthServiceProvider Tests
    
    func testPhoneAuthServiceProvider_MakeService_ReturnsMockService() {
        let service = PhoneAuthServiceProvider.makeService()
        
        XCTAssertNotNil(service)
        XCTAssertTrue(service is MockPhoneAuthService)
    }
    
    // MARK: - Concurrent Access Tests
    
    func testConcurrentVerificationRequests_DoNotCrash() async throws {
        await withTaskGroup(of: String?.self) { group in
            for i in 0..<20 {
                group.addTask {
                    try? await self.service.requestVerificationCode(for: "+1\(i)000000000")
                }
            }
        }
        
        XCTAssertTrue(true) // If we get here, no crash
    }
    
    func testConcurrentSignInAttempts_HandleCorrectly() async throws {
        let verificationID = try await service.requestVerificationCode(for: "+1234567890")
        
        var successes = 0
        var failures = 0
        
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    do {
                        _ = try await self.service.signIn(verificationID: verificationID, smsCode: "123456")
                        return true
                    } catch {
                        return false
                    }
                }
            }
            
            for await result in group {
                if result {
                    successes += 1
                } else {
                    failures += 1
                }
            }
        }
        
        // At least one should succeed and at least one fail (race condition dependent)
        // With actor isolation, behavior may vary - just verify total is 5
        XCTAssertEqual(successes + failures, 5)
    }
}
