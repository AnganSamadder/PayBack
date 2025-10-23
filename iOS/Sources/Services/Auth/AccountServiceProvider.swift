import Foundation
import FirebaseCore

enum AccountServiceProvider {
    static func makeAccountService() -> AccountService {
        if FirebaseApp.app() != nil {
            return FirestoreAccountService()
        }

        #if DEBUG
        print("[Auth] Firebase not configured – falling back to MockAccountService.")
        #endif
        return MockAccountService()
    }
}
