import Foundation
import XCTest

/// Base test case class with memory leak detection following supabase-swift conventions.
/// Subclass this for tests that need automatic memory leak checking.
///
/// Usage:
/// ```swift
/// final class MyServiceTests: LeakCheckingTestCase {
///     var sut: MyService!  // System Under Test
///
///     override func setUp() {
///         super.setUp()
///         sut = MyService()
///         trackForMemoryLeaks(sut)
///     }
///
///     override func tearDown() {
///         sut = nil
///         super.tearDown()
///     }
/// }
/// ```
open class LeakCheckingTestCase: XCTestCase {

    /// Objects to check for memory leaks
    private var trackedObjects: [(name: String, weakRef: () -> AnyObject?)] = []

    open override func tearDown() {
        // Check for memory leaks in tracked objects
        for (name, weakRef) in trackedObjects {
            XCTAssertNil(
                weakRef(),
                "\(name) should have been deallocated - potential memory leak detected",
                file: #file,
                line: #line
            )
        }

        trackedObjects.removeAll()
        super.tearDown()
    }

    /// Track an object for memory leak detection.
    /// Call this in setUp for objects that should be deallocated in tearDown.
    /// - Parameters:
    ///   - object: The object to track
    ///   - name: Optional name for the object (defaults to type name)
    ///   - file: Source file (for better error messages)
    ///   - line: Source line (for better error messages)
    public func trackForMemoryLeaks(
        _ object: AnyObject,
        name: String? = nil,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let objectName = name ?? String(describing: type(of: object))
        trackedObjects.append((name: objectName, weakRef: { [weak object] in object }))
    }

    /// Asserts that a specific object has been deallocated.
    /// Useful for explicit checks during test execution.
    /// - Parameters:
    ///   - object: A closure returning the weak reference to check
    ///   - name: Name of the object for error messages
    ///   - file: Source file
    ///   - line: Source line
    public func assertDeallocated(
        _ object: @autoclosure () -> AnyObject?,
        name: String = "Object",
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertNil(
            object(),
            "\(name) should have been deallocated",
            file: file,
            line: line
        )
    }
}

/// Extension providing memory leak detection for standard XCTestCase.
/// Use this when you can't subclass LeakCheckingTestCase.
extension XCTestCase {

    /// Adds a teardown block to check for memory leaks.
    /// Call this after creating objects that should be deallocated.
    ///
    /// Usage:
    /// ```swift
    /// func testMyService() {
    ///     let service = MyService()
    ///     addLeakCheck(service, name: "MyService")
    ///     // ... test code ...
    ///     // Service will be checked for deallocation after test completes
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - object: The object to check for memory leaks
    ///   - name: Name of the object for error messages
    ///   - file: Source file
    ///   - line: Source line
    ///
    /// - Note: The weak capture ensures we detect if the object is still retained.
    ///   If the object is deallocated before teardown (expected behavior), the assertion passes.
    public func addLeakCheck(
        _ object: AnyObject,
        name: String? = nil,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let objectName = name ?? String(describing: type(of: object))

        // Weak capture to detect if object is still retained after test completes
        addTeardownBlock { [weak object] in
            XCTAssertNil(
                object,
                "\(objectName) should have been deallocated - potential memory leak",
                file: file,
                line: line
            )
        }
    }
}
