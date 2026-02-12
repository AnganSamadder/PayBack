# iOS KNOWLEDGE BASE

**Path:** `apps/ios/PayBack/Sources`

**MAINTENANCE PROTOCOL**
- **Update this file** when you discover new patterns, fix subtle bugs, or clarify architecture.
- **Example**: If you fix a race condition in `AppStore`, document the fix pattern here.
- **Goal**: Save the next agent from wasting time on the same issue.

## OVERVIEW
Native Swift iOS app using a hybrid **Centralized Store + MVVM** architecture. `AppStore` is the single source of truth.

## STRUCTURE
```
Sources/
├── App/           # Entry point (`PayBackApp.swift`)
├── Features/      # UI Screens (Auth, Expenses, Groups)
├── Models/        # Domain entities (`SpendingGroup`, `UserAccount`)
├── Services/      # Business logic & Infrastructure
│   ├── State/     # `AppStore.swift` (Global State)
│   ├── Convex/    # Backend integration
│   └── Core/      # DI (`Dependencies.swift`)
└── DesignSystem/  # Reusable UI components
```

## ARCHITECTURAL PATTERNS
- **State Management**: `AppStore` (ObservableObject) holds all app state. Views access it via `@EnvironmentObject`.
- **Views**: "Dumb" views in `Features/` render state from the store.
- **DI**: `Dependencies.current` singleton for service access. Constructor injection supported for tests.
- **Sync**: Real-time sync handled by `AppStore.subscribeToSyncManager`.

## GOTCHAS
- **God Object**: `AppStore.swift` is massive (>1300 lines). Modify with care.
- **CI Flag**: `PAYBACK_CI_NO_CONVEX` mocks out the backend in CI.
- **Convex Env Routing**: Build setting `PAYBACK_CONVEX_ENV` is source of truth (`Debug/Internal=development`, `Release=production`).
- **Auth**: Two-step process: Clerk (Identity) -> Convex (Session).
- **Concurrency**: `MainActor` usage is critical for UI updates from sync.

## TESTING
- **Framework**: XCTest.
- **Strategy**: Unit tests for logic; UI tests for flows.
- **Mocking**: `Dependencies.mock()` allows swapping services.
