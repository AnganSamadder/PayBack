import XCTest
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore

/// Base test case for tests that use Firebase Local Emulator Suite
/// 
/// This class provides:
/// - Automatic emulator configuration
/// - Database cleanup between tests
/// - Helper methods for creating test users
/// - Assertions for Firebase operations
///
/// Usage:
/// ```swift
/// final class MyServiceTests: FirebaseEmulatorTestCase {
///     func testMyFeature() async throws {
///         let user = try await createTestUser(email: "test@example.com", password: "password123")
///         // Your test code here
///     }
/// }
/// ```
class FirebaseEmulatorTestCase: XCTestCase {
    
    // MARK: - Properties
    
    /// Firebase Auth instance configured for emulator
    var auth: Auth!
    
    /// Firestore instance configured for emulator
    var firestore: Firestore!
    
    /// Track created users for cleanup
    private var createdUserIds: [String] = []
    
    /// Track created Firestore documents for cleanup
    private var createdDocumentPaths: [String] = []
    
    /// Track whether the emulator was available during setUp so we can skip teardown work when skipped.
    private var emulatorAvailable = false
    
    // MARK: - Setup & Teardown
    
    override func setUp() async throws {
        try await super.setUp()
        
        try await requireFirebaseEmulator(
            message: "Firebase emulators are not running on localhost – skipping emulator‑dependent tests. Make sure to start them (e.g. ./scripts/start-emulators.sh) when running locally or in CI."
        )
        emulatorAvailable = true
        
        // Get Auth and Firestore instances (already configured for emulator)
        auth = Auth.auth()
        firestore = Firestore.firestore()
        
        // Sign out any existing user
        try? auth.signOut()
        
        // Clear key collections to avoid cross-test leakage
        await clearCollection("expenses")
        await clearCollection("groups")
        await clearCollection("inviteTokens")
        await clearCollection("linkRequests")
        
        // Clear tracked resources
        createdUserIds.removeAll()
        createdDocumentPaths.removeAll()
    }
    
    override func tearDown() async throws {
        // If we skipped because emulators are unavailable, there is nothing to clean up.
        guard emulatorAvailable else {
            try await super.tearDown()
            return
        }
        
        // Clean up created Firestore documents
        for path in createdDocumentPaths {
            try? await firestore.document(path).delete()
        }
        
        // Sign out
        try? auth.signOut()
        
        // Note: We don't delete users here because Firebase Auth emulator
        // automatically clears data between test runs when properly configured
        
        try await super.tearDown()
    }
    
    private func clearCollection(_ name: String) async {
        let snapshot = try? await firestore.collection(name).getDocuments()
        for document in snapshot?.documents ?? [] {
            try? await document.reference.delete()
        }
    }
    
    // MARK: - Helper Methods
    
    /// Create a test user with email and password
    /// - Parameters:
    ///   - email: User's email address
    ///   - password: User's password (must be 6+ characters)
    ///   - displayName: Optional display name
    ///   - signIn: Whether to automatically sign in as this user (default: true)
    /// - Returns: The created AuthDataResult
    @discardableResult
    func createTestUser(
        email: String,
        password: String = "password123",
        displayName: String? = nil,
        signIn: Bool = true
    ) async throws -> AuthDataResult {
        do {
            let result = try await auth.createUser(withEmail: email, password: password)
            createdUserIds.append(result.user.uid)
            
            if let displayName = displayName {
                let changeRequest = result.user.createProfileChangeRequest()
                changeRequest.displayName = displayName
                try await changeRequest.commitChanges()
            }
            
            // Creating a user automatically signs them in
            return result
        } catch let error as NSError {
            // If the user already exists (common when tests reuse static emails),
            // sign the user in instead of failing the test run.
            if error.code == AuthErrorCode.emailAlreadyInUse.rawValue {
                let result = try await auth.signIn(withEmail: email, password: password)
                if let displayName = displayName {
                    let changeRequest = result.user.createProfileChangeRequest()
                    changeRequest.displayName = displayName
                    try await changeRequest.commitChanges()
                }
                if !createdUserIds.contains(result.user.uid) {
                    createdUserIds.append(result.user.uid)
                }
                return result
            }
            throw error
        }
    }
    
    /// Sign in as an existing test user
    /// - Parameters:
    ///   - email: User's email address
    ///   - password: User's password
    /// - Returns: The AuthDataResult from sign in
    @discardableResult
    func signIn(email: String, password: String) async throws -> AuthDataResult {
        return try await auth.signIn(withEmail: email, password: password)
    }
    
    /// Create a Firestore document and track it for cleanup
    /// - Parameters:
    ///   - collection: Collection name
    ///   - documentId: Document ID (uses auto-generated ID if nil)
    ///   - data: Document data
    /// - Returns: The document reference
    @discardableResult
    func createDocument(
        collection: String,
        documentId: String? = nil,
        data: [String: Any]
    ) async throws -> DocumentReference {
        let docRef: DocumentReference
        if let documentId = documentId {
            docRef = firestore.collection(collection).document(documentId)
        } else {
            docRef = firestore.collection(collection).document()
        }
        
        try await docRef.setData(data)
        createdDocumentPaths.append("\(collection)/\(docRef.documentID)")
        
        return docRef
    }
    
    /// Create a Firestore document in a subcollection
    /// - Parameters:
    ///   - parentPath: Parent document path (e.g., "users/test@example.com")
    ///   - collection: Subcollection name
    ///   - documentId: Document ID (uses auto-generated ID if nil)
    ///   - data: Document data
    /// - Returns: The document reference
    @discardableResult
    func createSubcollectionDocument(
        parentPath: String,
        collection: String,
        documentId: String? = nil,
        data: [String: Any]
    ) async throws -> DocumentReference {
        let docRef: DocumentReference
        if let documentId = documentId {
            docRef = firestore.document(parentPath).collection(collection).document(documentId)
        } else {
            docRef = firestore.document(parentPath).collection(collection).document()
        }
        
        try await docRef.setData(data)
        createdDocumentPaths.append("\(parentPath)/\(collection)/\(docRef.documentID)")
        
        return docRef
    }
    
    /// Get the current authenticated user's UID
    /// - Returns: Current user's UID
    /// - Throws: XCTFail if no user is authenticated
    func currentUserId() throws -> String {
        guard let uid = auth.currentUser?.uid else {
            XCTFail("No authenticated user")
            throw NSError(domain: "FirebaseEmulatorTestCase", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No authenticated user"
            ])
        }
        return uid
    }
    
    /// Get the current authenticated user's email
    /// - Returns: Current user's email
    /// - Throws: XCTFail if no user is authenticated or no email
    func currentUserEmail() throws -> String {
        guard let email = auth.currentUser?.email else {
            XCTFail("No authenticated user or email")
            throw NSError(domain: "FirebaseEmulatorTestCase", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "No authenticated user or email"
            ])
        }
        return email
    }
    
    // MARK: - Assertions
    
    /// Assert that a Firestore document exists
    func assertDocumentExists(_ path: String, file: StaticString = #file, line: UInt = #line) async throws {
        let snapshot = try await firestore.document(path).getDocument()
        XCTAssertTrue(snapshot.exists, "Document at \(path) should exist", file: file, line: line)
    }
    
    /// Assert that a Firestore document does not exist
    func assertDocumentNotExists(_ path: String, file: StaticString = #file, line: UInt = #line) async throws {
        let snapshot = try await firestore.document(path).getDocument()
        XCTAssertFalse(snapshot.exists, "Document at \(path) should not exist", file: file, line: line)
    }
    
    /// Assert that a Firestore document has specific field values
    func assertDocumentField(
        _ path: String,
        field: String,
        equals expectedValue: Any,
        file: StaticString = #file,
        line: UInt = #line
    ) async throws {
        let snapshot = try await firestore.document(path).getDocument()
        XCTAssertTrue(snapshot.exists, "Document at \(path) should exist", file: file, line: line)
        
        let data = snapshot.data()
        XCTAssertNotNil(data, "Document data should not be nil", file: file, line: line)
        
        let actualValue = data?[field]
        XCTAssertNotNil(actualValue, "Field '\(field)' should exist", file: file, line: line)
        
        // Handle different types
        if let expected = expectedValue as? String, let actual = actualValue as? String {
            XCTAssertEqual(actual, expected, "Field '\(field)' should equal '\(expected)'", file: file, line: line)
        } else if let expected = expectedValue as? Int, let actual = actualValue as? Int {
            XCTAssertEqual(actual, expected, "Field '\(field)' should equal \(expected)", file: file, line: line)
        } else if let expected = expectedValue as? Bool, let actual = actualValue as? Bool {
            XCTAssertEqual(actual, expected, "Field '\(field)' should equal \(expected)", file: file, line: line)
        } else if let expected = expectedValue as? Double, let actual = actualValue as? Double {
            XCTAssertEqual(actual, expected, accuracy: 0.001, "Field '\(field)' should equal \(expected)", file: file, line: line)
        }
    }
    
    /// Assert that a collection has a specific number of documents
    func assertCollectionCount(
        _ collection: String,
        equals expectedCount: Int,
        file: StaticString = #file,
        line: UInt = #line
    ) async throws {
        let snapshot = try await firestore.collection(collection).getDocuments()
        XCTAssertEqual(
            snapshot.documents.count,
            expectedCount,
            "Collection '\(collection)' should have \(expectedCount) documents",
            file: file,
            line: line
        )
    }
}
