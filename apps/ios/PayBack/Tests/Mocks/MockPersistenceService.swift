import Foundation
@testable import PayBack

/// Mock persistence service for testing
final class MockPersistenceService: PersistenceServiceProtocol {
    private var storage: AppData = AppData(groups: [], expenses: [])
    private var shouldFail: Bool = false
    
    func save(_ data: AppData) {
        guard !shouldFail else { return }
        storage = data
    }
    
    func load() -> AppData {
        return storage
    }
    
    func clear() {
        storage = AppData(groups: [], expenses: [])
    }
    
    // Test helpers
    func setShouldFail(_ fail: Bool) {
        shouldFail = fail
    }
    
    func reset() {
        storage = AppData(groups: [], expenses: [])
        shouldFail = false
    }
}
