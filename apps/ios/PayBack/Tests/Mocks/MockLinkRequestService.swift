import Foundation
@testable import PayBack

/// Mock service for testing link request functionality in AppStore
/// Uses actor for thread-safe concurrent access
actor MockLinkRequestServiceForAppStore: LinkRequestService {
    private var requests: [UUID: LinkRequest] = [:]
    private var userEmail: String = "user@example.com"
    private var requesterId: String = "test-requester-123"
    private var requesterName: String = "Test User"
    
    /// Create a new link request
    func createLinkRequest(
        recipientEmail: String,
        targetMemberId: UUID,
        targetMemberName: String
    ) async throws -> LinkRequest {
        let requesterEmail = self.userEmail
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
            requesterId: self.requesterId,
            requesterEmail: requesterEmail,
            requesterName: self.requesterName,
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
    
    /// Fetches all incoming link requests for the current user
    func fetchIncomingRequests() async throws -> [LinkRequest] {
        return requests.values.filter { req in
            req.recipientEmail.lowercased() == userEmail.lowercased() &&
            req.status == .pending &&
            req.expiresAt > Date()
        }
    }
    
    /// Fetches all outgoing link requests created by the current user
    func fetchOutgoingRequests() async throws -> [LinkRequest] {
        return requests.values.filter { req in
            req.requesterEmail.lowercased() == userEmail.lowercased() &&
            req.status == .pending &&
            req.expiresAt > Date()
        }
    }
    
    /// Fetches previous (accepted/rejected) link requests for the current user
    func fetchPreviousRequests() async throws -> [LinkRequest] {
        return requests.values.filter { req in
            (req.recipientEmail.lowercased() == userEmail.lowercased() ||
             req.requesterEmail.lowercased() == userEmail.lowercased()) &&
            (req.status == .accepted || req.status == .rejected || req.status == .declined)
        }
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
    func declineLinkRequest(_ requestId: UUID) async throws {
        guard var request = requests[requestId] else {
            throw LinkingError.tokenInvalid
        }
        
        // Mark as declined
        request.status = .declined
        requests[requestId] = request
    }
    
    /// Cancels an outgoing link request
    func cancelLinkRequest(_ requestId: UUID) async throws {
        guard requests[requestId] != nil else {
            throw LinkingError.tokenInvalid
        }
        
        // Mark as cancelled by removing it
        requests.removeValue(forKey: requestId)
    }
    
    // MARK: - Test Helper Methods
    
    /// Reject a link request (explicit rejection) - test helper
    func rejectLinkRequest(_ requestId: UUID) async throws {
        guard var request = requests[requestId] else {
            throw LinkingError.tokenInvalid
        }
        
        // Mark as rejected
        request.status = .rejected
        request.rejectedAt = Date()
        requests[requestId] = request
    }
    
    /// Get all pending requests for a recipient - test helper
    func getPendingRequests(recipientEmail: String) async throws -> [LinkRequest] {
        let normalized = recipientEmail.lowercased().trimmingCharacters(in: .whitespaces)
        return requests.values.filter { req in
            req.recipientEmail.lowercased() == normalized &&
            req.status == .pending &&
            req.expiresAt > Date()
        }
    }
    
    /// Get a specific request by ID - test helper
    func getRequest(_ requestId: UUID) async throws -> LinkRequest? {
        return requests[requestId]
    }
    
    /// Set the current user's email for self-linking checks - test helper
    func setUserEmail(_ email: String) {
        self.userEmail = email
    }
    
    /// Set requester details - test helper
    func setRequesterDetails(id: String, name: String) {
        self.requesterId = id
        self.requesterName = name
    }
    
    /// Reset the mock service state - test helper
    func reset() {
        requests.removeAll()
        userEmail = "user@example.com"
        requesterId = "test-requester-123"
        requesterName = "Test User"
    }
    
    /// Add an incoming request directly - test helper
    func addIncomingRequest(_ request: LinkRequest) {
        requests[request.id] = request
    }
    
    /// Add an outgoing request directly - test helper
    func addOutgoingRequest(_ request: LinkRequest) {
        requests[request.id] = request
    }
    
    /// Add a previous request directly - test helper
    func addPreviousRequest(_ request: LinkRequest) {
        requests[request.id] = request
    }
}
