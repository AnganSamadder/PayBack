import Foundation

public protocol LinkRequestService {
    /// Creates a link request to connect an account with an unlinked participant
    /// - Parameters:
    ///   - recipientEmail: Email address of the account to send the request to
    ///   - targetMemberId: UUID of the GroupMember to link
    ///   - targetMemberName: Display name of the member
    /// - Returns: The created LinkRequest
    /// - Throws: LinkingError if creation fails (duplicate, unauthorized, etc.)
    func createLinkRequest(
        recipientEmail: String,
        targetMemberId: UUID,
        targetMemberName: String
    ) async throws -> LinkRequest
    
    /// Fetches all incoming link requests for the current user
    /// - Returns: Array of pending link requests sent to the current user
    /// - Throws: LinkingError if fetch fails
    func fetchIncomingRequests() async throws -> [LinkRequest]
    
    /// Fetches all outgoing link requests created by the current user
    /// - Returns: Array of pending link requests created by the current user
    /// - Throws: LinkingError if fetch fails
    func fetchOutgoingRequests() async throws -> [LinkRequest]
    
    /// Fetches previous (accepted/rejected) link requests for the current user
    /// - Returns: Array of accepted or rejected link requests
    /// - Throws: LinkingError if fetch fails
    func fetchPreviousRequests() async throws -> [LinkRequest]
    
    /// Accepts a link request and links the account to the member
    /// - Parameter requestId: UUID of the link request to accept
    /// - Returns: LinkAcceptResult containing the linked account details
    /// - Throws: LinkingError if acceptance fails
    func acceptLinkRequest(_ requestId: UUID) async throws -> LinkAcceptResult
    
    /// Declines a link request
    /// - Parameter requestId: UUID of the link request to decline
    /// - Throws: LinkingError if decline fails
    func declineLinkRequest(_ requestId: UUID) async throws
    
    /// Cancels an outgoing link request
    /// - Parameter requestId: UUID of the link request to cancel
    /// - Throws: LinkingError if cancellation fails
    func cancelLinkRequest(_ requestId: UUID) async throws
}

/// Mock implementation for testing and when Supabase is not configured
public final class MockLinkRequestService: LinkRequestService {
    private static var requests: [UUID: LinkRequest] = [:]
    private static let queue = DispatchQueue(label: "com.payback.mockLinkRequestService", attributes: .concurrent)
    
    public func createLinkRequest(
        recipientEmail: String,
        targetMemberId: UUID,
        targetMemberName: String
    ) async throws -> LinkRequest {
        return try await withCheckedThrowingContinuation { continuation in
            Self.queue.async(flags: .barrier) {
                // Normalize emails for comparison
                let normalizedRecipientEmail = recipientEmail.lowercased().trimmingCharacters(in: .whitespaces)
                let normalizedRequesterEmail = "mock@example.com".lowercased().trimmingCharacters(in: .whitespaces)
                
                // Prevent self-linking
                if normalizedRecipientEmail == normalizedRequesterEmail {
                    continuation.resume(throwing: LinkingError.selfLinkingNotAllowed)
                    return
                }
                
                // Check for duplicate requests
                let existingRequest = Self.requests.values.first { request in
                    request.recipientEmail == recipientEmail &&
                    request.targetMemberId == targetMemberId &&
                    request.status == .pending
                }
                
                if existingRequest != nil {
                    continuation.resume(throwing: LinkingError.duplicateRequest)
                    return
                }
                
                let request = LinkRequest(
                    id: UUID(),
                    requesterId: "mock-user-id",
                    requesterEmail: "mock@example.com",
                    requesterName: "Mock User",
                    recipientEmail: recipientEmail,
                    targetMemberId: targetMemberId,
                    targetMemberName: targetMemberName,
                    createdAt: Date(),
                    status: .pending,
                    expiresAt: Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date(),
                    rejectedAt: nil
                )
                
                Self.requests[request.id] = request
                continuation.resume(returning: request)
            }
        }
    }
    
    public func fetchIncomingRequests() async throws -> [LinkRequest] {
        return await withCheckedContinuation { continuation in
            Self.queue.async {
                let now = Date()
                let result = Self.requests.values.filter { request in
                    request.recipientEmail == "mock@example.com" &&
                    request.status == .pending &&
                    request.expiresAt > now
                }
                continuation.resume(returning: result)
            }
        }
    }
    
    public func fetchOutgoingRequests() async throws -> [LinkRequest] {
        return await withCheckedContinuation { continuation in
            Self.queue.async {
                let now = Date()
                let result = Self.requests.values.filter { request in
                    request.requesterId == "mock-user-id" &&
                    request.status == .pending &&
                    request.expiresAt > now
                }
                continuation.resume(returning: result)
            }
        }
    }
    
    public func fetchPreviousRequests() async throws -> [LinkRequest] {
        return await withCheckedContinuation { continuation in
            Self.queue.async {
                let result = Self.requests.values.filter { request in
                    request.recipientEmail == "mock@example.com" &&
                    (request.status == .accepted || request.status == .declined || request.status == .rejected)
                }
                continuation.resume(returning: result)
            }
        }
    }
    
    public func acceptLinkRequest(_ requestId: UUID) async throws -> LinkAcceptResult {
        return try await withCheckedThrowingContinuation { continuation in
            Self.queue.async(flags: .barrier) {
                guard var request = Self.requests[requestId] else {
                    continuation.resume(throwing: LinkingError.tokenInvalid)
                    return
                }
                
                // Check if expired
                if request.expiresAt <= Date() {
                    continuation.resume(throwing: LinkingError.tokenExpired)
                    return
                }
                
                // Update status
                request.status = .accepted
                Self.requests[requestId] = request
                
                let result = LinkAcceptResult(
                    linkedMemberId: request.targetMemberId,
                    linkedAccountId: "mock-account-id",
                    linkedAccountEmail: "mock@example.com"
                )
                continuation.resume(returning: result)
            }
        }
    }
    
    public func declineLinkRequest(_ requestId: UUID) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            Self.queue.async(flags: .barrier) {
                guard var request = Self.requests[requestId] else {
                    continuation.resume(throwing: LinkingError.tokenInvalid)
                    return
                }
                
                request.status = .declined
                request.rejectedAt = Date()
                Self.requests[requestId] = request
                continuation.resume(returning: ())
            }
        }
    }
    
    public func cancelLinkRequest(_ requestId: UUID) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            Self.queue.async(flags: .barrier) {
                Self.requests.removeValue(forKey: requestId)
                continuation.resume(returning: ())
            }
        }
    }
}

import Supabase

private struct LinkRequestRow: Codable {
    let id: UUID
    let requesterId: String
    let requesterEmail: String
    let requesterName: String
    let recipientEmail: String
    let targetMemberId: UUID
    let targetMemberName: String
    let createdAt: Date
    let status: String
    let expiresAt: Date
    let rejectedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case requesterId = "requester_id"
        case requesterEmail = "requester_email"
        case requesterName = "requester_name"
        case recipientEmail = "recipient_email"
        case targetMemberId = "target_member_id"
        case targetMemberName = "target_member_name"
        case createdAt = "created_at"
        case status
        case expiresAt = "expires_at"
        case rejectedAt = "rejected_at"
    }
}

private struct SupabaseUserContext {
    let id: String
    let email: String
    let name: String
}

/// Supabase implementation of LinkRequestService
final class SupabaseLinkRequestService: LinkRequestService {
    private let client: SupabaseClient
    private let table = "link_requests"
    
    init(client: SupabaseClient = SupabaseClientProvider.client!) {
        self.client = client
    }
    
    func createLinkRequest(
        recipientEmail: String,
        targetMemberId: UUID,
        targetMemberName: String
    ) async throws -> LinkRequest {
        let context = try await userContext()
        let normalizedRecipientEmail = recipientEmail.lowercased().trimmingCharacters(in: .whitespaces)
        
        if normalizedRecipientEmail == context.email {
            throw LinkingError.selfLinkingNotAllowed
        }
        
        let existing: PostgrestResponse<[LinkRequestRow]> = try await client
            .from(table)
            .select()
            .eq("requester_id", value: context.id)
            .eq("recipient_email", value: normalizedRecipientEmail)
            .eq("target_member_id", value: targetMemberId)
            .eq("status", value: LinkRequestStatus.pending.rawValue)
            .execute()
        
        if !existing.value.isEmpty {
            throw LinkingError.duplicateRequest
        }
        
        let request = LinkRequest(
            id: UUID(),
            requesterId: context.id,
            requesterEmail: context.email,
            requesterName: context.name,
            recipientEmail: normalizedRecipientEmail,
            targetMemberId: targetMemberId,
            targetMemberName: targetMemberName,
            createdAt: Date(),
            status: .pending,
            expiresAt: Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date(),
            rejectedAt: nil
        )
        
        let row = LinkRequestRow(
            id: request.id,
            requesterId: request.requesterId,
            requesterEmail: request.requesterEmail,
            requesterName: request.requesterName,
            recipientEmail: request.recipientEmail,
            targetMemberId: request.targetMemberId,
            targetMemberName: request.targetMemberName,
            createdAt: request.createdAt,
            status: request.status.rawValue,
            expiresAt: request.expiresAt,
            rejectedAt: request.rejectedAt
        )
        
        _ = try await client
            .from(table)
            .insert([row], returning: .minimal)
            .execute() as PostgrestResponse<Void>
        
        return request
    }
    
    func fetchIncomingRequests() async throws -> [LinkRequest] {
        let context = try await userContext()
        let now = Date()
        
        let snapshot: PostgrestResponse<[LinkRequestRow]> = try await client
            .from(table)
            .select()
            .eq("recipient_email", value: context.email)
            .eq("status", value: LinkRequestStatus.pending.rawValue)
            .gt("expires_at", value: now)
            .execute()
        
        return snapshot.value.compactMap(linkRequest(from:))
    }
    
    func fetchOutgoingRequests() async throws -> [LinkRequest] {
        let context = try await userContext()
        let now = Date()
        
        let snapshot: PostgrestResponse<[LinkRequestRow]> = try await client
            .from(table)
            .select()
            .eq("requester_id", value: context.id)
            .eq("status", value: LinkRequestStatus.pending.rawValue)
            .gt("expires_at", value: now)
            .execute()
        
        return snapshot.value.compactMap(linkRequest(from:))
    }
    
    func fetchPreviousRequests() async throws -> [LinkRequest] {
        let context = try await userContext()
        
        let snapshot: PostgrestResponse<[LinkRequestRow]> = try await client
            .from(table)
            .select()
            .eq("recipient_email", value: context.email)
            .`in`("status", values: [
                LinkRequestStatus.accepted.rawValue,
                LinkRequestStatus.declined.rawValue,
                LinkRequestStatus.rejected.rawValue
            ])
            .execute()
        
        return snapshot.value.compactMap(linkRequest(from:))
    }
    
    func acceptLinkRequest(_ requestId: UUID) async throws -> LinkAcceptResult {
        let context = try await userContext()
        
        let response: PostgrestResponse<[LinkRequestRow]> = try await client
            .from(table)
            .select()
            .eq("id", value: requestId)
            .limit(1)
            .execute()
        
        guard let row = response.value.first else {
            throw LinkingError.tokenInvalid
        }
        
        guard row.recipientEmail == context.email else {
            throw LinkingError.unauthorized
        }
        
        guard row.expiresAt > Date() else {
            throw LinkingError.tokenExpired
        }
        
        guard row.status == LinkRequestStatus.pending.rawValue else {
            throw LinkingError.tokenAlreadyClaimed
        }
        
        _ = try await client
            .from(table)
            .update(["status": LinkRequestStatus.accepted.rawValue], returning: .minimal)
            .eq("id", value: requestId)
            .eq("status", value: LinkRequestStatus.pending.rawValue)
            .execute() as PostgrestResponse<Void>
        
        return LinkAcceptResult(
            linkedMemberId: row.targetMemberId,
            linkedAccountId: context.id,
            linkedAccountEmail: context.email
        )
    }
    
    func declineLinkRequest(_ requestId: UUID) async throws {
        let context = try await userContext()
        
        let response: PostgrestResponse<[LinkRequestRow]> = try await client
            .from(table)
            .select()
            .eq("id", value: requestId)
            .limit(1)
            .execute()
        
        guard let row = response.value.first else {
            throw LinkingError.tokenInvalid
        }
        
        guard row.recipientEmail == context.email else {
            throw LinkingError.unauthorized
        }
        
        struct DeclinePayload: Encodable {
            let status: String
            let rejectedAt: Date

            enum CodingKeys: String, CodingKey {
                case status
                case rejectedAt = "rejected_at"
            }
        }

        let payload = DeclinePayload(status: LinkRequestStatus.declined.rawValue, rejectedAt: Date())

        _ = try await client
            .from(table)
            .update(payload, returning: .minimal)
            .eq("id", value: requestId)
            .execute() as PostgrestResponse<Void>
    }
    
    func cancelLinkRequest(_ requestId: UUID) async throws {
        let context = try await userContext()
        
        let response: PostgrestResponse<[LinkRequestRow]> = try await client
            .from(table)
            .select()
            .eq("id", value: requestId)
            .limit(1)
            .execute()
        
        guard let row = response.value.first else {
            throw LinkingError.tokenInvalid
        }
        
        guard row.requesterId == context.id else {
            throw LinkingError.unauthorized
        }
        
        _ = try await client
            .from(table)
            .delete(returning: .minimal)
            .eq("id", value: requestId)
            .execute() as PostgrestResponse<Void>
    }
    
    // MARK: - Helpers
    
    private func linkRequest(from row: LinkRequestRow) -> LinkRequest? {
        guard let status = LinkRequestStatus(rawValue: row.status) else { return nil }
        
        return LinkRequest(
            id: row.id,
            requesterId: row.requesterId,
            requesterEmail: row.requesterEmail,
            requesterName: row.requesterName,
            recipientEmail: row.recipientEmail,
            targetMemberId: row.targetMemberId,
            targetMemberName: row.targetMemberName,
            createdAt: row.createdAt,
            status: status,
            expiresAt: row.expiresAt,
            rejectedAt: row.rejectedAt
        )
    }
    
    private func userContext() async throws -> SupabaseUserContext {
        guard SupabaseClientProvider.isConfigured else {
            throw LinkingError.unauthorized
        }
        
        do {
            let session = try await client.auth.session
            guard let email = session.user.email?.lowercased() else {
                throw LinkingError.unauthorized
            }
            let name: String
            if let display = session.user.userMetadata["display_name"], case let .string(value) = display, !value.isEmpty {
                name = value
            } else if let email = session.user.email, let prefix = email.split(separator: "@").first {
                name = String(prefix)
            } else {
                name = "Unknown"
            }
            return SupabaseUserContext(id: session.user.id.uuidString, email: email, name: name)
        } catch {
            throw LinkingError.unauthorized
        }
    }
}

/// Provider for LinkRequestService that returns appropriate implementation
enum LinkRequestServiceProvider {
    static func makeLinkRequestService() -> LinkRequestService {
        if let client = SupabaseClientProvider.client {
            return SupabaseLinkRequestService(client: client)
        }
        
        #if DEBUG
        print("[LinkRequest] Supabase not configured – falling back to MockLinkRequestService.")
        #endif
        return MockLinkRequestService()
    }
}
