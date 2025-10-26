import Foundation

protocol InviteLinkService {
    /// Generates an invite link for an unlinked participant
    /// - Parameters:
    ///   - targetMemberId: UUID of the GroupMember to create invite for
    ///   - targetMemberName: Display name of the member
    /// - Returns: InviteLink containing token, URL, and shareable text
    /// - Throws: LinkingError if generation fails
    func generateInviteLink(
        targetMemberId: UUID,
        targetMemberName: String
    ) async throws -> InviteLink
    
    /// Validates an invite token and returns validation result with expense preview
    /// - Parameter tokenId: UUID of the invite token to validate
    /// - Returns: InviteTokenValidation containing validity status and preview data
    /// - Throws: LinkingError if validation fails
    func validateInviteToken(_ tokenId: UUID) async throws -> InviteTokenValidation
    
    /// Claims an invite token and links the account to the member
    /// - Parameter tokenId: UUID of the invite token to claim
    /// - Returns: LinkAcceptResult containing the linked account details
    /// - Throws: LinkingError if claim fails
    func claimInviteToken(_ tokenId: UUID) async throws -> LinkAcceptResult
    
    /// Fetches all active invite tokens created by the current user
    /// - Returns: Array of active (unclaimed, unexpired) invite tokens
    /// - Throws: LinkingError if fetch fails
    func fetchActiveInvites() async throws -> [InviteToken]
    
    /// Revokes an invite token, preventing it from being claimed
    /// - Parameter tokenId: UUID of the invite token to revoke
    /// - Throws: LinkingError if revocation fails
    func revokeInvite(_ tokenId: UUID) async throws
}

/// Mock implementation for testing and when Firebase is not configured
final class MockInviteLinkService: InviteLinkService {
    private static var tokens: [UUID: InviteToken] = [:]
    
    func generateInviteLink(
        targetMemberId: UUID,
        targetMemberName: String
    ) async throws -> InviteLink {
        let createdAt = Date()
        let expiresAt = Calendar.current.date(byAdding: .day, value: 30, to: createdAt) ?? Date()
        
        let token = InviteToken(
            id: UUID(),
            creatorId: "mock-user-id",
            creatorEmail: "mock@example.com",
            targetMemberId: targetMemberId,
            targetMemberName: targetMemberName,
            createdAt: createdAt,
            expiresAt: expiresAt
        )
        
        Self.tokens[token.id] = token
        
        let url = URL(string: "payback://link/claim?token=\(token.id.uuidString)")!
        let shareText = """
        Hi! I've added you to PayBack for tracking shared expenses.
        
        Tap this link to claim your account and see our expense history:
        \(url.absoluteString)
        
        - \(targetMemberName)
        """
        
        return InviteLink(token: token, url: url, shareText: shareText)
    }
    
    func validateInviteToken(_ tokenId: UUID) async throws -> InviteTokenValidation {
        guard let token = Self.tokens[tokenId] else {
            return InviteTokenValidation(
                isValid: false,
                token: nil,
                expensePreview: nil,
                errorMessage: LinkingError.tokenInvalid.errorDescription
            )
        }
        
        // Check if expired
        if token.expiresAt <= Date() {
            return InviteTokenValidation(
                isValid: false,
                token: token,
                expensePreview: nil,
                errorMessage: LinkingError.tokenExpired.errorDescription
            )
        }
        
        // Check if already claimed
        if token.claimedBy != nil {
            return InviteTokenValidation(
                isValid: false,
                token: token,
                expensePreview: nil,
                errorMessage: LinkingError.tokenAlreadyClaimed.errorDescription
            )
        }
        
        // Mock expense preview
        let preview = ExpensePreview(
            personalExpenses: [],
            groupExpenses: [],
            totalBalance: 0.0,
            groupNames: []
        )
        
        return InviteTokenValidation(
            isValid: true,
            token: token,
            expensePreview: preview,
            errorMessage: nil
        )
    }
    
    func claimInviteToken(_ tokenId: UUID) async throws -> LinkAcceptResult {
        guard var token = Self.tokens[tokenId] else {
            throw LinkingError.tokenInvalid
        }
        
        // Check if expired
        if token.expiresAt <= Date() {
            throw LinkingError.tokenExpired
        }
        
        // Check if already claimed
        if token.claimedBy != nil {
            throw LinkingError.tokenAlreadyClaimed
        }
        
        // Mark as claimed
        token.claimedBy = "mock-account-id"
        token.claimedAt = Date()
        Self.tokens[tokenId] = token
        
        return LinkAcceptResult(
            linkedMemberId: token.targetMemberId,
            linkedAccountId: "mock-account-id",
            linkedAccountEmail: "mock@example.com"
        )
    }
    
    func fetchActiveInvites() async throws -> [InviteToken] {
        let now = Date()
        return Self.tokens.values.filter { token in
            token.claimedBy == nil && token.expiresAt > now
        }
    }
    
    func revokeInvite(_ tokenId: UUID) async throws {
        Self.tokens.removeValue(forKey: tokenId)
    }
}

import FirebaseCore
import FirebaseFirestore
import FirebaseAuth

/// Firestore implementation of InviteLinkService
final class FirestoreInviteLinkService: InviteLinkService {
    private let database: Firestore
    private let collectionName = "inviteTokens"
    
    init(database: Firestore = Firestore.firestore()) {
        self.database = database
    }
    
    func generateInviteLink(
        targetMemberId: UUID,
        targetMemberName: String
    ) async throws -> InviteLink {
        do {
            try ensureFirebaseConfigured()
            guard let currentUser = Auth.auth().currentUser else {
                throw LinkingError.unauthorized
            }
            
            let tokenId = UUID()
            let createdAt = Date()
            let expiresAt = Calendar.current.date(byAdding: .day, value: 30, to: createdAt) ?? Date()
            
            let token = InviteToken(
                id: tokenId,
                creatorId: currentUser.uid,
                creatorEmail: currentUser.email ?? "",
                targetMemberId: targetMemberId,
                targetMemberName: targetMemberName,
                createdAt: createdAt,
                expiresAt: expiresAt
            )
            
            let data: [String: Any] = [
                "id": token.id.uuidString,
                "creatorId": token.creatorId,
                "creatorEmail": token.creatorEmail,
                "targetMemberId": token.targetMemberId.uuidString,
                "targetMemberName": token.targetMemberName,
                "createdAt": Timestamp(date: token.createdAt),
                "expiresAt": Timestamp(date: token.expiresAt)
            ]
            
            try await database
                .collection(collectionName)
                .document(token.id.uuidString)
                .setData(data)
            
            // Generate deep link URL
            let url = URL(string: "payback://link/claim?token=\(token.id.uuidString)")!
            
            // Create shareable text
            let shareText = """
            Hi! I've added you to PayBack for tracking shared expenses.
            
            Tap this link to claim your account and see our expense history:
            \(url.absoluteString)
            
            - \(targetMemberName)
            """
            
            return InviteLink(token: token, url: url, shareText: shareText)
        } catch {
            throw mapError(error)
        }
    }
    
    func validateInviteToken(_ tokenId: UUID) async throws -> InviteTokenValidation {
        do {
            try ensureFirebaseConfigured()
            
            let documentRef = database.collection(collectionName).document(tokenId.uuidString)
            let document = try await documentRef.getDocument()
            
            guard document.exists, let data = document.data() else {
                return InviteTokenValidation(
                    isValid: false,
                    token: nil,
                    expensePreview: nil,
                    errorMessage: LinkingError.tokenInvalid.errorDescription
                )
            }
            
            let token = try parseInviteToken(from: data)
            
            // Check if expired
            if token.expiresAt <= Date() {
                return InviteTokenValidation(
                    isValid: false,
                    token: token,
                    expensePreview: nil,
                    errorMessage: LinkingError.tokenExpired.errorDescription
                )
            }
            
            // Check if already claimed
            if token.claimedBy != nil {
                return InviteTokenValidation(
                    isValid: false,
                    token: token,
                    expensePreview: nil,
                    errorMessage: LinkingError.tokenAlreadyClaimed.errorDescription
                )
            }
            
            // Note: Expense preview generation will be handled by AppStore
            // as it requires access to local expense data
            return InviteTokenValidation(
                isValid: true,
                token: token,
                expensePreview: nil,
                errorMessage: nil
            )
        } catch {
            throw mapError(error)
        }
    }
    
    func claimInviteToken(_ tokenId: UUID) async throws -> LinkAcceptResult {
        do {
            try ensureFirebaseConfigured()
            guard let currentUser = Auth.auth().currentUser,
                  let email = currentUser.email else {
                throw LinkingError.unauthorized
            }
            
            let normalizedEmail = email.lowercased().trimmingCharacters(in: .whitespaces)
            let documentRef = database.collection(collectionName).document(tokenId.uuidString)
            
            // Use a transaction to prevent race conditions
            let result = try await database.runTransaction({ (transaction, errorPointer) -> Any? in
                let document: DocumentSnapshot
                do {
                    document = try transaction.getDocument(documentRef)
                } catch let fetchError as NSError {
                    errorPointer?.pointee = fetchError
                    return nil
                }
                
                guard document.exists, let data = document.data() else {
                    errorPointer?.pointee = NSError(
                        domain: "InviteLinkService",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Token not found"]
                    )
                    return nil
                }
                
                let token: InviteToken
                do {
                    token = try self.parseInviteToken(from: data)
                } catch {
                    errorPointer?.pointee = error as NSError
                    return nil
                }
                
                // Check if expired
                if token.expiresAt <= Date() {
                    errorPointer?.pointee = NSError(
                        domain: "InviteLinkService",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Token expired"]
                    )
                    return nil
                }
                
                // Check if already claimed - this is the critical race condition check
                if token.claimedBy != nil {
                    errorPointer?.pointee = NSError(
                        domain: "InviteLinkService",
                        code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "Token already claimed"]
                    )
                    return nil
                }
                
                // Mark token as claimed within the transaction
                transaction.updateData([
                    "claimedBy": currentUser.uid,
                    "claimedAt": Timestamp(date: Date())
                ], forDocument: documentRef)
                
                return LinkAcceptResult(
                    linkedMemberId: token.targetMemberId,
                    linkedAccountId: currentUser.uid,
                    linkedAccountEmail: normalizedEmail
                ) as Any
            })
            
            guard let linkResult = result as? LinkAcceptResult else {
                throw LinkingError.tokenInvalid
            }
            
            return linkResult
        } catch {
            throw mapError(error)
        }
    }
    
    func fetchActiveInvites() async throws -> [InviteToken] {
        do {
            try ensureFirebaseConfigured()
            guard let currentUser = Auth.auth().currentUser else {
                throw LinkingError.unauthorized
            }
            
            let now = Date()
            
            let snapshot = try await database
                .collection(collectionName)
                .whereField("creatorId", isEqualTo: currentUser.uid)
                .getDocuments()
            
            return snapshot.documents.compactMap { document in
                try? parseInviteToken(from: document.data())
            }.filter { token in
                // Filter to only unclaimed and unexpired tokens
                token.claimedBy == nil && token.expiresAt > now
            }
        } catch {
            throw mapError(error)
        }
    }
    
    func revokeInvite(_ tokenId: UUID) async throws {
        do {
            try ensureFirebaseConfigured()
            guard let currentUser = Auth.auth().currentUser else {
                throw LinkingError.unauthorized
            }
            
            let documentRef = database.collection(collectionName).document(tokenId.uuidString)
            let document = try await documentRef.getDocument()
            
            guard document.exists, let data = document.data() else {
                throw LinkingError.tokenInvalid
            }
            
            let token = try parseInviteToken(from: data)
            
            // Verify the current user is the creator
            guard token.creatorId == currentUser.uid else {
                throw LinkingError.unauthorized
            }
            
            // Delete the token
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
    
    private func parseInviteToken(from data: [String: Any]) throws -> InviteToken {
        guard let idString = data["id"] as? String,
              let id = UUID(uuidString: idString),
              let creatorId = data["creatorId"] as? String,
              let creatorEmail = data["creatorEmail"] as? String,
              let targetMemberIdString = data["targetMemberId"] as? String,
              let targetMemberId = UUID(uuidString: targetMemberIdString),
              let targetMemberName = data["targetMemberName"] as? String else {
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
        
        let claimedBy = data["claimedBy"] as? String
        
        let claimedAt: Date?
        if let timestamp = data["claimedAt"] as? Timestamp {
            claimedAt = timestamp.dateValue()
        } else {
            claimedAt = nil
        }
        
        return InviteToken(
            id: id,
            creatorId: creatorId,
            creatorEmail: creatorEmail,
            targetMemberId: targetMemberId,
            targetMemberName: targetMemberName,
            createdAt: createdAt,
            expiresAt: expiresAt,
            claimedBy: claimedBy,
            claimedAt: claimedAt
        )
    }
    
    private func mapError(_ error: Error) -> LinkingError {
        if let linkingError = error as? LinkingError {
            return linkingError
        }
        
        let nsError = error as NSError
        
        // Handle custom transaction errors
        if nsError.domain == "InviteLinkService" {
            switch nsError.code {
            case -1:
                return .tokenInvalid
            case -2:
                return .tokenExpired
            case -3:
                return .tokenAlreadyClaimed
            default:
                return .tokenInvalid
            }
        }
        
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


/// Provider for InviteLinkService that returns appropriate implementation
enum InviteLinkServiceProvider {
    static func makeInviteLinkService() -> InviteLinkService {
        if FirebaseApp.app() != nil {
            return FirestoreInviteLinkService()
        }
        
        #if DEBUG
        print("[InviteLink] Firebase not configured – falling back to MockInviteLinkService.")
        #endif
        return MockInviteLinkService()
    }
}
