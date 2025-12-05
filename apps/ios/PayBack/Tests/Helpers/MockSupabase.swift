import Foundation
import Supabase
import XCTest

struct MockSupabaseResponse {
    let statusCode: Int
    let body: Data
    let headers: [String: String]

    init(statusCode: Int = 200, jsonObject: Any, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.body = try! JSONSerialization.data(withJSONObject: jsonObject, options: [])
        self.headers = headers
    }
}

final class MockSupabaseURLProtocol: URLProtocol {
    private static let queue = DispatchQueue(label: "MockSupabaseURLProtocol")
    private static var responseQueue: [MockSupabaseResponse] = []
    private(set) static var recordedRequests: [URLRequest] = []

    static func reset() {
        queue.sync {
            responseQueue.removeAll()
            recordedRequests.removeAll()
        }
    }

    static func enqueue(_ response: MockSupabaseResponse) {
        queue.sync {
            responseQueue.append(response)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response: MockSupabaseResponse = Self.queue.sync {
            let resp = Self.responseQueue.isEmpty ? MockSupabaseResponse(statusCode: 200, jsonObject: []) : Self.responseQueue.removeFirst()
            Self.recordedRequests.append(request)
            return resp
        }

        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        var headers = response.headers
        headers["Content-Type"] = headers["Content-Type"] ?? "application/json"
        headers["Content-Range"] = headers["Content-Range"] ?? "0-0/1"

        let httpResponse = HTTPURLResponse(url: url, statusCode: response.statusCode, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

func makeMockSupabaseClient() -> SupabaseClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockSupabaseURLProtocol.self]
    let session = URLSession(configuration: config)

    let options = SupabaseClientOptions(
        db: .init(),
        auth: .init(emitLocalSessionAsInitialSession: true),
        global: .init(headers: [:], session: session),
        functions: .init(),
        realtime: .init(),
        storage: .init()
    )

    return SupabaseClient(
        supabaseURL: URL(string: "https://example.supabase.mock")!,
        supabaseKey: "test-key",
        options: options
    )
}

func isoDate(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}
