import Foundation

enum AccountServiceProvider {
    static func makeAccountService() -> AccountService {
        if let client = SupabaseClientProvider.client {
            return SupabaseAccountService(client: client)
        }

        #if DEBUG
        print("[Auth] Supabase not configured – falling back to MockAccountService.")
        #endif
        return MockAccountService()
    }
}
