import Foundation
import Combine

// Simple wrapper or shared instance since EmailAuthService is a protocol
@MainActor
class BindableEmailAuthService {
    static let shared: EmailAuthService = EmailAuthServiceProvider.makeService()
}
