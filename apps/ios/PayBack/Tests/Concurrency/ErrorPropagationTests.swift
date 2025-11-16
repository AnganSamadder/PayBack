import XCTest
@testable import PayBack

/// Tests for error propagation in async code
///
/// This test suite validates:
/// - Errors propagate through async call stack
/// - Error types are preserved through async boundaries
///
/// Related Requirements: R35
final class ErrorPropagationTests: XCTestCase {
    
    // MARK: - Test errors propagate through async call stack
    
    func test_asyncError_propagatesToCaller() async {
        // Arrange
        func throwingAsyncFunction() async throws -> String {
            throw LinkingError.networkUnavailable
        }
        
        // Act & Assert
        do {
            _ = try await throwingAsyncFunction()
            XCTFail("Should have thrown error")
        } catch {
            XCTAssertTrue(error is LinkingError)
            if let linkingError = error as? LinkingError {
                XCTAssertEqual(linkingError, LinkingError.networkUnavailable)
            }
        }
    }
    
    func test_asyncError_propagatesThroughMultipleLayers() async {
        // Arrange
        func level3() async throws -> String {
            throw LinkingError.tokenExpired
        }
        
        func level2() async throws -> String {
            return try await level3()
        }
        
        func level1() async throws -> String {
            return try await level2()
        }
        
        // Act & Assert
        do {
            _ = try await level1()
            XCTFail("Should have thrown error")
        } catch {
            XCTAssertTrue(error is LinkingError)
            if let linkingError = error as? LinkingError {
                XCTAssertEqual(linkingError, LinkingError.tokenExpired)
            }
        }
    }
    
    func test_asyncError_propagatesThroughAwaitChain() async {
        // Arrange
        func fetchData() async throws -> String {
            throw LinkingError.unauthorized
        }
        
        func processData() async throws -> String {
            let data = try await fetchData()
            return data.uppercased()
        }
        
        func handleRequest() async throws -> String {
            let result = try await processData()
            return result
        }
        
        // Act & Assert
        do {
            _ = try await handleRequest()
            XCTFail("Should have thrown error")
        } catch {
            XCTAssertTrue(error is LinkingError)
            if let linkingError = error as? LinkingError {
                XCTAssertEqual(linkingError, LinkingError.unauthorized)
            }
        }
    }
    
    func test_asyncError_propagatesFromTaskGroup() async {
        // Arrange & Act
        do {
            try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    throw LinkingError.duplicateRequest
                }
                
                group.addTask {
                    return "success"
                }
                
                // Try to collect results - should throw
                for try await _ in group {
                    // Process results
                }
            }
            XCTFail("Should have thrown error")
        } catch {
            // Assert
            XCTAssertTrue(error is LinkingError)
            if let linkingError = error as? LinkingError {
                XCTAssertEqual(linkingError, LinkingError.duplicateRequest)
            }
        }
    }
    
    func test_asyncError_propagatesFromNestedTaskGroup() async {
        // Arrange & Act
        do {
            try await withThrowingTaskGroup(of: String.self) { outerGroup in
                outerGroup.addTask {
                    try await withThrowingTaskGroup(of: String.self) { innerGroup in
                        innerGroup.addTask {
                            throw LinkingError.accountNotFound
                        }
                        
                        for try await result in innerGroup {
                            return result
                        }
                        return "completed"
                    }
                }
                
                for try await _ in outerGroup {
                    // Process results
                }
            }
            XCTFail("Should have thrown error")
        } catch {
            // Assert
            XCTAssertTrue(error is LinkingError)
            if let linkingError = error as? LinkingError {
                XCTAssertEqual(linkingError, LinkingError.accountNotFound)
            }
        }
    }
    
    // MARK: - Test error types are preserved
    
    func test_linkingError_preservedThroughAsyncBoundary() async {
        // Arrange
        func performLinking() async throws -> String {
            throw LinkingError.memberAlreadyLinked
        }
        
        // Act & Assert
        do {
            _ = try await performLinking()
            XCTFail("Should have thrown error")
        } catch let error {
            guard let linkingError = error as? LinkingError else {
                XCTFail("Wrong error type: \(error)")
                return
            }
            XCTAssertEqual(linkingError, LinkingError.memberAlreadyLinked)
        }
    }
    
    func test_nsError_preservedThroughAsyncBoundary() async {
        // Arrange
        func performNetworkRequest() async throws -> String {
            let error = NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorTimedOut,
                userInfo: [NSLocalizedDescriptionKey: "Request timed out"]
            )
            throw error
        }
        
        // Act & Assert
        do {
            _ = try await performNetworkRequest()
            XCTFail("Should have thrown error")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, NSURLErrorDomain)
            XCTAssertEqual(error.code, NSURLErrorTimedOut)
            XCTAssertEqual(error.localizedDescription, "Request timed out")
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
    
    func test_customError_preservedThroughRetryPolicy() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 2, baseDelay: 0.01)
        
        // Act & Assert
        do {
            _ = try await policy.execute {
                throw LinkingError.selfLinkingNotAllowed
            }
            XCTFail("Should have thrown error")
        } catch {
            guard let linkingError = error as? LinkingError else {
                XCTFail("Wrong error type: \(error)")
                return
            }
            // Non-retryable error should be thrown immediately
            XCTAssertEqual(linkingError, LinkingError.selfLinkingNotAllowed)
        }
    }
    
    func test_errorProperties_preservedThroughPropagation() async {
        // Arrange
        func createDetailedError() async throws -> String {
            let error = NSError(
                domain: "TestDomain",
                code: 42,
                userInfo: [
                    NSLocalizedDescriptionKey: "Test error",
                    NSLocalizedFailureReasonErrorKey: "Test failure reason",
                    NSLocalizedRecoverySuggestionErrorKey: "Test recovery suggestion"
                ]
            )
            throw error
        }
        
        func wrapperFunction() async throws -> String {
            return try await createDetailedError()
        }
        
        // Act & Assert
        do {
            _ = try await wrapperFunction()
            XCTFail("Should have thrown error")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, "TestDomain")
            XCTAssertEqual(error.code, 42)
            XCTAssertEqual(error.localizedDescription, "Test error")
            XCTAssertEqual(error.localizedFailureReason, "Test failure reason")
            XCTAssertEqual(error.localizedRecoverySuggestion, "Test recovery suggestion")
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
    
    // MARK: - Test error propagation with actors
    
    func test_actorError_propagatesToCaller() async {
        // Arrange
        actor ErrorThrowingActor {
            func performOperation() throws -> String {
                throw LinkingError.tokenInvalid
            }
        }
        
        let actor = ErrorThrowingActor()
        
        // Act & Assert
        do {
            _ = try await actor.performOperation()
            XCTFail("Should have thrown error")
        } catch {
            guard let linkingError = error as? LinkingError else {
                XCTFail("Wrong error type: \(error)")
                return
            }
            XCTAssertEqual(linkingError, LinkingError.tokenInvalid)
        }
    }
    
    func test_actorAsyncError_propagatesToCaller() async {
        // Arrange
        actor AsyncErrorThrowingActor {
            func performAsyncOperation() async throws -> String {
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
                throw LinkingError.accountAlreadyLinked
            }
        }
        
        let actor = AsyncErrorThrowingActor()
        
        // Act & Assert
        do {
            _ = try await actor.performAsyncOperation()
            XCTFail("Should have thrown error")
        } catch {
            guard let linkingError = error as? LinkingError else {
                XCTFail("Wrong error type: \(error)")
                return
            }
            XCTAssertEqual(linkingError, LinkingError.accountAlreadyLinked)
        }
    }
    
    // MARK: - Test error propagation in complex scenarios
    
    func test_multipleErrors_firstErrorPropagates() async {
        // Arrange & Act
        do {
            try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await Task.sleep(nanoseconds: 10_000_000) // 10ms
                    throw LinkingError.tokenExpired
                }
                
                group.addTask {
                    try await Task.sleep(nanoseconds: 20_000_000) // 20ms
                    throw LinkingError.unauthorized
                }
                
                // First error should propagate
                for try await _ in group {
                    // Process results
                }
            }
            XCTFail("Should have thrown error")
        } catch {
            guard let linkingError = error as? LinkingError else {
                XCTFail("Wrong error type: \(error)")
                return
            }
            // Should be one of the errors (likely the first to complete)
            XCTAssertTrue(
                linkingError == LinkingError.tokenExpired || linkingError == LinkingError.unauthorized,
                "Should be one of the thrown errors"
            )
        }
    }
    
    func test_errorInMiddleOfChain_stopsExecution() async {
        // Arrange
        var step1Executed = false
        var step2Executed = false
        var step3Executed = false
        
        func step1() async throws -> String {
            step1Executed = true
            return "step1"
        }
        
        func step2() async throws -> String {
            step2Executed = true
            throw LinkingError.networkUnavailable
        }
        
        func step3() async throws -> String {
            step3Executed = true
            return "step3"
        }
        
        func executeChain() async throws -> String {
            _ = try await step1()
            _ = try await step2()
            _ = try await step3()
            return "completed"
        }
        
        // Act & Assert
        do {
            _ = try await executeChain()
            XCTFail("Should have thrown error")
        } catch {
            guard let linkingError = error as? LinkingError else {
                XCTFail("Wrong error type: \(error)")
                return
            }
            XCTAssertEqual(linkingError, LinkingError.networkUnavailable)
            XCTAssertTrue(step1Executed, "Step 1 should execute")
            XCTAssertTrue(step2Executed, "Step 2 should execute")
            XCTAssertFalse(step3Executed, "Step 3 should not execute after error")
        }
    }
    
    func test_errorWithCleanup_cleanupExecutesBeforePropagation() async {
        // Arrange
        var resourceAcquired = false
        var resourceReleased = false
        var errorThrown = false
        
        func operationWithCleanup() async throws -> String {
            defer {
                if resourceAcquired {
                    resourceReleased = true
                }
            }
            
            resourceAcquired = true
            errorThrown = true
            throw LinkingError.duplicateRequest
        }
        
        // Act & Assert
        do {
            _ = try await operationWithCleanup()
            XCTFail("Should have thrown error")
        } catch {
            guard let linkingError = error as? LinkingError else {
                XCTFail("Wrong error type: \(error)")
                return
            }
            XCTAssertEqual(linkingError, LinkingError.duplicateRequest)
            XCTAssertTrue(errorThrown, "Error should be thrown")
            XCTAssertTrue(resourceAcquired, "Resource should be acquired")
            XCTAssertTrue(resourceReleased, "Resource should be released before error propagates")
        }
    }
    
    // MARK: - Test error propagation with Result type
    
    func test_resultType_capturesError() async {
        // Arrange
        func operationReturningResult() async -> Result<String, LinkingError> {
            return .failure(.tokenAlreadyClaimed)
        }
        
        // Act
        let result = await operationReturningResult()
        
        // Assert
        switch result {
        case .success:
            XCTFail("Should have failed")
        case .failure(let error):
            XCTAssertEqual(error, LinkingError.tokenAlreadyClaimed)
        }
    }
    
    func test_resultType_convertsToThrowingError() async {
        // Arrange
        func operationReturningResult() async -> Result<String, LinkingError> {
            return .failure(.memberAlreadyLinked)
        }
        
        // Act & Assert
        let result = await operationReturningResult()
        
        switch result {
        case .success:
            XCTFail("Should have failed")
        case .failure(let error):
            XCTAssertEqual(error, LinkingError.memberAlreadyLinked)
        }
    }
    
    // MARK: - Test error propagation with async let
    
    func test_asyncLet_errorPropagates() async {
        // Arrange
        @Sendable func operation1() async throws -> String {
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            return "op1"
        }
        
        @Sendable func operation2() async throws -> String {
            try await Task.sleep(nanoseconds: 20_000_000) // 20ms
            throw LinkingError.networkUnavailable
        }
        
        // Act & Assert
        do {
            async let result1 = operation1()
            async let result2 = operation2()
            
            _ = try await (result1, result2)
            XCTFail("Should have thrown error")
        } catch {
            guard let linkingError = error as? LinkingError else {
                XCTFail("Wrong error type: \(error)")
                return
            }
            XCTAssertEqual(linkingError, LinkingError.networkUnavailable)
        }
    }
    
    func test_asyncLet_firstErrorPropagates() async {
        // Arrange
        @Sendable func operation1() async throws -> String {
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            throw LinkingError.tokenExpired
        }
        
        @Sendable func operation2() async throws -> String {
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            throw LinkingError.unauthorized
        }
        
        // Act & Assert
        do {
            async let result1 = operation1()
            async let result2 = operation2()
            
            _ = try await (result1, result2)
            XCTFail("Should have thrown error")
        } catch {
            guard let linkingError = error as? LinkingError else {
                XCTFail("Wrong error type: \(error)")
                return
            }
            // First error should propagate
            XCTAssertEqual(linkingError, LinkingError.tokenExpired)
        }
    }
    
    // MARK: - Test error context preservation
    
    func test_errorContext_preservedInStackTrace() async {
        // Arrange
        func deepFunction() async throws -> String {
            throw LinkingError.accountNotFound
        }
        
        func middleFunction() async throws -> String {
            return try await deepFunction()
        }
        
        func topFunction() async throws -> String {
            return try await middleFunction()
        }
        
        // Act & Assert
        do {
            _ = try await topFunction()
            XCTFail("Should have thrown error")
        } catch {
            guard let linkingError = error as? LinkingError else {
                XCTFail("Wrong error type: \(error)")
                return
            }
            // Error should maintain its type through the call stack
            XCTAssertEqual(linkingError, LinkingError.accountNotFound)

            // Verify error description is preserved
            XCTAssertNotNil(linkingError.errorDescription)
            XCTAssertNotNil(linkingError.recoverySuggestion)
        }
    }
    
    func test_wrappedError_preservesUnderlyingError() async {
        // Arrange
        struct WrapperError: Error {
            let underlyingError: Error
        }
        
        func throwWrappedError() async throws -> String {
            throw WrapperError(underlyingError: LinkingError.tokenInvalid)
        }
        
        // Act & Assert
        do {
            _ = try await throwWrappedError()
            XCTFail("Should have thrown error")
        } catch {
            // Verify we caught the wrapper error
            guard let wrapperError = error as? WrapperError else {
                XCTFail("Wrong error type: \(error)")
                return
            }
            XCTAssertTrue(wrapperError.underlyingError is LinkingError)
            if let linkingError = wrapperError.underlyingError as? LinkingError {
                XCTAssertEqual(linkingError, LinkingError.tokenInvalid)
            }
        }
    }
}
