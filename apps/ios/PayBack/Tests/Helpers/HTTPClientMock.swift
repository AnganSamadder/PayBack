import Foundation
import XCTest
@testable import PayBack

/// Mock HTTP client for testing network requests following supabase-swift conventions.
/// Allows capturing and verifying HTTP requests without making actual network calls.
/// Thread-safety is ensured via internal DispatchQueue synchronization.
final class HTTPClientMock: @unchecked Sendable {

    /// Represents a captured HTTP request
    struct CapturedRequest: Sendable {
        let url: URL
        let method: String
        let headers: [String: String]
        let body: Data?
        let timestamp: Date

        init(url: URL, method: String, headers: [String: String], body: Data?, timestamp: Date = Date()) {
            self.url = url
            self.method = method
            self.headers = headers
            self.body = body
            self.timestamp = timestamp
        }
    }

    /// Represents a mock response to return
    struct MockResponse: Sendable {
        let data: Data
        let statusCode: Int
        let headers: [String: String]

        init(data: Data = Data(), statusCode: Int = 200, headers: [String: String] = [:]) {
            self.data = data
            self.statusCode = statusCode
            self.headers = headers
        }

        /// Creates a successful JSON response
        static func json(_ json: Any, statusCode: Int = 200) -> MockResponse {
            let data = try? JSONSerialization.data(withJSONObject: json, options: [])
            return MockResponse(data: data ?? Data(), statusCode: statusCode, headers: ["Content-Type": "application/json"])
        }

        /// Creates an error response
        static func error(statusCode: Int, message: String = "Error") -> MockResponse {
            let errorBody = ["error": message]
            let data = try? JSONSerialization.data(withJSONObject: errorBody, options: [])
            return MockResponse(data: data ?? Data(), statusCode: statusCode)
        }
    }

    // MARK: - Properties

    private let queue = DispatchQueue(label: "HTTPClientMock", attributes: .concurrent)
    private var _capturedRequests: [CapturedRequest] = []
    private var _mockResponses: [String: MockResponse] = [:]
    private var _defaultResponse: MockResponse?

    /// All captured requests
    var capturedRequests: [CapturedRequest] {
        queue.sync { _capturedRequests }
    }

    /// The last captured request
    var lastRequest: CapturedRequest? {
        capturedRequests.last
    }

    // MARK: - Configuration

    /// Sets a mock response for a specific URL pattern
    func setResponse(for urlPattern: String, response: MockResponse) {
        queue.async(flags: .barrier) { [weak self] in
            self?._mockResponses[urlPattern] = response
        }
    }

    /// Sets the default response for unmatched URLs
    func setDefaultResponse(_ response: MockResponse) {
        queue.async(flags: .barrier) { [weak self] in
            self?._defaultResponse = response
        }
    }

    /// Clears all captured requests and mock responses
    func reset() {
        queue.async(flags: .barrier) { [weak self] in
            self?._capturedRequests.removeAll()
            self?._mockResponses.removeAll()
            self?._defaultResponse = nil
        }
    }

    // MARK: - Request Simulation

    /// Simulates a request and captures it
    func simulateRequest(
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil
    ) -> MockResponse {
        let request = CapturedRequest(url: url, method: method, headers: headers, body: body)

        queue.async(flags: .barrier) { [weak self] in
            self?._capturedRequests.append(request)
        }

        return queue.sync {
            // Check for matching URL pattern
            for (pattern, response) in _mockResponses {
                if url.absoluteString.contains(pattern) {
                    return response
                }
            }
            return _defaultResponse ?? MockResponse()
        }
    }

    // MARK: - Assertions

    /// Asserts that a request was made to a URL containing the given pattern
    func assertRequestMade(
        containing pattern: String,
        method: String? = nil,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let requests = capturedRequests
        let matching = requests.filter { request in
            let urlMatches = request.url.absoluteString.contains(pattern)
            let methodMatches = method == nil || request.method == method
            return urlMatches && methodMatches
        }

        XCTAssertFalse(
            matching.isEmpty,
            "Expected request to URL containing '\(pattern)'\(method.map { " with method \($0)" } ?? ""), but none found. Captured URLs: \(requests.map { $0.url.absoluteString })",
            file: file,
            line: line
        )
    }

    /// Asserts that no requests were made
    func assertNoRequestsMade(file: StaticString = #file, line: UInt = #line) {
        let requests = capturedRequests
        XCTAssertTrue(
            requests.isEmpty,
            "Expected no requests, but \(requests.count) were made",
            file: file,
            line: line
        )
    }
}
