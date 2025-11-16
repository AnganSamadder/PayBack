import XCTest
@testable import PayBack

/// Tests for MockFirestore infrastructure
final class MockFirestoreTests: XCTestCase {
    var mockFirestore: MockFirestore!
    
    override func setUp() async throws {
        try await super.setUp()
        mockFirestore = MockFirestore()
    }
    
    override func tearDown() async throws {
        await mockFirestore.reset()
        mockFirestore = nil
        try await super.tearDown()
    }
    
    // MARK: - Collection and Document Tests
    
    func testCollectionCreation() async {
        let collection = await mockFirestore.collection("test-collection")
        XCTAssertEqual(collection.path, "test-collection")
    }
    
    func testDocumentCreation() async {
        let collection = await mockFirestore.collection("test-collection")
        let document = await collection.document("test-doc")
        XCTAssertEqual(document.documentId, "test-doc")
        XCTAssertEqual(document.path, "test-collection/test-doc")
    }
    
    // MARK: - CRUD Operations
    
    func testSetAndGetDocument() async throws {
        let collection = await mockFirestore.collection("expenses")
        let document = await collection.document("exp-123")
        
        let data: [String: Any] = [
            "description": "Test Expense",
            "amount": 100.0,
            "ownerId": "user-123"
        ]
        
        try await document.setData(data)
        
        let snapshot = try await document.getDocument()
        XCTAssertTrue(snapshot.exists)
        XCTAssertEqual(snapshot.id, "exp-123")
        XCTAssertEqual(snapshot.data["description"] as? String, "Test Expense")
        XCTAssertEqual(snapshot.data["amount"] as? Double, 100.0)
    }
    
    func testSetDataWithMerge() async throws {
        let collection = await mockFirestore.collection("users")
        let document = await collection.document("user-1")
        
        // Set initial data
        try await document.setData(["name": "Alice", "age": 30])
        
        // Merge new data
        try await document.setData(["age": 31, "city": "NYC"], merge: true)
        
        let snapshot = try await document.getDocument()
        XCTAssertEqual(snapshot.data["name"] as? String, "Alice")
        XCTAssertEqual(snapshot.data["age"] as? Int, 31)
        XCTAssertEqual(snapshot.data["city"] as? String, "NYC")
    }
    
    func testDeleteDocument() async throws {
        let collection = await mockFirestore.collection("expenses")
        let document = await collection.document("exp-456")
        
        try await document.setData(["description": "To Delete"])
        
        var snapshot = try await document.getDocument()
        XCTAssertTrue(snapshot.exists)
        
        try await document.delete()
        
        snapshot = try await document.getDocument()
        XCTAssertFalse(snapshot.exists)
    }
    
    func testAddDocument() async throws {
        let collection = await mockFirestore.collection("groups")
        
        let data: [String: Any] = ["name": "Trip Group", "memberCount": 3]
        let docRef = try await collection.addDocument(data: data)
        
        XCTAssertFalse(docRef.documentId.isEmpty)
        
        let snapshot = try await docRef.getDocument()
        XCTAssertTrue(snapshot.exists)
        XCTAssertEqual(snapshot.data["name"] as? String, "Trip Group")
    }
    
    // MARK: - Query Tests
    
    func testGetAllDocuments() async throws {
        let collection = await mockFirestore.collection("expenses")
        
        try await collection.document("exp-1").setData(["amount": 50.0])
        try await collection.document("exp-2").setData(["amount": 75.0])
        try await collection.document("exp-3").setData(["amount": 100.0])
        
        let snapshot = try await collection.getDocuments()
        XCTAssertEqual(snapshot.count, 3)
        XCTAssertFalse(snapshot.isEmpty)
    }
    
    func testWhereFieldQuery() async throws {
        let collection = await mockFirestore.collection("expenses")
        
        try await collection.document("exp-1").setData(["ownerId": "user-1", "amount": 50.0])
        try await collection.document("exp-2").setData(["ownerId": "user-2", "amount": 75.0])
        try await collection.document("exp-3").setData(["ownerId": "user-1", "amount": 100.0])
        
        let query = await collection.whereField("ownerId", isEqualTo: "user-1")
        let snapshot = try await query.getDocuments()
        
        XCTAssertEqual(snapshot.count, 2)
        XCTAssertTrue(snapshot.documents.allSatisfy { $0.data["ownerId"] as? String == "user-1" })
    }
    
    func testWhereFieldQueryNoResults() async throws {
        let collection = await mockFirestore.collection("expenses")
        
        try await collection.document("exp-1").setData(["ownerId": "user-1"])
        
        let query = await collection.whereField("ownerId", isEqualTo: "user-999")
        let snapshot = try await query.getDocuments()
        
        XCTAssertEqual(snapshot.count, 0)
        XCTAssertTrue(snapshot.isEmpty)
    }
    
    // MARK: - Error Simulation Tests
    
    func testSetDataFailure() async throws {
        await mockFirestore.setShouldFail(true, error: MockFirestoreError.networkError)
        
        let collection = await mockFirestore.collection("expenses")
        let document = await collection.document("exp-1")
        
        do {
            try await document.setData(["test": "data"])
            XCTFail("Should have thrown error")
        } catch {
            XCTAssertTrue(error is MockFirestoreError)
        }
    }
    
    func testGetDocumentsFailure() async throws {
        await mockFirestore.setShouldFail(true, error: MockFirestoreError.permissionDenied)
        
        let collection = await mockFirestore.collection("expenses")
        
        do {
            _ = try await collection.getDocuments()
            XCTFail("Should have thrown error")
        } catch {
            XCTAssertTrue(error is MockFirestoreError)
        }
    }
    
    func testQueryFailure() async throws {
        let collection = await mockFirestore.collection("expenses")
        try await collection.document("exp-1").setData(["ownerId": "user-1"])
        
        await mockFirestore.setShouldFail(true, error: MockFirestoreError.networkError)
        
        let query = await collection.whereField("ownerId", isEqualTo: "user-1")
        
        do {
            _ = try await query.getDocuments()
            XCTFail("Should have thrown error")
        } catch {
            XCTAssertTrue(error is MockFirestoreError)
        }
    }
    
    // MARK: - Reset Tests
    
    func testReset() async throws {
        let collection = await mockFirestore.collection("expenses")
        try await collection.document("exp-1").setData(["amount": 100.0])
        
        await mockFirestore.reset()
        
        let newCollection = await mockFirestore.collection("expenses")
        let snapshot = try await newCollection.getDocuments()
        XCTAssertEqual(snapshot.count, 0)
    }
}
