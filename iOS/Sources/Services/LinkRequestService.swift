import Foundation

protocol LinkRequestService {
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

/// Mock implementation for testing and when Firebase is not configured
final class MockLinkRequestService: LinkRequestService {
    private static var requests: [UUID: LinkRequest] = [:]
    
    func createLinkRequest(
        recipientEmail: String,
        targetMemberId: UUID,
        targetMemberName: String
    ) async throws -> LinkRequest {
        // Normalize emails for comparison
        let normalizedRecipientEmail = recipientEmail.lowercased().trimmingCharacters(in: .whitespaces)
        let normalizedRequesterEmail = "mock@example.com".lowercased().trimmingCharacters(in: .whitespaces)
        
        // Prevent self-linking
        if normalizedRecipientEmail == normalizedRequesterEmail {
            throw LinkingError.selfLinkingNotAllowed
        }
        
        // Check for duplicate requests
        let existingRequest = Self.requests.values.first { request in
            request.recipientEmail == recipientEmail &&
            request.targetMemberId == targetMemberId &&
            request.status == .pending
        }
        
        if existingRequest != nil {
            throw LinkingError.duplicateRequest
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
        return request
    }
    
    func fetchIncomingRequests() async throws -> [LinkRequest] {
        let now = Date()
        return Self.requests.values.filter { request in
            request.recipientEmail == "mock@example.com" &&
            request.status == .pending &&
            request.expiresAt > now
        }
    }
    
    func fetchOutgoingRequests() async throws -> [LinkRequest] {
        let now = Date()
        return Self.requests.values.filter { request in
            request.requesterId == "mock-user-id" &&
            request.status == .pending &&
            request.expiresAt > now
        }
    }
    
    func fetchPreviousRequests() async throws -> [LinkRequest] {
        return Self.requests.values.filter { request in
            request.recipientEmail == "mock@example.com" &&
            (request.status == .accepted || request.status == .declined || request.status == .rejected)
        }
    }
    
    func acceptLinkRequest(_ requestId: UUID) async throws -> LinkAcceptResult {
        guard var request = Self.requests[requestId] else {
            throw LinkingError.tokenInvalid
        }
        
        // Check if expired
        if request.expiresAt <= Date() {
            throw LinkingError.tokenExpired
        }
        
        // Update status
        request.status = .accepted
        Self.requests[requestId] = request
        
        return LinkAcceptResult(
            linkedMemberId: request.targetMemberId,
            linkedAccountId: "mock-account-id",
            linkedAccountEmail: "mock@example.com"
        )
    }
    
    func declineLinkRequest(_ requestId: UUID) async throws {
        guard var request = Self.requests[requestId] else {
            throw LinkingError.tokenInvalid
        }
        
        request.status = .declined
        request.rejectedAt = Date()
        Self.requests[requestId] = request
    }
    
    func cancelLinkRequest(_ requestId: UUID) async throws {
        Self.requests.removeValue(forKey: requestId)
    }
}

import FirebaseCore
import FirebaseFirestore
import FirebaseAuth

/// Firestore implementation of LinkRequestService
final class FirestoreLinkRequestService: LinkRequestService {
    private let database: Firestore
    private let collectionName = "linkRequests"
    
    init(database: Firestore = Firestore.firestore()) {
        self.database = database
    }
    
    func createLinkRequest(
        recipientEmail: String,
        targetMemberId: UUID,
        targetMemberName: String
    ) async throws -> LinkRequest {
        do {
            try ensureFirebaseConfigured()
            guard let currentUser = Auth.auth().currentUser else {
                throw LinkingError.unauthorized
            }
            
            let normalizedRecipientEmail = recipientEmail.lowercased().trimmingCharacters(in: .whitespaces)
            let currentUserEmail = (currentUser.email ?? "").lowercased().trimmingCharacters(in: .whitespaces)
            
            // Prevent self-linking
            if normalizedRecipientEmail == currentUserEmail {
                throw LinkingError.selfLinkingNotAllowed
            }
            
            // Check for duplicate pending requests
            let existingRequests = try await database
                .collection(collectionName)
                .whereField("requesterId", isEqualTo: currentUser.uid)
                .whereField("recipientEmail", isEqualTo: normalizedRecipientEmail)
                .whereField("targetMemberId", isEqualTo: targetMemberId.uuidString)
                .whereField("status", isEqualTo: LinkRequestStatus.pending.rawValue)
                .getDocuments()
            
            if !existingRequests.documents.isEmpty {
                throw LinkingError.duplicateRequest
            }
            
            let request = LinkRequest(
                id: UUID(),
                requesterId: currentUser.uid,
                requesterEmail: currentUserEmail,
                requesterName: currentUser.displayName ?? "Unknown",
                recipientEmail: normalizedRecipientEmail,
                targetMemberId: targetMemberId,
                targetMemberName: targetMemberName,
                createdAt: Date(),
                status: .pending,
                expiresAt: Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date(),
                rejectedAt: nil
            )
            
            let data: [String: Any] = [
                "id": request.id.uuidString,
                "requesterId": request.requesterId,
                "requesterEmail": request.requesterEmail,
                "requesterName": request.requesterName,
                "recipientEmail": request.recipientEmail,
                "targetMemberId": request.targetMemberId.uuidString,
                "targetMemberName": request.targetMemberName,
                "createdAt": Timestamp(date: request.createdAt),
                "status": request.status.rawValue,
                "expiresAt": Timestamp(date: request.expiresAt)
            ]
            
            try await database
                .collection(collectionName)
                .document(request.id.uuidString)
                .setData(data)
            
            return request
        } catch {
            throw mapError(error)
        }
    }
    
    func fetchIncomingRequests() async throws -> [LinkRequest] {
        do {
            try ensureFirebaseConfigured()
            guard let currentUser = Auth.auth().currentUser,
                  let email = currentUser.email else {
                throw LinkingError.unauthorized
            }
            
            let normalizedEmail = email.lowercased().trimmingCharacters(in: .whitespaces)
            let now = Date()
            
            let snapshot = try await database
                .collection(collectionName)
                .whereField("recipientEmail", isEqualTo: normalizedEmail)
                .whereField("status", isEqualTo: LinkRequestStatus.pending.rawValue)
                .getDocuments()
            
            return snapshot.documents.compactMap { document in
                try? parseLinkRequest(from: document.data())
            }.filter { request in
                // Filter out expired requests
                request.expiresAt > now
            }
        } catch {
            throw mapError(error)
        }
    }
    
    func fetchOutgoingRequests() async throws -> [LinkRequest] {
        do {
            try ensureFirebaseConfigured()
            guard let currentUser = Auth.auth().currentUser else {
                throw LinkingError.unauthorized
            }
            
            let now = Date()
            
            let snapshot = try await database
                .collection(collectionName)
                .whereField("requesterId", isEqualTo: currentUser.uid)
                .whereField("status", isEqualTo: LinkRequestStatus.pending.rawValue)
                .getDocuments()
            
            return snapshot.documents.compactMap { document in
                try? parseLinkRequest(from: document.data())
            }.filter { request in
                // Filter out expired requests
                request.expiresAt > now
            }
        } catch {
            throw mapError(error)
        }
    }
    
    func fetchPreviousRequests() async throws -> [LinkRequest] {
        do {
            try ensureFirebaseConfigured()
            guard let currentUser = Auth.auth().currentUser,
                  let email = currentUser.email else {
                throw LinkingError.unauthorized
            }
            
            let normalizedEmail = email.lowercased().trimmingCharacters(in: .whitespaces)
            
            // Fetch accepted requests
            let acceptedSnapshot = try await database
                .collection(collectionName)
                .whereField("recipientEmail", isEqualTo: normalizedEmail)
                .whereField("status", isEqualTo: LinkRequestStatus.accepted.rawValue)
                .getDocuments()
            
            // Fetch declined requests
            let declinedSnapshot = try await database
                .collection(collectionName)
                .whereField("recipientEmail", isEqualTo: normalizedEmail)
                .whereField("status", isEqualTo: LinkRequestStatus.declined.rawValue)
                .getDocuments()
            
            // Fetch rejected requests
            let rejectedSnapshot = try await database
                .collection(collectionName)
                .whereField("recipientEmail", isEqualTo: normalizedEmail)
                .whereField("status", isEqualTo: LinkRequestStatus.rejected.rawValue)
                .getDocuments()
            
            let acceptedRequests = acceptedSnapshot.documents.compactMap { document in
                try? parseLinkRequest(from: document.data())
            }
            
            let declinedRequests = declinedSnapshot.documents.compactMap { document in
                try? parseLinkRequest(from: document.data())
            }
            
            let rejectedRequests = rejectedSnapshot.documents.compactMap { document in
                try? parseLinkRequest(from: document.data())
            }
            
            return acceptedRequests + declinedRequests + rejectedRequests
        } catch {
            throw mapError(error)
        }
    }
    
    func acceptLinkRequest(_ requestId: UUID) async throws -> LinkAcceptResult {
        do {
            try ensureFirebaseConfigured()
            guard let currentUser = Auth.auth().currentUser,
                  let email = currentUser.email else {
                throw LinkingError.unauthorized
            }
            
            let normalizedEmail = email.lowercased().trimmingCharacters(in: .whitespaces)
            let documentRef = database.collection(collectionName).document(requestId.uuidString)
            
            let document = try await documentRef.getDocument()
            
            guard document.exists, let data = document.data() else {
                throw LinkingError.tokenInvalid
            }
            
            let request = try parseLinkRequest(from: data)
            
            // Verify the current user is the recipient
            guard request.recipientEmail == normalizedEmail else {
                throw LinkingError.unauthorized
            }
            
            // Check if expired
            if request.expiresAt <= Date() {
                throw LinkingError.tokenExpired
            }
            
            // Check if already accepted
            if request.status == .accepted {
                throw LinkingError.tokenAlreadyClaimed
            }
            
            // Update status to accepted
            try await documentRef.updateData([
                "status": LinkRequestStatus.accepted.rawValue
            ])
            
            return LinkAcceptResult(
                linkedMemberId: request.targetMemberId,
                linkedAccountId: currentUser.uid,
                linkedAccountEmail: normalizedEmail
            )
        } catch {
            throw mapError(error)
        }
    }
    
    func declineLinkRequest(_ requestId: UUID) async throws {
        do {
            try ensureFirebaseConfigured()
            guard let currentUser = Auth.auth().currentUser,
                  let email = currentUser.email else {
                throw LinkingError.unauthorized
            }
            
            let normalizedEmail = email.lowercased().trimmingCharacters(in: .whitespaces)
            let documentRef = database.collection(collectionName).document(requestId.uuidString)
            
            let document = try await documentRef.getDocument()
            
            guard document.exists, let data = document.data() else {
                throw LinkingError.tokenInvalid
            }
            
            let request = try parseLinkRequest(from: data)
            
            // Verify the current user is the recipient
            guard request.recipientEmail == normalizedEmail else {
                throw LinkingError.unauthorized
            }
            
            // Update status to declined and store rejection timestamp
            try await documentRef.updateData([
                "status": LinkRequestStatus.declined.rawValue,
                "rejectedAt": Timestamp(date: Date())
            ])
        } catch {
            throw mapError(error)
        }
    }
    
    func cancelLinkRequest(_ requestId: UUID) async throws {
        do {
            try ensureFirebaseConfigured()
            guard let currentUser = Auth.auth().currentUser else {
                throw LinkingError.unauthorized
            }
            
            let documentRef = database.collection(collectionName).document(requestId.uuidString)
            
            let document = try await documentRef.getDocument()
            
            guard document.exists, let data = document.data() else {
                throw LinkingError.tokenInvalid
            }
            
            let request = try parseLinkRequest(from: data)
            
            // Verify the current user is the requester
            guard request.requesterId == currentUser.uid else {
                throw LinkingError.unauthorized
            }
            
            // Delete the request
            try await documentRef.delete()
        } catch {
            throw mapError(error)
        }
    }
    
    // MARK: - Private Helpers
    
    private func ensureFirebaseConfigured() throws {
        guard FirebaseApp.app() != nil else {
            throw LinkingError.unauthorized
        }
    }
    
    private func parseLinkRequest(from data: [String: Any]) throws -> LinkRequest {
        guard let idString = data["id"] as? String,
              let id = UUID(uuidString: idString),
              let requesterId = data["requesterId"] as? String,
              let requesterEmail = data["requesterEmail"] as? String,
              let requesterName = data["requesterName"] as? String,
              let recipientEmail = data["recipientEmail"] as? String,
              let targetMemberIdString = data["targetMemberId"] as? String,
              let targetMemberId = UUID(uuidString: targetMemberIdString),
              let targetMemberName = data["targetMemberName"] as? String,
              let statusString = data["status"] as? String,
              let status = LinkRequestStatus(rawValue: statusString) else {
            throw LinkingError.tokenInvalid
        }
        
        let createdAt: Date
        if let timestamp = data["createdAt"] as? Timestamp {
            createdAt = timestamp.dateValue()
        } else {
            createdAt = Date()
        }
        
        let expiresAt: Date
        if let timestamp = data["expiresAt"] as? Timestamp {
            expiresAt = timestamp.dateValue()
        } else {
            expiresAt = Calendar.current.date(byAdding: .day, value: 30, to: createdAt) ?? Date()
        }
        
        let rejectedAt: Date?
        if let timestamp = data["rejectedAt"] as? Timestamp {
            rejectedAt = timestamp.dateValue()
        } else {
            rejectedAt = nil
        }
        
        return LinkRequest(
            id: id,
            requesterId: requesterId,
            requesterEmail: requesterEmail,
            requesterName: requesterName,
            recipientEmail: recipientEmail,
            targetMemberId: targetMemberId,
            targetMemberName: targetMemberName,
            createdAt: createdAt,
            status: status,
            expiresAt: expiresAt,
            rejectedAt: rejectedAt
        )
    }
    
    private func mapError(_ error: Error) -> LinkingError {
        if let linkingError = error as? LinkingError {
            return linkingError
        }
        
        let nsError = error as NSError
        
        if nsError.domain == FirestoreErrorDomain, let code = FirestoreErrorCode.Code(rawValue: nsError.code) {
            switch code {
            case .unavailable, .deadlineExceeded:
                return .networkUnavailable
            case .permissionDenied, .unauthenticated:
                return .unauthorized
            default:
                return .networkUnavailable
            }
        }
        
        if nsError.domain == NSURLErrorDomain {
            return .networkUnavailable
        }
        
        return .networkUnavailable
    }
}

/// Provider for LinkRequestService that returns appropriate implementation
enum LinkRequestServiceProvider {
    static func makeLinkRequestService() -> LinkRequestService {
        if FirebaseApp.app() != nil {
            return FirestoreLinkRequestService()
        }
        
        #if DEBUG
        print("[LinkRequest] Firebase not configured – falling back to MockLinkRequestService.")
        #endif
        return MockLinkRequestService()
    }
}
