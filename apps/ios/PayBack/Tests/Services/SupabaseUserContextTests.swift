import XCTest
@testable import PayBack
import Supabase

final class SupabaseUserContextTests: XCTestCase {
    private var client: SupabaseClient!
    
    override func setUp() {
        super.setUp()
        client = makeMockSupabaseClient()
        MockSupabaseURLProtocol.reset()
    }
    
    override func tearDown() {
        MockSupabaseURLProtocol.reset()
        client = nil
        super.tearDown()
    }
    
    func testDefaultProviderReturnsContextWhenSessionExists() async throws {
        // Given: A valid starting session established via simulated sign-in
        let userId = UUID()
        let email = "test@example.com"
        let displayName = "Test User"
        let futureDate = Int(Date().timeIntervalSince1970) + 3600
        let sessionJson: [String: Any] = [
            "access_token": "valid.token",
            "token_type": "bearer",
            "expires_in": 3600,
            "expires_at": futureDate,
            "refresh_token": "valid.refresh",
            "user": [
                "id": userId.uuidString,
                "aud": "authenticated",
                "role": "authenticated",
                "email": email,
                "created_at": isoDate(Date()),
                "updated_at": isoDate(Date()),
                "app_metadata": ["provider": "email"],
                "user_metadata": ["display_name": displayName]
            ]
        ]
        
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: sessionJson)
        )
        
        // establish session
        try await client.auth.signIn(email: email, password: "password")
        
        // When: asking for context
        let provider = SupabaseUserContextProvider.defaultProvider(client: client)
        let context = try await provider()
        
        // Then:
        XCTAssertEqual(context.id, userId.uuidString)
        XCTAssertEqual(context.email, email)
        XCTAssertEqual(context.name, displayName)
    }
    
    func testDefaultProviderThrowsWhenSessionMissing() async throws {
        // Given: client initialized with no session (default)
        
        // When: asking for context
        let provider = SupabaseUserContextProvider.defaultProvider(client: client)
        
        // Then:
        await XCTAssertThrowsErrorAsync(try await provider()) { error in
            XCTAssertEqual(error as? PayBackError, .authSessionMissing)
        }
    }
    
    func testDefaultProviderHandleMissingDisplayName() async throws {
        // Given: Session with no display name
        let userId = UUID()
        let email = "nodisplay@example.com"
        let futureDate = Int(Date().timeIntervalSince1970) + 3600
        let sessionJson: [String: Any] = [
            "access_token": "valid.token",
            "token_type": "bearer",
            "expires_in": 3600,
            "expires_at": futureDate,
            "refresh_token": "valid.refresh",
            "user": [
                "id": userId.uuidString,
                "aud": "authenticated",
                "role": "authenticated",
                "email": email,
                "created_at": isoDate(Date()),
                "updated_at": isoDate(Date()),
                "app_metadata": ["provider": "email"],
                "user_metadata": [:] // Empty metadata
            ]
        ]
        
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: sessionJson))
        try await client.auth.signIn(email: email, password: "password")
        
        // When:
        let provider = SupabaseUserContextProvider.defaultProvider(client: client)
        let context = try await provider()
        
        // Then:
        XCTAssertEqual(context.id, userId.uuidString)
        XCTAssertEqual(context.email, email)
        XCTAssertNil(context.name)
    }
}
