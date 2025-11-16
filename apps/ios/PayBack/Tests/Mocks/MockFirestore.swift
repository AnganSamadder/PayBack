import Foundation
@testable import PayBack

/// Thread-safe mock Firestore implementation for testing
/// Simulates Firebase Firestore behavior without external dependencies
actor MockFirestore {
    private var collections: [String: MockCollectionReference] = [:]
    private var shouldFail: Bool = false
    private var failureError: Error?
    
    /// Get or create a collection reference
    func collection(_ path: String) -> MockCollectionReference {
        if collections[path] == nil {
            collections[path] = MockCollectionReference(path: path, firestore: self)
        }
        return collections[path]!
    }
    
    /// Configure the mock to simulate failures
    func setShouldFail(_ fail: Bool, error: Error? = nil) {
        shouldFail = fail
        failureError = error
    }
    
    /// Check if mock is configured to fail
    func getShouldFail() -> (shouldFail: Bool, error: Error?) {
        return (shouldFail, failureError)
    }
    
    /// Reset all mock state for test isolation
    func reset() {
        collections.removeAll()
        shouldFail = false
        failureError = nil
    }
}

/// Mock collection reference with query capabilities
actor MockCollectionReference {
    let path: String
    private weak var firestore: MockFirestore?
    private var documents: [String: [String: Any]] = [:]
    
    init(path: String, firestore: MockFirestore) {
        self.path = path
        self.firestore = firestore
    }
    
    /// Get a document reference
    func document(_ documentId: String) -> MockDocumentReference {
        return MockDocumentReference(
            path: "\(path)/\(documentId)",
            documentId: documentId,
            collection: self
        )
    }
    
    /// Create a query filtering by field equality
    func whereField(_ field: String, isEqualTo value: Any) -> MockQuery {
        return MockQuery(collection: self, filters: [(field, value)])
    }
    
    /// Check if operations should fail
    func checkShouldFail() async throws {
        if let firestore = firestore {
            let (shouldFail, error) = await firestore.getShouldFail()
            if shouldFail {
                throw error ?? MockFirestoreError.operationFailed
            }
        }
    }
    
    /// Get all documents in the collection
    func getDocuments() async throws -> MockQuerySnapshot {
        // Check if should fail
        if let firestore = firestore {
            let (shouldFail, error) = await firestore.getShouldFail()
            if shouldFail {
                throw error ?? MockFirestoreError.operationFailed
            }
        }
        
        let docs = documents.map { MockDocumentSnapshot(id: $0.key, data: $0.value, exists: true) }
        return MockQuerySnapshot(documents: docs)
    }
    
    /// Add a document with auto-generated ID
    func addDocument(data: [String: Any]) async throws -> MockDocumentReference {
        // Check if should fail
        if let firestore = firestore {
            let (shouldFail, error) = await firestore.getShouldFail()
            if shouldFail {
                throw error ?? MockFirestoreError.operationFailed
            }
        }
        
        let docId = UUID().uuidString
        documents[docId] = data
        return document(docId)
    }
    
    /// Internal method to set document data
    func setDocument(_ docId: String, data: [String: Any]) {
        documents[docId] = data
    }
    
    /// Internal method to get document data
    func getDocument(_ docId: String) -> [String: Any]? {
        return documents[docId]
    }
    
    /// Internal method to delete document
    func deleteDocument(_ docId: String) {
        documents.removeValue(forKey: docId)
    }
    
    /// Internal method to get all documents (for queries)
    func getAllDocuments() -> [String: [String: Any]] {
        return documents
    }
}

/// Mock document reference for CRUD operations
class MockDocumentReference {
    let path: String
    let documentId: String
    private weak var collection: MockCollectionReference?
    
    init(path: String, documentId: String, collection: MockCollectionReference) {
        self.path = path
        self.documentId = documentId
        self.collection = collection
    }
    
    /// Set document data
    func setData(_ data: [String: Any], merge: Bool = false) async throws {
        guard let collection = collection else {
            throw MockFirestoreError.collectionNotFound
        }
        
        // Check if should fail
        try await collection.checkShouldFail()
        
        if merge, let existingData = await collection.getDocument(documentId) {
            var mergedData = existingData
            for (key, value) in data {
                mergedData[key] = value
            }
            await collection.setDocument(documentId, data: mergedData)
        } else {
            await collection.setDocument(documentId, data: data)
        }
    }
    
    /// Get document snapshot
    func getDocument() async throws -> MockDocumentSnapshot {
        guard let collection = collection else {
            throw MockFirestoreError.collectionNotFound
        }
        
        // Check if should fail
        try await collection.checkShouldFail()
        
        if let data = await collection.getDocument(documentId) {
            return MockDocumentSnapshot(id: documentId, data: data, exists: true)
        } else {
            return MockDocumentSnapshot(id: documentId, data: [:], exists: false)
        }
    }
    
    /// Delete the document
    func delete() async throws {
        guard let collection = collection else {
            throw MockFirestoreError.collectionNotFound
        }
        
        // Check if should fail
        try await collection.checkShouldFail()
        
        await collection.deleteDocument(documentId)
    }
}

/// Mock query for filtering and fetching documents
class MockQuery {
    private weak var collection: MockCollectionReference?
    private let filters: [(String, Any)]
    
    init(collection: MockCollectionReference, filters: [(String, Any)]) {
        self.collection = collection
        self.filters = filters
    }
    
    /// Execute query and get matching documents
    func getDocuments() async throws -> MockQuerySnapshot {
        guard let collection = collection else {
            throw MockFirestoreError.collectionNotFound
        }
        
        // Check if should fail
        try await collection.checkShouldFail()
        
        let allDocs = await collection.getAllDocuments()
        
        // Apply filters
        let filteredDocs = allDocs.filter { (docId, data) in
            for (field, value) in filters {
                guard let fieldValue = data[field] else {
                    return false
                }
                
                // Compare values based on type
                if let stringValue = value as? String, let fieldString = fieldValue as? String {
                    if fieldString != stringValue {
                        return false
                    }
                } else if let intValue = value as? Int, let fieldInt = fieldValue as? Int {
                    if fieldInt != intValue {
                        return false
                    }
                } else if let doubleValue = value as? Double, let fieldDouble = fieldValue as? Double {
                    if fieldDouble != doubleValue {
                        return false
                    }
                } else if let boolValue = value as? Bool, let fieldBool = fieldValue as? Bool {
                    if fieldBool != boolValue {
                        return false
                    }
                } else {
                    // For other types, use string comparison
                    if "\(fieldValue)" != "\(value)" {
                        return false
                    }
                }
            }
            return true
        }
        
        let docs = filteredDocs.map { MockDocumentSnapshot(id: $0.key, data: $0.value, exists: true) }
        return MockQuerySnapshot(documents: docs)
    }
}

/// Mock query snapshot containing query results
struct MockQuerySnapshot {
    let documents: [MockDocumentSnapshot]
    
    var isEmpty: Bool {
        return documents.isEmpty
    }
    
    var count: Int {
        return documents.count
    }
}

/// Mock document snapshot representing a single document
struct MockDocumentSnapshot {
    let id: String
    let data: [String: Any]
    let exists: Bool
    
    init(id: String, data: [String: Any], exists: Bool = true) {
        self.id = id
        self.data = data
        self.exists = exists
    }
    
    /// Get field value by key
    func get(_ field: String) -> Any? {
        return data[field]
    }
}

/// Errors that can be thrown by mock Firestore operations
enum MockFirestoreError: LocalizedError {
    case operationFailed
    case collectionNotFound
    case documentNotFound
    case networkError
    case permissionDenied
    
    var errorDescription: String? {
        switch self {
        case .operationFailed:
            return "Mock Firestore operation failed"
        case .collectionNotFound:
            return "Collection not found"
        case .documentNotFound:
            return "Document not found"
        case .networkError:
            return "Network error"
        case .permissionDenied:
            return "Permission denied"
        }
    }
}
