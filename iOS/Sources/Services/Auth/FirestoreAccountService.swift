import Foundation
import FirebaseCore
import FirebaseFirestore

final class FirestoreAccountService: AccountService {
    private let database: Firestore
    private let collectionName = "users"

    init(database: Firestore = Firestore.firestore()) {
        self.database = database
    }

    func normalizedEmail(from rawValue: String) throws -> String {
        let normalized = EmailValidator.normalized(rawValue)

        guard EmailValidator.isValid(normalized) else {
            throw AccountServiceError.invalidEmail
        }

        return normalized
    }

    func lookupAccount(byEmail email: String) async throws -> UserAccount? {
        do {
            try ensureFirebaseConfigured()

            let sanitized = try normalizedEmail(from: email)
            let document = database.collection(collectionName).document(sanitized)
            let snapshot = try await document.getDocument()

            guard snapshot.exists, let data = snapshot.data() else {
                return nil
            }

            return try makeAccount(from: data, id: snapshot.documentID)
        } catch {
            throw mapError(error)
        }
    }

    func createAccount(email: String, displayName: String) async throws -> UserAccount {
        do {
            try ensureFirebaseConfigured()

            let sanitized = try normalizedEmail(from: email)
            let document = database.collection(collectionName).document(sanitized)

            if try await document.getDocument().exists {
                throw AccountServiceError.duplicateAccount
            }

            let createdAt = Date()
            let payload: [String: Any] = [
                "email": sanitized,
                "displayName": displayName,
                "createdAt": Timestamp(date: createdAt),
                "linkedMemberId": NSNull()
            ]

            try await document.setData(payload)

            return UserAccount(
                id: document.documentID,
                email: sanitized,
                displayName: displayName,
                linkedMemberId: nil,
                createdAt: createdAt
            )
        } catch {
            throw mapError(error)
        }
    }

    func updateLinkedMember(accountId: String, memberId: UUID?) async throws {
        do {
            try ensureFirebaseConfigured()

            let document = database.collection(collectionName).document(accountId)
            var updates: [String: Any] = [:]
            if let memberId {
                updates["linkedMemberId"] = memberId.uuidString
            } else {
                updates["linkedMemberId"] = NSNull()
            }
            updates["updatedAt"] = Timestamp(date: Date())
            try await document.setData(updates, merge: true)
        } catch {
            throw mapError(error)
        }
    }

    func syncFriends(accountEmail: String, friends: [AccountFriend]) async throws {
        do {
            try ensureFirebaseConfigured()

            let friendDocs = database.collection(collectionName)
                .document(accountEmail)
                .collection("friends")

            let now = Date()
            let friendIds = Set(friends.map { $0.memberId.uuidString })

            let batch = database.batch()

            for friend in friends {
                let friendId = friend.memberId.uuidString
                let friendRef = friendDocs.document(friendId)
                let linkedEmail = friend.linkedAccountEmail?.lowercased()
                let linkedAccountId = friend.linkedAccountId
                let hasLinkedAccount = friend.hasLinkedAccount || linkedEmail != nil || linkedAccountId != nil

                var data: [String: Any] = [
                    "memberId": friendId,
                    "name": friend.name,
                    "hasLinkedAccount": hasLinkedAccount,
                    "updatedAt": Timestamp(date: now)
                ]
                data["linkedAccountEmail"] = linkedEmail ?? NSNull()
                data["linkedAccountId"] = linkedAccountId ?? NSNull()
                batch.setData(data, forDocument: friendRef, merge: true)
            }

            let existingFriends = try await friendDocs.getDocuments()
            for document in existingFriends.documents where !friendIds.contains(document.documentID) {
                batch.deleteDocument(document.reference)
            }

            try await batch.commit()
        } catch {
            throw mapError(error)
        }
    }

    func fetchFriends(accountEmail: String) async throws -> [AccountFriend] {
        do {
            try ensureFirebaseConfigured()

            let snapshot = try await database
                .collection(collectionName)
                .document(accountEmail)
                .collection("friends")
                .getDocuments()

            return snapshot.documents.compactMap { document in
                let data = document.data()
                guard let memberIdString = data["memberId"] as? String,
                      let memberId = UUID(uuidString: memberIdString),
                      let name = data["name"] as? String else {
                    return nil
                }

                let hasLinked = data["hasLinkedAccount"] as? Bool ?? false
                let linkedEmail: String?
                if let email = data["linkedAccountEmail"] as? String, !email.isEmpty {
                    linkedEmail = email
                } else {
                    linkedEmail = nil
                }
                let linkedId: String?
                if let id = data["linkedAccountId"] as? String, !id.isEmpty {
                    linkedId = id
                } else {
                    linkedId = nil
                }

                return AccountFriend(
                    memberId: memberId,
                    name: name,
                    hasLinkedAccount: hasLinked,
                    linkedAccountId: linkedId,
                    linkedAccountEmail: linkedEmail
                )
            }
        } catch {
            throw mapError(error)
        }
    }

    private func ensureFirebaseConfigured() throws {
        guard FirebaseApp.app() != nil else {
            throw AccountServiceError.configurationMissing
        }
    }

    private func makeAccount(from data: [String: Any], id: String) throws -> UserAccount {
        guard let email = data["email"] as? String,
              let displayName = data["displayName"] as? String else {
            throw AccountServiceError.underlying(NSError(domain: "FirestoreAccountService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Account document is missing required fields."]))
        }

        let linkedMemberId: UUID?
        if let rawMember = data["linkedMemberId"] as? String {
            linkedMemberId = UUID(uuidString: rawMember)
        } else {
            linkedMemberId = nil
        }

        let createdAt: Date
        if let timestamp = data["createdAt"] as? Timestamp {
            createdAt = timestamp.dateValue()
        } else if let date = data["createdAt"] as? Date {
            createdAt = date
        } else {
            createdAt = Date()
        }

        return UserAccount(
            id: id,
            email: email,
            displayName: displayName,
            linkedMemberId: linkedMemberId,
            createdAt: createdAt
        )
    }

    private func mapError(_ error: Error) -> AccountServiceError {
        if let accountError = error as? AccountServiceError {
            return accountError
        }

        let nsError = error as NSError
        if nsError.domain == FirestoreErrorDomain, let code = FirestoreErrorCode.Code(rawValue: nsError.code) {
            switch code {
            case .unavailable, .deadlineExceeded:
                return .networkUnavailable
            case .invalidArgument:
                return .invalidEmail
            case .alreadyExists:
                return .duplicateAccount
            default:
                return .underlying(error)
            }
        }

        if nsError.domain == NSURLErrorDomain {
            return .networkUnavailable
        }

        return .underlying(error)
    }
}
