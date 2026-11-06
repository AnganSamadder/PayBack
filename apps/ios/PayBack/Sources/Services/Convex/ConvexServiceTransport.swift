import Foundation

#if !PAYBACK_CI_NO_CONVEX
import ConvexMobile

/// Only immutable encoded arguments and Sendable results cross the transport actor.
/// Tests replace this boundary while retaining the production adapter's loops and checks.
protocol ConvexServiceTransport: Sendable {
    func query<Response: Decodable & Sendable>(
        _ name: String, arguments: [String: String], yielding: Response.Type
    ) async throws -> Response
    func mutation<Response: Decodable & Sendable>(
        _ name: String, arguments: [String: String], yielding: Response.Type
    ) async throws -> Response
}

extension ConvexServiceTransport {
    func queryPreservingHistory<Response: Decodable & Sendable>(
        _ name: String, arguments: [String: String], yielding: Response.Type
    ) async throws -> Response {
        do { return try await query(name, arguments: arguments, yielding: yielding) }
        catch { throw ConvexBackendErrorMapper.preservingHistory(error) }
    }

    func mutationPreservingHistory<Response: Decodable & Sendable>(
        _ name: String, arguments: [String: String], yielding: Response.Type
    ) async throws -> Response {
        do { return try await mutation(name, arguments: arguments, yielding: yielding) }
        catch { throw ConvexBackendErrorMapper.preservingHistory(error) }
    }
}

enum ConvexTransportArguments {
    static func encode(_ arguments: [String: ConvexEncodable?]) throws -> [String: String] {
        try arguments.mapValues { try $0?.convexEncode() ?? "null" }
    }

    /// These legacy page APIs use optional strings, unlike the nullable cursor
    /// inside Convex's standard paginationOpts object.
    static func page(cursor: String?, limit: Int) -> [String: ConvexEncodable?] {
        var arguments: [String: ConvexEncodable?] = [
            "limit": Double(limit), "financial_contract_version": 2.0
        ]
        if let cursor { arguments["cursor"] = cursor }
        return arguments
    }
}

enum ConvexServiceTransportError: Error {
    case liveClientUnavailable
    case expectedActorRequired
    case streamEndedWithoutValue
}

struct ConvexIgnoredResult: Decodable, Sendable {
    init(from decoder: Decoder) throws {}
}

actor LiveConvexServiceTransport: ConvexServiceTransport {
    private let client: ConvexClient

    init(client: ConvexClient) { self.client = client }

    private struct EncodedArgument: ConvexEncodable {
        let json: String
        func convexEncode() throws -> String { json }
    }

    private func arguments(_ encoded: [String: String]) -> [String: ConvexEncodable?] {
        encoded.mapValues { EncodedArgument(json: $0) }
    }

    func query<Response: Decodable & Sendable>(
        _ name: String, arguments encoded: [String: String], yielding: Response.Type
    ) async throws -> Response {
        try Task.checkCancellation()
        do {
            for try await response in client.subscribe(
                to: name, with: arguments(encoded), yielding: Response.self
            ).values {
                try Task.checkCancellation()
                return response
            }
        } catch {
            throw ConvexBackendErrorMapper.preservingHistory(error)
        }
        throw ConvexServiceTransportError.streamEndedWithoutValue
    }

    func mutation<Response: Decodable & Sendable>(
        _ name: String, arguments encoded: [String: String], yielding: Response.Type
    ) async throws -> Response {
        try Task.checkCancellation()
        do {
            let result: Response = try await client.mutation(name, with: arguments(encoded))
            try Task.checkCancellation()
            return result
        } catch { throw ConvexBackendErrorMapper.preservingHistory(error) }
    }
}
#endif
