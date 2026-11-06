import Foundation

/// Owns one import presentation at a time, independently of the store's data gate.
/// Every asynchronous UI callback must claim its original ticket before publishing.
struct ImportOperationOwnership {
    struct Ticket: Equatable, Sendable {
        fileprivate let id = UUID()
        fileprivate let accountID: String?
        fileprivate let dataEpoch: UUID
    }

    private var active: Ticket?
    var isActive: Bool { active != nil }

    mutating func begin(accountID: String?, dataEpoch: UUID) -> Ticket? {
        guard active == nil else { return nil }
        let ticket = Ticket(accountID: accountID, dataEpoch: dataEpoch)
        active = ticket
        return ticket
    }

    func owns(_ ticket: Ticket, accountID: String?, dataEpoch: UUID) -> Bool {
        active == ticket && ticket.accountID == accountID && ticket.dataEpoch == dataEpoch
    }

    @discardableResult
    mutating func finish(_ ticket: Ticket, accountID: String?, dataEpoch: UUID) -> Bool {
        guard owns(ticket, accountID: accountID, dataEpoch: dataEpoch) else { return false }
        active = nil
        return true
    }

    mutating func invalidate() { active = nil }
}
