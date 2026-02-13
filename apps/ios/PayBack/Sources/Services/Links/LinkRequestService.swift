//
//  LinkRequestService.swift
//  PayBack
//
//  Adapted for Clerk/Convex migration.
//

import Foundation

public protocol LinkRequestService: Sendable {
    /// Creates a link request to connect an account with an unlinked participant
    func createLinkRequest(
        recipientEmail: String,
        targetMemberId: UUID,
        targetMemberName: String
    ) async throws -> LinkRequest

    /// Fetches all incoming link requests for the current user
    func fetchIncomingRequests() async throws -> [LinkRequest]

    /// Fetches all outgoing link requests created by the current user
    func fetchOutgoingRequests() async throws -> [LinkRequest]

    /// Fetches previous (accepted/rejected) link requests for the current user
    func fetchPreviousRequests() async throws -> [LinkRequest]

    /// Accepts a link request and links the account to the member
    func acceptLinkRequest(_ requestId: UUID) async throws -> LinkAcceptResult

    /// Declines a link request
    func declineLinkRequest(_ requestId: UUID) async throws

    /// Cancels an outgoing link request
    func cancelLinkRequest(_ requestId: UUID) async throws
}

/// Mock implementation for testing
public final class MockLinkRequestService: LinkRequestService, @unchecked Sendable {
    private static var requests: [UUID: LinkRequest] = [:]
    private static let queue = DispatchQueue(label: "com.payback.mockLinkRequestService", attributes: .concurrent)

    public init() {}

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
                    continuation.resume(throwing: PayBackError.linkSelfNotAllowed)
                    return
                }

                // Check for duplicate requests
                let existingRequest = Self.requests.values.first { request in
                    request.recipientEmail == recipientEmail &&
                    request.targetMemberId == targetMemberId &&
                    request.status == .pending
                }

                if existingRequest != nil {
                    continuation.resume(throwing: PayBackError.linkDuplicateRequest)
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
                continuation.resume(returning: Array(result))
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
                continuation.resume(returning: Array(result))
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
                continuation.resume(returning: Array(result))
            }
        }
    }

    public func acceptLinkRequest(_ requestId: UUID) async throws -> LinkAcceptResult {
        return try await withCheckedThrowingContinuation { continuation in
            Self.queue.async(flags: .barrier) {
                guard var request = Self.requests[requestId] else {
                    continuation.resume(throwing: PayBackError.linkInvalid)
                    return
                }

                // Check if expired
                if request.expiresAt <= Date() {
                    continuation.resume(throwing: PayBackError.linkExpired)
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
                    continuation.resume(throwing: PayBackError.linkInvalid)
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
