import Foundation
import Supabase

struct SupabaseUserContext {
    let id: String
    let email: String
    let name: String?
}

enum SupabaseUserContextProvider {
    static func defaultProvider(client: SupabaseClient) -> () async throws -> SupabaseUserContext {
        return {
            do {
                let session = try await client.auth.session
                guard let email = session.user.email?.lowercased() else {
                    throw AccountServiceError.userNotFound
                }
                let name: String?
                if let display = session.user.userMetadata["display_name"], case let .string(value) = display {
                    name = value
                } else {
                    name = nil
                }
                return SupabaseUserContext(id: session.user.id.uuidString, email: email, name: name)
            } catch {
                throw AccountServiceError.userNotFound
            }
        }
    }
}
