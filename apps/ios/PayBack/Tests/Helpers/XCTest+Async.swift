import XCTest

@discardableResult
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: ((Error) -> Void)? = nil
) async -> Error? {
    do {
        _ = try await expression()
        XCTFail(message(), file: file, line: line)
        return nil
    } catch {
        errorHandler?(error)
        return error
    }
}
