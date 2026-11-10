import Foundation

#if !PAYBACK_CI_NO_CONVEX
import ConvexMobile

enum ConvexBackendErrorMapper {
    private struct ErrorPayload: Decodable {
        let code: String
        let scope: String?
    }

    static func preservingHistory(_ error: Error) -> Error {
        if let history = historyRecovery(error) { return history }
        return error
    }

    static func historyRecovery(_ error: Error) -> GroupHistoryRecoveryError? {
        if let error = error as? GroupHistoryRecoveryError { return error }
        guard let clientError = error as? ClientError,
              case .ConvexError(let data) = clientError,
              let payload = try? JSONDecoder().decode(GroupHistoryRecoveryError.self, from: Data(data.utf8)),
              ["HISTORY_RECONCILIATION_PENDING", "HISTORY_RECONCILIATION_FAILED"].contains(payload.code)
        else { return nil }
        return payload
    }

    /// Only an exact structured rollback code permits subdivision. An uncertain
    /// response can be replayed with the same IDs, but never proves rollback.
    static func importFailure(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let typed = error as? ImportTransportError { return typed }
        if let history = historyRecovery(error) { return history }
        if let clientError = error as? ClientError {
            switch clientError {
            case .InternalError:
                return ImportTransportError.uncertainOutcome
            case .ServerError:
                return ImportTransportError.rejected(code: "IMPORT_SERVER_REJECTED")
            case .ConvexError(let data):
                guard let payload = try? JSONDecoder().decode(ErrorPayload.self, from: Data(data.utf8)) else {
                    return ImportTransportError.rejected(code: "IMPORT_INVALID_ERROR_PAYLOAD")
                }
                if payload.code == "IMPORT_BUDGET_EXCEEDED" {
                    let scopes = ["request", "identity", "group", "expense", "references", "revisions"]
                    guard let scope = payload.scope, scopes.contains(scope) else {
                        return ImportTransportError.rejected(code: "IMPORT_INVALID_ERROR_PAYLOAD")
                    }
                    return ImportTransportError.budgetExceeded(scope: scope)
                }
                return ImportTransportError.rejected(code: payload.code)
            }
        }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? CancellationError() : ImportTransportError.uncertainOutcome
        }
        if error is DecodingError { return ImportTransportError.uncertainOutcome }
        if error is EncodingError { return ImportTransportError.rejected(code: "IMPORT_INVALID_REQUEST") }
        if let error = error as? PayBackError {
            switch error {
            case .networkUnavailable, .timeout: return ImportTransportError.uncertainOutcome
            default: return ImportTransportError.rejected(code: "IMPORT_REJECTED")
            }
        }
        return ImportTransportError.rejected(code: "IMPORT_REJECTED")
    }
}
#endif
