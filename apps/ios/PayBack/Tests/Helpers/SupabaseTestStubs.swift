import Foundation
import Supabase

func stubUser(id: UUID = UUID(), email: String? = "user@example.com", phone: String? = nil, name: String? = "User") -> User {
    let metadata: [String: AnyJSON] = name.map { ["display_name": .string($0)] } ?? [:]
    return User(
        id: id,
        appMetadata: [:],
        userMetadata: metadata,
        aud: "authenticated",
        email: email,
        phone: phone,
        createdAt: Date(),
        updatedAt: Date()
    )
}

func stubSession(user: User) -> Session {
    Session(
        providerToken: nil,
        providerRefreshToken: nil,
        accessToken: "token",
        tokenType: "bearer",
        expiresIn: 3600,
        expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970,
        refreshToken: "refresh",
        user: user
    )
}
