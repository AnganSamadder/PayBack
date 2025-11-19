import Foundation
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore

protocol GroupCloudService {
    func fetchGroups() async throws -> [SpendingGroup]
    func upsertGroup(_ group: SpendingGroup) async throws
    func deleteGroups(_ ids: [UUID]) async throws
}

enum GroupCloudServiceError: LocalizedError {
    case userNotAuthenticated

    var errorDescription: String? {
        switch self {
        case .userNotAuthenticated:
            return "Please sign in before syncing groups with the cloud."
        }
    }
}

struct FirestoreGroupCloudService: GroupCloudService {
    private let database: Firestore
    private let collectionName = "groups"

    init(database: Firestore = Firestore.firestore()) {
        self.database = database
    }

    func fetchGroups() async throws -> [SpendingGroup] {
        try ensureFirebaseConfigured()

        guard let currentUser = Auth.auth().currentUser,
              let email = currentUser.email?.lowercased() else {
            throw GroupCloudServiceError.userNotAuthenticated
        }

        let collection = database.collection(collectionName)

        let primarySnapshot = try await collection
            .whereField("ownerAccountId", isEqualTo: currentUser.uid)
            .getDocuments()

        if !primarySnapshot.isEmpty {
            return primarySnapshot.documents.compactMap { group(from: $0) }
        }

        let secondarySnapshot = try await collection
            .whereField("ownerEmail", isEqualTo: email)
            .getDocuments()

        if !secondarySnapshot.isEmpty {
            return secondarySnapshot.documents.compactMap { group(from: $0) }
        }

        let fallbackSnapshot = try await collection.getDocuments()
        return fallbackSnapshot.documents
            .filter { document in
                let data = document.data()
                if let owner = data["ownerAccountId"] as? String, owner == currentUser.uid {
                    return true
                }
                if let ownerEmail = data["ownerEmail"] as? String, ownerEmail.lowercased() == email {
                    return true
                }
                if data["ownerAccountId"] == nil && data["ownerEmail"] == nil {
                    return true
                }
                return false
            }
            .compactMap { group(from: $0) }
    }

    func upsertGroup(_ group: SpendingGroup) async throws {
        try ensureFirebaseConfigured()

        guard let currentUser = Auth.auth().currentUser,
              let email = currentUser.email?.lowercased() else {
            throw GroupCloudServiceError.userNotAuthenticated
        }

        let document = database.collection(collectionName).document(group.id.uuidString)
        try await document.setData(groupPayload(group, ownerEmail: email, ownerAccountId: currentUser.uid), merge: true)
    }

    func deleteGroups(_ ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        try ensureFirebaseConfigured()

        guard Auth.auth().currentUser != nil else {
            throw GroupCloudServiceError.userNotAuthenticated
        }

        let batch = database.batch()
        let collection = database.collection(collectionName)
        for id in ids {
            batch.deleteDocument(collection.document(id.uuidString))
        }
        try await batch.commit()
    }

    private func group(from document: DocumentSnapshot) -> SpendingGroup? {
        guard let data = document.data(),
              let name = data["name"] as? String,
              let membersArray = data["members"] as? [[String: Any]] else {
            return nil
        }

        let members: [GroupMember] = membersArray.compactMap { member in
            guard let idString = member["id"] as? String,
                  let name = member["name"] as? String,
                  let id = UUID(uuidString: idString) else {
                return nil
            }
            return GroupMember(id: id, name: name)
        }

        let createdAt: Date
        if let timestamp = data["createdAt"] as? Timestamp {
            createdAt = timestamp.dateValue()
        } else {
            createdAt = Date()
        }

        let isDirect: Bool?
        if let flag = data["isDirect"] as? Bool {
            isDirect = flag
        } else {
            isDirect = nil
        }

        return SpendingGroup(
            id: UUID(uuidString: document.documentID) ?? UUID(),
            name: name,
            members: members,
            createdAt: createdAt,
            isDirect: isDirect
        )
    }

    private func groupPayload(
        _ group: SpendingGroup,
        ownerEmail: String,
        ownerAccountId: String
    ) -> [String: Any] {
        var payload: [String: Any] = [:]
        payload["name"] = group.name
        payload["members"] = group.members.map { member in
            [
                "id": member.id.uuidString,
                "name": member.name
            ]
        }
        if let isDirect = group.isDirect {
            payload["isDirect"] = isDirect
        }
        payload["ownerEmail"] = ownerEmail
        payload["ownerAccountId"] = ownerAccountId
        payload["createdAt"] = Timestamp(date: group.createdAt)
        payload["updatedAt"] = Timestamp(date: Date())
        return payload
    }

    private func ensureFirebaseConfigured() throws {
        guard FirebaseApp.app() != nil else {
            throw AccountServiceError.configurationMissing
        }
    }
}

enum GroupCloudServiceProvider {
    static func makeService() -> GroupCloudService {
        if FirebaseApp.app() != nil {
            return FirestoreGroupCloudService()
        }

        #if DEBUG
        print("[Groups] Firebase not configured – returning no-op service.")
        #endif
        return NoopGroupCloudService()
    }
}

struct NoopGroupCloudService: GroupCloudService {
    func fetchGroups() async throws -> [SpendingGroup] { [] }
    func upsertGroup(_ group: SpendingGroup) async throws {}
    func deleteGroups(_ ids: [UUID]) async throws {}
}
