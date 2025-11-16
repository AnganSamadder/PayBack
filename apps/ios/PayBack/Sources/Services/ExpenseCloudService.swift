import Foundation
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore

struct ExpenseParticipant {
    let memberId: UUID
    let name: String
    let linkedAccountId: String?
    let linkedAccountEmail: String?
}

protocol ExpenseCloudService {
    func fetchExpenses() async throws -> [Expense]
    func upsertExpense(_ expense: Expense, participants: [ExpenseParticipant]) async throws
    func deleteExpense(_ id: UUID) async throws
    func clearLegacyMockExpenses() async throws
}

enum ExpenseCloudServiceError: LocalizedError {
    case userNotAuthenticated

    var errorDescription: String? {
        switch self {
        case .userNotAuthenticated:
            return "Please sign in before syncing expenses with the cloud."
        }
    }
}

struct FirestoreExpenseCloudService: ExpenseCloudService {
    private let database: Firestore
    private let collectionName = "expenses"

    init(database: Firestore = Firestore.firestore()) {
        self.database = database
    }

    func fetchExpenses() async throws -> [Expense] {
        try ensureFirebaseConfigured()

        guard let currentUser = Auth.auth().currentUser,
              let email = currentUser.email?.lowercased() else {
            throw ExpenseCloudServiceError.userNotAuthenticated
        }

        let collection = database.collection(collectionName)
        
        // Fetch all expenses and filter locally to ensure we get all matching expenses
        // regardless of which ownership field is populated
        let allSnapshot = try await collection.getDocuments()
        
        return allSnapshot.documents
            .filter { document in
                let data = document.data()
                // Match by ownerAccountId
                if let owner = data["ownerAccountId"] as? String, owner == currentUser.uid {
                    return true
                }
                // Match by ownerEmail
                if let ownerEmail = data["ownerEmail"] as? String, ownerEmail.lowercased() == email {
                    return true
                }
                // Match if no owner fields (legacy data)
                if data["ownerAccountId"] == nil && data["ownerEmail"] == nil {
                    return true
                }
                return false
            }
            .compactMap { expense(from: $0) }
    }

    func upsertExpense(_ expense: Expense, participants: [ExpenseParticipant]) async throws {
        try ensureFirebaseConfigured()

        guard let currentUser = Auth.auth().currentUser,
              let email = currentUser.email?.lowercased() else {
            throw ExpenseCloudServiceError.userNotAuthenticated
        }

        let document = database.collection(collectionName).document(expense.id.uuidString)
        try await document.setData(
            expensePayload(
                expense,
                participants: participants,
                ownerEmail: email,
                ownerAccountId: currentUser.uid
            ),
            merge: true
        )
    }

    func deleteExpense(_ id: UUID) async throws {
        try ensureFirebaseConfigured()

        guard Auth.auth().currentUser != nil else {
            throw ExpenseCloudServiceError.userNotAuthenticated
        }

        try await database
            .collection(collectionName)
            .document(id.uuidString)
            .delete()
    }

    func clearLegacyMockExpenses() async throws {
        try ensureFirebaseConfigured()
        guard let currentUser = Auth.auth().currentUser else {
            throw ExpenseCloudServiceError.userNotAuthenticated
        }

        let snapshot = try await database
            .collection(collectionName)
            .whereField("ownerAccountId", isEqualTo: currentUser.uid)
            .getDocuments()
        let mockSnapshot = try await database
            .collection(collectionName)
            .whereField("isPayBackGeneratedMockData", isEqualTo: true)
            .getDocuments()

        var referencesToDelete: [DocumentReference] = []

        for document in snapshot.documents {
            let data = document.data()
            if data["ownerEmail"] == nil || data["ownerEmail"] is NSNull {
                referencesToDelete.append(document.reference)
            }
        }

        for document in mockSnapshot.documents {
            if !referencesToDelete.contains(where: { $0.path == document.reference.path }) {
                referencesToDelete.append(document.reference)
            }
        }

        guard !referencesToDelete.isEmpty else { return }

        let batch = database.batch()
        referencesToDelete.forEach { batch.deleteDocument($0) }
        try await batch.commit()
    }

    private func ensureFirebaseConfigured() throws {
        guard FirebaseApp.app() != nil else {
            throw AccountServiceError.configurationMissing
        }
    }

    private func expensePayload(
        _ expense: Expense,
        participants: [ExpenseParticipant],
        ownerEmail: String,
        ownerAccountId: String
    ) -> [String: Any] {
        var payload: [String: Any] = [:]
        payload["id"] = expense.id.uuidString
        payload["groupId"] = expense.groupId.uuidString
        payload["description"] = expense.description
        payload["date"] = Timestamp(date: expense.date)
        payload["totalAmount"] = expense.totalAmount
        payload["paidByMemberId"] = expense.paidByMemberId.uuidString
        payload["involvedMemberIds"] = expense.involvedMemberIds.map { $0.uuidString }
        payload["splits"] = expense.splits.map { split in
            return [
                "id": split.id.uuidString,
                "memberId": split.memberId.uuidString,
                "amount": split.amount,
                "isSettled": split.isSettled
            ]
        }
        payload["isSettled"] = expense.isSettled
        payload["ownerEmail"] = ownerEmail
        payload["ownerAccountId"] = ownerAccountId
        payload["participantMemberIds"] = expense.involvedMemberIds.map { $0.uuidString }
        payload["participants"] = participants.map { participant in
            var data: [String: Any] = [
                "memberId": participant.memberId.uuidString,
                "name": participant.name
            ]
            data["linkedAccountId"] = participant.linkedAccountId ?? NSNull()
            data["linkedAccountEmail"] = participant.linkedAccountEmail?.lowercased() ?? NSNull()
            return data
        }
        let linkedParticipants: [[String: Any]] = participants.compactMap { participant in
            guard participant.linkedAccountId != nil || participant.linkedAccountEmail != nil else {
                return nil
            }
            return [
                "memberId": participant.memberId.uuidString,
                "linkedAccountId": participant.linkedAccountId as Any? ?? NSNull(),
                "linkedAccountEmail": participant.linkedAccountEmail?.lowercased() as Any? ?? NSNull(),
                "name": participant.name
            ]
        }
        payload["linkedParticipants"] = linkedParticipants
        payload["createdAt"] = Timestamp(date: expense.date)
        payload["updatedAt"] = Timestamp(date: Date())
        return payload
    }

    private func expense(from document: DocumentSnapshot) -> Expense? {
        guard let data = document.data(),
              let groupIdString = data["groupId"] as? String,
              let description = data["description"] as? String,
              let dateValue = data["date"],
              let totalAmount = data["totalAmount"] as? Double,
              let paidByString = data["paidByMemberId"] as? String,
              let involved = data["involvedMemberIds"] as? [String],
              let splitsArray = data["splits"] as? [[String: Any]]
        else {
            return nil
        }

        let date: Date
        if let timestamp = dateValue as? Timestamp {
            date = timestamp.dateValue()
        } else {
            date = Date()
        }

        let groupId = UUID(uuidString: groupIdString) ?? UUID()
        let paidBy = UUID(uuidString: paidByString) ?? UUID()
        let involvedIds = involved.compactMap { UUID(uuidString: $0) }

        let splits: [ExpenseSplit] = splitsArray.compactMap { item in
            guard let idString = item["id"] as? String,
                  let memberIdString = item["memberId"] as? String,
                  let amount = item["amount"] as? Double,
                  let isSettled = item["isSettled"] as? Bool,
                  let splitId = UUID(uuidString: idString),
                  let memberId = UUID(uuidString: memberIdString) else {
                return nil
            }
            return ExpenseSplit(id: splitId, memberId: memberId, amount: amount, isSettled: isSettled)
        }

        let isSettled = data["isSettled"] as? Bool ?? splits.allSatisfy { $0.isSettled }

        var participantNames: [UUID: String] = [:]
        if let participantsArray = data["participants"] as? [[String: Any]] {
            for participant in participantsArray {
                guard let idString = participant["memberId"] as? String,
                      let memberId = UUID(uuidString: idString),
                      let rawName = participant["name"] as? String else {
                    continue
                }
                let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                participantNames[memberId] = trimmed
            }
        }

        return Expense(
            id: UUID(uuidString: document.documentID) ?? UUID(),
            groupId: groupId,
            description: description,
            date: date,
            totalAmount: totalAmount,
            paidByMemberId: paidBy,
            involvedMemberIds: involvedIds,
            splits: splits,
            isSettled: isSettled,
            participantNames: participantNames.isEmpty ? nil : participantNames
        )
    }
}

struct NoopExpenseCloudService: ExpenseCloudService {
    func fetchExpenses() async throws -> [Expense] { [] }
    func upsertExpense(_ expense: Expense, participants: [ExpenseParticipant]) async throws {}
    func deleteExpense(_ id: UUID) async throws {}
    func clearLegacyMockExpenses() async throws {}
}

enum ExpenseCloudServiceProvider {
    static func makeService() -> ExpenseCloudService {
        if FirebaseApp.app() != nil {
            return FirestoreExpenseCloudService()
        }

        #if DEBUG
        print("[Expenses] Firebase not configured – using NoopExpenseCloudService.")
        #endif
        return NoopExpenseCloudService()
    }
}
