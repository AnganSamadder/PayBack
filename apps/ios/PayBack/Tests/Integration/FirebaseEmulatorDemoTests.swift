import XCTest
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore
@testable import PayBack

/// Demo test suite showing Firebase Emulator integration
/// These tests demonstrate that emulators are working correctly
final class FirebaseEmulatorDemoTests: FirebaseEmulatorTestCase {
    
    // MARK: - Authentication Tests
    
    func testEmulatorAuthCreateUser() async throws {
        // Create a test user through the emulator
        let result = try await createTestUser(
            email: "emulator@test.com",
            password: "password123",
            displayName: "Emulator Test User"
        )
        
        XCTAssertEqual(result.user.email, "emulator@test.com")
        XCTAssertNotNil(result.user.uid)
    }
    
    func testEmulatorAuthSignIn() async throws {
        // Create user
        _ = try await createTestUser(email: "signin@test.com", password: "secret123")
        
        // Sign out
        try auth.signOut()
        
        // Sign back in
        let result = try await signIn(email: "signin@test.com", password: "secret123")
        XCTAssertEqual(result.user.email, "signin@test.com")
    }
    
    func testEmulatorAuthMultipleUsers() async throws {
        // Create multiple users to verify isolation with unique emails
        let email1 = "user1-\(UUID().uuidString.lowercased())@test.com"
        let email2 = "user2-\(UUID().uuidString.lowercased())@test.com"
        
        let user1 = try await createTestUser(email: email1, password: "password123")
        
        // Sign out and create another user
        try auth.signOut()
        let user2 = try await createTestUser(email: email2, password: "password123")
        
        XCTAssertNotEqual(user1.user.uid, user2.user.uid)
        XCTAssertEqual(user2.user.email, email2)
    }
    
    // MARK: - Firestore Tests
    
    func testEmulatorFirestoreCreateDocument() async throws {
        // Create authenticated user first
        let user = try await createTestUser(email: "test@example.com", password: "password123")
        
        // Create a document in Firestore emulator (in user's collection)
        let docRef = try await createDocument(
            collection: "users",
            documentId: user.user.email!,
            data: [
                "displayName": "Test User",
                "createdAt": Date(),
                "uid": user.user.uid
            ]
        )
        
        XCTAssertEqual(docRef.documentID, user.user.email!)
        
        // Verify document exists
        try await assertDocumentExists("users/\(user.user.email!)")
        try await assertDocumentField("users/\(user.user.email!)", field: "displayName", equals: "Test User")
    }
    
    func testEmulatorFirestoreUpdateDocument() async throws {
        // Create authenticated user
        let user = try await createTestUser(email: "update@example.com", password: "password123")
        
        // Create document in user's collection
        let docRef = firestore.collection("users").document(user.user.email!)
        try await docRef.setData([
            "displayName": "Original Name",
            "uid": user.user.uid
        ])
        
        // Update it
        try await docRef.updateData(["displayName": "Updated Name"])
        
        // Verify update
        try await assertDocumentField(
            "users/\(user.user.email!)",
            field: "displayName",
            equals: "Updated Name"
        )
    }
    
    func testEmulatorFirestoreDeleteDocument() async throws {
        // Create authenticated user
        let user = try await createTestUser(email: "delete@example.com", password: "password123")
        
        // Create document in user's collection
        let docRef = firestore.collection("users").document(user.user.email!)
        try await docRef.setData([
            "displayName": "Temp User",
            "uid": user.user.uid
        ])
        
        // Verify it exists
        try await assertDocumentExists("users/\(user.user.email!)")
        
        // Delete it
        try await docRef.delete()
        
        // Verify it's gone
        try await assertDocumentNotExists("users/\(user.user.email!)")
    }
    
    func testEmulatorFirestoreQuery() async throws {
        // Create authenticated user
        let user = try await createTestUser(email: "query@example.com", password: "password123")
        
        // Create multiple expense documents with proper owner fields
        let expensesRef = firestore.collection("expenses")
        try await expensesRef.document().setData([
            "description": "Expense A",
            "amount": 10,
            "ownerEmail": user.user.email!,
            "ownerAccountId": user.user.uid
        ])
        try await expensesRef.document().setData([
            "description": "Expense B",
            "amount": 20,
            "ownerEmail": user.user.email!,
            "ownerAccountId": user.user.uid
        ])
        try await expensesRef.document().setData([
            "description": "Expense C",
            "amount": 30,
            "ownerEmail": user.user.email!,
            "ownerAccountId": user.user.uid
        ])
        
        // Query for expensive expenses
        let snapshot = try await expensesRef
            .whereField("ownerEmail", isEqualTo: user.user.email!)
            .whereField("amount", isGreaterThan: 15)
            .getDocuments()
        
        XCTAssertEqual(snapshot.documents.count, 2)
    }
    
    // MARK: - Combined Auth + Firestore Tests
    
    func testEmulatorUserDocumentCreation() async throws {
        // Create authenticated user
        let authResult = try await createTestUser(
            email: "user@test.com",
            password: "password"
        )
        
        // Create user document in Firestore
        _ = try await createDocument(
            collection: "users",
            documentId: authResult.user.email!,
            data: [
                "uid": authResult.user.uid,
                "email": authResult.user.email!,
                "createdAt": Date()
            ]
        )
        
        // Verify user document
        try await assertDocumentExists("users/\(authResult.user.email!)")
        try await assertDocumentField(
            "users/\(authResult.user.email!)",
            field: "uid",
            equals: authResult.user.uid
        )
    }
    
    func testEmulatorSubcollection() async throws {
        // Create user
        let _ = try await createTestUser(email: "parent@test.com", password: "password123")
        
        // Create subcollection document  
        let subDocRef = try await createSubcollectionDocument(
            parentPath: "users/parent@test.com",
            collection: "friends",
            documentId: "friend1",
            data: [
                "email": "friend@test.com",
                "displayName": "Friend",
                "isLinked": false
            ]
        )
        
        XCTAssertEqual(subDocRef.documentID, "friend1")
        
        // Verify subcollection document
        try await assertDocumentExists("users/parent@test.com/friends/friend1")
        try await assertDocumentField(
            "users/parent@test.com/friends/friend1",
            field: "displayName",
            equals: "Friend"
        )
    }
    
    // MARK: - Emulator Specific Tests
    func testEmulatorIsolation() async throws {
        // This test verifies that each test run starts with a clean state
        // Create authenticated user
        let user = try await createTestUser(email: "isolation@example.com", password: "password123")
        
        // Create a group document with proper authentication
        let groupRef = firestore.collection("groups").document()
        try await groupRef.setData([
            "name": "Test Group",
            "ownerEmail": user.user.email!,
            "ownerAccountId": user.user.uid,
            "isDirect": false
        ])
        
        // Verify we can read it back
        let snapshot = try await firestore.collection("groups")
            .whereField("ownerEmail", isEqualTo: user.user.email!)
            .getDocuments()
        XCTAssertEqual(snapshot.documents.count, 1, "Should only have 1 group")
    }
    
    func testEmulatorPerformance() async throws {
        // Emulator should be fast - create 50 documents quickly
        let user = try await createTestUser(email: "perf@example.com", password: "password123")
        let startTime = Date()
        
        let expensesRef = firestore.collection("expenses")
        for i in 0..<50 {
            try await expensesRef.document().setData([
                "description": "Expense \(i)",
                "amount": Double(i),
                "ownerEmail": user.user.email!,
                "ownerAccountId": user.user.uid
            ])
        }
        
        let elapsed = Date().timeIntervalSince(startTime)
        XCTAssertLessThan(elapsed, 10.0, "Should create 50 documents in under 10 seconds")
        
        // Verify count
        let snapshot = try await expensesRef
            .whereField("ownerEmail", isEqualTo: user.user.email!)
            .getDocuments()
        XCTAssertEqual(snapshot.documents.count, 50)
    }
}
