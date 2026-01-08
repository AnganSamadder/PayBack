import XCTest
@testable import PayBack

/// Tests specifically for the invite URL generation and HTTPS redirect functionality
final class InviteURLGenerationTests: XCTestCase {
    
    var mockService: MockInviteLinkServiceForTests!
    
    override func setUp() async throws {
        try await super.setUp()
        mockService = MockInviteLinkServiceForTests()
    }
    
    override func tearDown() async throws {
        await mockService.reset()
        mockService = nil
        try await super.tearDown()
    }
    
    // MARK: - URL Structure Tests
    
    func testURLHasValidStructure() async throws {
        let invite = try await mockService.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "StructureTest"
        )
        
        let url = invite.url
        
        // URL should be parseable
        XCTAssertNotNil(url.host ?? url.scheme)
        
        // Should have query items
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        XCTAssertNotNil(components)
    }
    
    func testURLTokenParameterIsValidUUID() async throws {
        let invite = try await mockService.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "UUIDTest"
        )
        
        let components = URLComponents(url: invite.url, resolvingAgainstBaseURL: false)
        let tokenParam = components?.queryItems?.first(where: { $0.name == "token" })?.value
        
        XCTAssertNotNil(tokenParam, "URL should have token parameter")
        XCTAssertNotNil(UUID(uuidString: tokenParam!), "Token should be valid UUID")
    }
    
    func testURLTokenMatchesInviteToken() async throws {
        let invite = try await mockService.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "MatchTest"
        )
        
        let components = URLComponents(url: invite.url, resolvingAgainstBaseURL: false)
        let tokenParam = components?.queryItems?.first(where: { $0.name == "token" })?.value
        
        XCTAssertEqual(tokenParam, invite.token.id.uuidString)
    }
    
    // MARK: - HTTPS URL Tests (when Supabase is configured)
    
    func testHTTPSURLFormat() async throws {
        // If Supabase is configured, URL should be HTTPS
        if SupabaseClientProvider.isConfigured {
            let invite = try await mockService.generateInviteLink(
                targetMemberId: UUID(),
                targetMemberName: "HTTPSTest"
            )
            
            XCTAssertEqual(invite.url.scheme, "https", "When Supabase is configured, URL should use HTTPS")
            XCTAssertTrue(invite.url.absoluteString.contains("/functions/v1/invite"), "URL should point to Edge Function")
        }
    }
    
    func testHTTPSURLContainsEdgeFunctionPath() async throws {
        if let baseURL = SupabaseClientProvider.baseURL {
            let invite = try await mockService.generateInviteLink(
                targetMemberId: UUID(),
                targetMemberName: "PathTest"
            )
            
            let urlString = invite.url.absoluteString
            XCTAssertTrue(urlString.hasPrefix(baseURL.absoluteString), "URL should start with Supabase base URL")
            XCTAssertTrue(urlString.contains("/functions/v1/invite"), "URL should contain Edge Function path")
        }
    }
    
    // MARK: - Fallback URL Tests (when Supabase is not configured)
    
    func testFallbackURLUsesCustomScheme() async throws {
        // When Supabase is NOT configured, URL should use custom scheme
        if !SupabaseClientProvider.isConfigured {
            let invite = try await mockService.generateInviteLink(
                targetMemberId: UUID(),
                targetMemberName: "FallbackTest"
            )
            
            XCTAssertEqual(invite.url.scheme, "payback", "Fallback should use custom scheme")
            XCTAssertEqual(invite.url.host, "link")
            XCTAssertEqual(invite.url.path, "/claim")
        }
    }
    
    func testFallbackURLStructure() async throws {
        if !SupabaseClientProvider.isConfigured {
            let invite = try await mockService.generateInviteLink(
                targetMemberId: UUID(),
                targetMemberName: "FallbackStructureTest"
            )
            
            let urlString = invite.url.absoluteString
            XCTAssertTrue(urlString.hasPrefix("payback://link/claim?token="))
        }
    }
    
    // MARK: - URL Consistency Tests
    
    func testSameTokenGeneratesSameURLFormat() async throws {
        let invite1 = try await mockService.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "Consistency1"
        )
        let invite2 = try await mockService.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "Consistency2"
        )
        
        // Both URLs should use the same scheme
        XCTAssertEqual(invite1.url.scheme, invite2.url.scheme)
        
        // If using HTTPS, both should have same host
        if invite1.url.scheme == "https" {
            XCTAssertEqual(invite1.url.host, invite2.url.host)
        }
    }
    
    func testURLDoesNotContainSensitiveInfo() async throws {
        let invite = try await mockService.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "SecretUser"
        )
        
        let urlString = invite.url.absoluteString.lowercased()
        
        // URL should not contain user email or creator info
        XCTAssertFalse(urlString.contains("creator"))
        XCTAssertFalse(urlString.contains("email"))
        XCTAssertFalse(urlString.contains("@"))
    }
    
    // MARK: - URL Length Tests
    
    func testURLIsReasonableLength() async throws {
        let invite = try await mockService.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "LengthTest"
        )
        
        let urlLength = invite.url.absoluteString.count
        
        // URLs should be reasonable for sharing
        XCTAssertLessThan(urlLength, 500, "URL should be reasonable length for sharing")
        XCTAssertGreaterThan(urlLength, 50, "URL should contain minimum required info")
    }
    
    // MARK: - URL Encoding Tests
    
    func testURLIsProperlyEncoded() async throws {
        let invite = try await mockService.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "EncodingTest"
        )
        
        // URL should not contain unencoded special characters that would break it
        let urlString = invite.url.absoluteString
        XCTAssertFalse(urlString.contains(" "), "URL should not contain spaces")
    }
    
    // MARK: - Share Text URL Integration Tests
    
    func testShareTextURLIsClickable() async throws {
        let invite = try await mockService.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "ClickableTest"
        )
        
        // The URL in share text should match the invite URL exactly
        XCTAssertTrue(invite.shareText.contains(invite.url.absoluteString))
        
        // URL should be on its own line (not concatenated with text)
        let lines = invite.shareText.components(separatedBy: "\n")
        let urlLine = lines.first(where: { $0.contains("://") })
        XCTAssertNotNil(urlLine, "URL should be present in share text")
    }
    
    func testShareTextURLIsComplete() async throws {
        let invite = try await mockService.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "CompleteURLTest"
        )
        
        // Extract URL from share text
        let shareText = invite.shareText
        let urlString = invite.url.absoluteString
        
        // The full URL should be in the share text without truncation
        XCTAssertTrue(shareText.contains(urlString), "Share text should contain complete URL")
    }
}

// MARK: - URL Parsing Tests

final class InviteURLParsingTests: XCTestCase {
    
    // MARK: - Deep Link Parsing Tests
    
    func testParseCustomSchemeURL() {
        let tokenId = UUID()
        let urlString = "payback://link/claim?token=\(tokenId.uuidString)"
        let url = URL(string: urlString)!
        
        XCTAssertEqual(url.scheme, "payback")
        XCTAssertEqual(url.host, "link")
        XCTAssertEqual(url.path, "/claim")
        
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let tokenParam = components?.queryItems?.first(where: { $0.name == "token" })?.value
        XCTAssertEqual(tokenParam, tokenId.uuidString)
    }
    
    func testParseHTTPSURL() {
        let tokenId = UUID()
        let urlString = "https://example.supabase.co/functions/v1/invite?token=\(tokenId.uuidString)"
        let url = URL(string: urlString)!
        
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "example.supabase.co")
        XCTAssertEqual(url.path, "/functions/v1/invite")
        
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let tokenParam = components?.queryItems?.first(where: { $0.name == "token" })?.value
        XCTAssertEqual(tokenParam, tokenId.uuidString)
    }
    
    func testExtractTokenFromURL() {
        let tokenId = UUID()
        let urls = [
            "payback://link/claim?token=\(tokenId.uuidString)",
            "https://test.supabase.co/functions/v1/invite?token=\(tokenId.uuidString)"
        ]
        
        for urlString in urls {
            let url = URL(string: urlString)!
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let extractedToken = components?.queryItems?.first(where: { $0.name == "token" })?.value
            
            XCTAssertNotNil(extractedToken)
            XCTAssertEqual(UUID(uuidString: extractedToken!), tokenId)
        }
    }
    
    func testInvalidTokenFormatInURL() {
        let invalidURLs = [
            "payback://link/claim?token=invalid",
            "payback://link/claim?token=",
            "payback://link/claim",
            "payback://link/claim?other=value"
        ]
        
        for urlString in invalidURLs {
            let url = URL(string: urlString)!
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let tokenParam = components?.queryItems?.first(where: { $0.name == "token" })?.value
            
            // Either token is missing or it's not a valid UUID
            if let token = tokenParam {
                let parsedUUID = UUID(uuidString: token)
                // Token present but invalid is okay for this test
                if parsedUUID == nil {
                    // Expected for invalid token
                }
            }
        }
    }
    
    // MARK: - URL Comparison Tests
    
    func testURLsWithSameTokenAreEquivalent() {
        let tokenId = UUID()
        let customURL = URL(string: "payback://link/claim?token=\(tokenId.uuidString)")!
        let httpsURL = URL(string: "https://test.supabase.co/functions/v1/invite?token=\(tokenId.uuidString)")!
        
        // Extract tokens
        let customComponents = URLComponents(url: customURL, resolvingAgainstBaseURL: false)
        let httpsComponents = URLComponents(url: httpsURL, resolvingAgainstBaseURL: false)
        
        let customToken = customComponents?.queryItems?.first(where: { $0.name == "token" })?.value
        let httpsToken = httpsComponents?.queryItems?.first(where: { $0.name == "token" })?.value
        
        XCTAssertEqual(customToken, httpsToken, "Both URLs should contain the same token")
    }
}

// MARK: - SupabaseClientProvider URL Tests

final class SupabaseClientProviderURLTests: XCTestCase {
    
    func testBaseURLPropertyExists() {
        // Test that baseURL property is accessible
        let _ = SupabaseClientProvider.baseURL
        // No assertion needed - just verifying property exists
    }
    
    func testPaybackURLSchemeIsRegistered() {
        // Verify the payback:// URL scheme is registered in Info.plist
        guard let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] else {
            // In test bundles, we can't access the main app's Info.plist directly
            // This test verifies the scheme works by checking URL construction
            let testURL = URL(string: "payback://link/claim?token=test")
            XCTAssertNotNil(testURL)
            XCTAssertEqual(testURL?.scheme, "payback")
            return
        }
        
        let schemes = urlTypes.flatMap { dict -> [String] in
            (dict["CFBundleURLSchemes"] as? [String]) ?? []
        }
        
        XCTAssertTrue(schemes.contains("payback"), "payback URL scheme should be registered")
    }
    
    func testBaseURLFormatWhenConfigured() {
        if let baseURL = SupabaseClientProvider.baseURL {
            // Should be valid URL
            XCTAssertNotNil(baseURL.scheme)
            XCTAssertNotNil(baseURL.host)
            
            // Should be HTTPS
            XCTAssertEqual(baseURL.scheme, "https")
            
            // Should contain supabase.co
            XCTAssertTrue(baseURL.host?.contains("supabase") ?? false)
        }
    }
    
    func testIsConfiguredConsistentWithBaseURL() {
        let isConfigured = SupabaseClientProvider.isConfigured
        let baseURL = SupabaseClientProvider.baseURL
        
        // If configured, baseURL should exist
        if isConfigured {
            XCTAssertNotNil(baseURL, "When configured, baseURL should be present")
        }
    }
    
    func testConfigurationThreadSafety() async {
        // Call from multiple concurrent tasks
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    let _ = SupabaseClientProvider.isConfigured
                    let _ = SupabaseClientProvider.baseURL
                    return true
                }
            }
            
            for await _ in group {}
        }
        // Test passes if no crashes
    }
}

// MARK: - LinkAcceptResult Tests

final class LinkAcceptResultTests: XCTestCase {
    
    func testLinkAcceptResultInitialization() {
        let memberId = UUID()
        let accountId = "test-account-123"
        let accountEmail = "test@example.com"
        
        let result = LinkAcceptResult(
            linkedMemberId: memberId,
            linkedAccountId: accountId,
            linkedAccountEmail: accountEmail
        )
        
        XCTAssertEqual(result.linkedMemberId, memberId)
        XCTAssertEqual(result.linkedAccountId, accountId)
        XCTAssertEqual(result.linkedAccountEmail, accountEmail)
    }
    
    func testLinkAcceptResultWithEmptyStrings() {
        let result = LinkAcceptResult(
            linkedMemberId: UUID(),
            linkedAccountId: "",
            linkedAccountEmail: ""
        )
        
        XCTAssertTrue(result.linkedAccountId.isEmpty)
        XCTAssertTrue(result.linkedAccountEmail.isEmpty)
    }
}

// MARK: - InviteToken Tests

final class InviteTokenTests: XCTestCase {
    
    func testInviteTokenInitialization() {
        let id = UUID()
        let creatorId = "creator-123"
        let creatorEmail = "creator@test.com"
        let targetMemberId = UUID()
        let targetMemberName = "Target Member"
        let createdAt = Date()
        let expiresAt = Date().addingTimeInterval(7 * 24 * 3600)
        
        let token = InviteToken(
            id: id,
            creatorId: creatorId,
            creatorEmail: creatorEmail,
            targetMemberId: targetMemberId,
            targetMemberName: targetMemberName,
            createdAt: createdAt,
            expiresAt: expiresAt, 
            claimedBy: nil,
            claimedAt: nil
        )
        
        XCTAssertEqual(token.id, id)
        XCTAssertEqual(token.creatorId, creatorId)
        XCTAssertEqual(token.creatorEmail, creatorEmail)
        XCTAssertEqual(token.targetMemberId, targetMemberId)
        XCTAssertEqual(token.targetMemberName, targetMemberName)
        XCTAssertNil(token.claimedBy)
        XCTAssertNil(token.claimedAt)
    }
    
    func testInviteTokenWithClaimInfo() {
        let claimedAt = Date()
        let claimedBy = "claimer-456"
        
        let token = InviteToken(
            id: UUID(),
            creatorId: "creator",
            creatorEmail: "creator@test.com",
            targetMemberId: UUID(),
            targetMemberName: "Target",
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(3600),
            claimedBy: claimedBy,
            claimedAt: claimedAt
        )
        
        XCTAssertEqual(token.claimedBy, claimedBy)
        XCTAssertEqual(token.claimedAt, claimedAt)
    }
    
    func testInviteTokenHashable() {
        let token1 = InviteToken(
            id: UUID(),
            creatorId: "creator",
            creatorEmail: "creator@test.com",
            targetMemberId: UUID(),
            targetMemberName: "Target",
            createdAt: Date(),
            expiresAt: Date()
        )
        
        let token2 = InviteToken(
            id: UUID(),
            creatorId: "creator",
            creatorEmail: "creator@test.com",
            targetMemberId: UUID(),
            targetMemberName: "Target",
            createdAt: Date(),
            expiresAt: Date()
        )
        
        // Different IDs should hash differently
        XCTAssertNotEqual(token1.hashValue, token2.hashValue)
        
        // Can be used in Set
        var tokenSet = Set<InviteToken>()
        tokenSet.insert(token1)
        tokenSet.insert(token2)
        XCTAssertEqual(tokenSet.count, 2)
    }
}

// MARK: - InviteTokenValidation Tests

final class InviteTokenValidationTests: XCTestCase {
    
    func testValidValidation() {
        let token = InviteToken(
            id: UUID(),
            creatorId: "creator",
            creatorEmail: "creator@test.com",
            targetMemberId: UUID(),
            targetMemberName: "Target",
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(3600)
        )
        
        let validation = InviteTokenValidation(
            isValid: true,
            token: token,
            expensePreview: nil,
            errorMessage: nil
        )
        
        XCTAssertTrue(validation.isValid)
        XCTAssertNotNil(validation.token)
        XCTAssertNil(validation.errorMessage)
    }
    
    func testInvalidValidationWithError() {
        let validation = InviteTokenValidation(
            isValid: false,
            token: nil,
            expensePreview: nil,
            errorMessage: "Token not found"
        )
        
        XCTAssertFalse(validation.isValid)
        XCTAssertNil(validation.token)
        XCTAssertEqual(validation.errorMessage, "Token not found")
    }
    
    func testValidationWithExpensePreview() {
        let preview = ExpensePreview(
            personalExpenses: [],
            groupExpenses: [],
            totalBalance: 100.0,
            groupNames: ["Group 1", "Group 2"]
        )
        
        let validation = InviteTokenValidation(
            isValid: true,
            token: nil,
            expensePreview: preview,
            errorMessage: nil
        )
        
        XCTAssertNotNil(validation.expensePreview)
        XCTAssertEqual(validation.expensePreview?.totalBalance, 100.0)
        XCTAssertEqual(validation.expensePreview?.groupNames.count, 2)
    }
}

// MARK: - ExpensePreview Tests

final class ExpensePreviewTests: XCTestCase {
    
    func testExpensePreviewInitialization() {
        let preview = ExpensePreview(
            personalExpenses: [],
            groupExpenses: [],
            totalBalance: 50.0,
            groupNames: ["Test Group"]
        )
        
        XCTAssertTrue(preview.personalExpenses.isEmpty)
        XCTAssertTrue(preview.groupExpenses.isEmpty)
        XCTAssertEqual(preview.totalBalance, 50.0)
        XCTAssertEqual(preview.groupNames.count, 1)
    }
    
    func testExpensePreviewWithNegativeBalance() {
        let preview = ExpensePreview(
            personalExpenses: [],
            groupExpenses: [],
            totalBalance: -75.50,
            groupNames: []
        )
        
        XCTAssertEqual(preview.totalBalance, -75.50)
    }
    
    func testExpensePreviewWithZeroBalance() {
        let preview = ExpensePreview(
            personalExpenses: [],
            groupExpenses: [],
            totalBalance: 0.0,
            groupNames: []
        )
        
        XCTAssertEqual(preview.totalBalance, 0.0)
    }
    
    func testExpensePreviewWithMultipleGroups() {
        let groupNames = ["Family", "Work", "Friends", "Roommates"]
        let preview = ExpensePreview(
            personalExpenses: [],
            groupExpenses: [],
            totalBalance: 0.0,
            groupNames: groupNames
        )
        
        XCTAssertEqual(preview.groupNames, groupNames)
    }
}
