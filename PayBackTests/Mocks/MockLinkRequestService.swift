import Foundation
@testable import PayBack

/// Mock service for testing link request functionality
/// Uses actor for thread-safe concurrent access
actor MockLinkRequestService {
    private var requests: [UUID: LinkRequest] = [:]
    private var userEmail: String = "user@example.com"
    
    /// Create a new link request
    func createLinkRequest(
        recipientEmail: String,
        targetMemberId: UUID,
        targetMemberName: String,
        requesterId: String = "test-requester-123",
        requesterEmail: String = "user@example.com",
        requesterName: String = "Test User"
    ) async throws -> LinkRequest {
        // Prevent self-linking (case-insensitive email comparison)
        let normalizedRequester = requesterEmail.lowercased().trimmingCharacters(in: .whitespaces)
        let normalizedRecipient = recipientEmail.lowercased().trimmingCharacters(in: .whitespaces)
        
        if normalizedRequester == normalizedRecipient {
            throw LinkingError.selfLinkingNotAllowed
        }
        
        // Check for duplicate requests to same email
        let existingRequest = requests.values.first { req in
            req.requesterEmail.lowercased() == normalizedRequester &&
            req.recipientEmail.lowercased() == normalizedRecipient &&
            req.targetMemberId == targetMemberId &&
            req.status == .pending
        }
        
        if existingRequest != nil {
            throw LinkingError.duplicateRequest
        }
        
        let requestId = UUID()
        let createdAt = Date()
        let expiresAt = createdAt.addingTimeInterval(7 * 24 * 3600) // 7 days
        
        let request = LinkRequest(
            id: requestId,
            requesterId: requesterId,
            requesterEmail: requesterEmail,
            requesterName: requesterName,
            recipientEmail: recipientEmail,
            targetMemberId: targetMemberId,
            targetMemberName: targetMemberName,
            createdAt: createdAt,
            status: .pending,
            expiresAt: expiresAt,
            rejectedAt: nil
        )
        
        requests[requestId] = request
        
        return request
    }
    
    /// Accept a link request
    func acceptLinkRequest(_ requestId: UUID) async throws -> LinkAcceptResult {
        guard var request = requests[requestId] else {
            throw LinkingError.tokenInvalid
        }
        
        // Check if expired
        if request.expiresAt < Date() {
            throw LinkingError.tokenExpired
        }
        
        // Check if already processed
        if request.status != .pending {
            throw LinkingError.tokenAlreadyClaimed
        }
        
        // Mark as accepted
        request.status = .accepted
        requests[requestId] = request
        
        return LinkAcceptResult(
            linkedMemberId: request.targetMemberId,
            linkedAccountId: request.requesterId,
            linkedAccountEmail: request.requesterEmail
        )
    }
    
    /// Decline a link request
    func declineLinkRequest(_ requestId: UUID, reason: String? = nil) async throws {
        guard var request = requests[requestId] else {
            throw LinkingError.tokenInvalid
        }
        
        // Mark as declined (note: reason parameter ignored as struct doesn't have declinedReason field)
        request.status = .declined
        requests[requestId] = request
    }
    
    /// Reject a link request (explicit rejection)
    func rejectLinkRequest(_ requestId: UUID) async throws {
        guard var request = requests[requestId] else {
            throw LinkingError.tokenInvalid
        }
        
        // Mark as rejected
        request.status = .rejected
        request.rejectedAt = Date()
        requests[requestId] = request
    }
    
    /// Get all pending requests for a recipient
    func getPendingRequests(recipientEmail: String) async throws -> [LinkRequest] {
        let normalized = recipientEmail.lowercased().trimmingCharacters(in: .whitespaces)
        return requests.values.filter { req in
            req.recipientEmail.lowercased() == normalized &&
            req.status == .pending &&
            req.expiresAt > Date()
        }
    }
    
    /// Get a specific request by ID
    func getRequest(_ requestId: UUID) async throws -> LinkRequest? {
        return requests[requestId]
    }
    
    /// Set the current user's email for self-linking checks
    func setUserEmail(_ email: String) {
        self.userEmail = email
    }
    
    /// Reset the mock service state
    func reset() {
        requests.removeAll()
        userEmail = "user@example.com"
    }
}

