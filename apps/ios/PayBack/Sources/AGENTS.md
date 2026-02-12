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

## NAVIGATION CONVENTIONS (NATIVE IOS)
- **Push pages must use `NavigationStack` routes**: If a screen should feel like "back to previous page", add a typed route in `App/Navigation/TabRoutes.swift` and navigate via `NavigationLink(value:)` / path mutation.
- **Do not build custom push animations** for normal detail pages (`FriendDetail`, `GroupDetail`, `ExpenseDetail`). Native push/pop and interactive edge-swipe are the default.
- **Modal flows stay modal**: Use `sheet` / `fullScreenCover` for task-style flows (create/add/import/settings/camera/claim/etc). Do not force swipe-back semantics onto modals.
- **Per-tab navigation state lives in `TabNavigationState`**: Keep independent paths for each tab. Switching tabs preserves each tab's stack.
- **Active tab re-tap resets and scrolls to top**: `TabBarReselectObserver` detects reselects; on re-tap clear only that tab's path and refresh that tab root so home content returns to top (Activity also resets segment to default).
- **Tab 2 is reserved FAB spacer**: Never treat tab index `2` as a selectable content tab.
- **Route resolution**: Use `AppStore.navigationGroup(id:)`, `navigationExpense(id:)`, and `navigationMember(id:)` to resolve IDs safely and consistently (including identity equivalence).

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
