# Plan: Adopt supabase-swift Conventions for PayBack

The PayBack project has solid foundations but can significantly improve by adopting patterns from supabase-swift around dependency injection, testing infrastructure, concurrency safety, and error handling.

---

## Executive Summary

After analyzing both the **supabase-swift** repository and the **PayBack** project, I've identified several areas where PayBack can improve its code conventions, scalability, and test quality by adopting patterns from supabase-swift.

---

## 1. supabase-swift Conventions and Patterns

### 1.1 Code Organization

**Module Structure** (Sources/):
- Organized by feature/domain modules: `Auth/`, `Functions/`, `PostgREST/`, `Realtime/`, `Storage/`, `Helpers/`
- Each module is a separate SPM target with explicit dependencies
- Shared code lives in `Helpers/` module

**Internal Organization** (e.g., Sources/Auth):
- Public API files at root level
- Internal implementation in `Internal/` subdirectory
- Exports/re-exports in `Exports.swift`
- Deprecated APIs clearly marked in `Deprecated.swift`

### 1.2 Test Structure

**Test Organization** (Tests/):
- Mirror source structure: `AuthTests/`, `FunctionsTests/`, etc.
- Dedicated `IntegrationTests/` for cross-module testing
- Shared test utilities in `TestHelpers/` (a separate SPM target)
- Test resources in `Resources/` subdirectories
- Snapshot storage in `__Snapshots__/`

**Test Patterns**:
```swift
final class AuthClientTests: XCTestCase {
  var sessionManager: SessionManager!
  var storage: InMemoryLocalStorage!
  var http: HTTPClientMock!
  var sut: AuthClient!  // System Under Test convention

  override func invokeTest() {
    withMainSerialExecutor { super.invokeTest() }  // Deterministic async testing
  }

  override func setUp() { ... }
  override func tearDown() {
    Mocker.removeAll()
    // Memory leak detection
    let completion = { [weak sut] in XCTAssertNil(sut, "sut should not leak") }
    defer { completion() }
    sut = nil
  }
}
```

**Key Testing Features**:
- **Snapshot testing** with inline snapshots for HTTP requests
- **HTTP mocking** using `Mocker` library + custom `HTTPClientMock`
- **Memory leak detection** in tearDown
- **Deterministic concurrency** with `withMainSerialExecutor`
- **Dependency injection** via `Dependencies` container

### 1.3 Naming Conventions

**Types**:
- Public types: `AuthClient`, `Session`, `User`
- Internal types: Prefixed context (e.g., `SignUpRequest`, `VerifyOTPParams`)
- Errors: Domain-specific enums (`AuthError`)
- Response types: `*Response` suffix (`AuthResponse`, `SSOResponse`)

**Methods**:
- Async methods: No special suffix, use `async throws`
- Factory/builder: `make*()` pattern
- Test methods: `test<What>_<Condition>_<Expected>()` (e.g., `testSignOut_sessionMissing_throws`)

### 1.4 Error Handling

```swift
public enum AuthError: Error, Sendable {
  case sessionMissing
  case implicitGrantRedirect(message: String)
  case pkceGrantCodeExchange(message: String, error: String?, code: String?)
  case api(message: String, errorCode: String?, underlyingData: Data, underlyingResponse: HTTPURLResponse)
}
```
- Enum-based errors with associated values
- Clear, specific error cases
- Preserved underlying data for debugging

### 1.5 Dependency Management

```swift
dependencies: [
  .package(url: "https://github.com/apple/swift-crypto.git", "1.0.0"..<"5.0.0"),
  .package(url: "https://github.com/pointfreeco/swift-concurrency-extras", from: "1.1.0"),
  .package(url: "https://github.com/pointfreeco/swift-custom-dump", from: "1.3.2"),
  .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0"),
]
```
- Test dependencies separated in test targets only
- Uses Point-Free libraries for enhanced testing
- Version ranges where appropriate

### 1.6 Concurrency Patterns

```swift
public actor AuthClient {
  // Actor-isolated state
  nonisolated private var api: APIClient { Dependencies[clientID].api }
  
  public var session: Session {
    get async throws { try await sessionManager.session() }
  }
}
```
- Actors for thread-safe state
- `nonisolated` for non-mutating accessors
- `@MainActor` for UI-related code
- `Sendable` conformance on all public types

---

## 2. PayBack Project Current State

### 2.1 Code Organization

**Current Structure**:
```
Sources/
├── App/
├── DesignSystem/
├── Features/
│   ├── Activity/
│   ├── Add/
│   ├── Auth/
│   ├── Expenses/
│   ├── Groups/
│   ├── People/
│   ├── Profile/
│   └── Settings/
├── Models/
├── Services/
│   ├── Auth/
│   ├── Core/
│   ├── Expenses/
│   ├── Groups/
│   ├── Links/
│   └── State/
└── PayBackApp.swift
```

**Strengths**:
- Feature-based organization
- Separation of Models, Services, Features

**Gaps**:
- No `Internal/` separation for implementation details
- No centralized `Helpers/` module
- No `Deprecated.swift` for migration paths

### 2.2 Test Structure

**Current Structure**:
```
Tests/
├── BusinessLogic/
├── Concurrency/
├── ErrorHandling/
├── Features/
├── Fixtures/
├── Helpers/
├── Integration/
├── Mocks/
├── Models/
├── Performance/
├── PropertyBased/
├── Serialization/
├── Services/
└── PayBackTests.swift
```

**Strengths**:
- Comprehensive test categories
- Property-based testing
- Performance testing
- Good documentation

**Gaps compared to supabase-swift**:
- No snapshot testing for network requests
- No memory leak detection in tearDown
- No `withMainSerialExecutor` for deterministic async tests
- Mock implementations scattered (not centralized TestHelpers target)

### 2.3 Service Layer Patterns

**Current**:
```swift
protocol AccountService {
    func normalizedEmail(from rawValue: String) throws -> String
    func lookupAccount(byEmail email: String) async throws -> UserAccount?
}

actor MockAccountService: AccountService { ... }
```

**Gaps**:
- Mock in production code (should be in tests)
- No dependency injection container like supabase-swift's `Dependencies`

---

## 3. Implementation Steps

### Step 1: Add `Sendable` Conformance to All Model Types
**Files**: 
- `apps/ios/PayBack/Sources/Models/Expense.swift`
- `apps/ios/PayBack/Sources/Models/GroupMember.swift`

**Change**: Add `Sendable` to struct declarations for safe modern Swift concurrency.

**Status**: [ ] Not Started

---

### Step 2: Create Centralized `Dependencies` Container
**New File**: `apps/ios/PayBack/Sources/Services/Core/Dependencies.swift`

**Pattern**:
```swift
@MainActor
final class Dependencies {
    static var current = Dependencies()
    
    var accountService: AccountService
    var emailAuthService: EmailAuthService
    // ...
    
    private init() {
        accountService = SupabaseAccountService()
        emailAuthService = SupabaseEmailAuthService()
    }
    
    static func mock() -> Dependencies {
        let deps = Dependencies()
        deps.accountService = MockAccountService()
        return deps
    }
}
```

**Status**: [ ] Not Started

---

### Step 3: Relocate MockAccountService to Tests
**From**: `apps/ios/PayBack/Sources/Services/Auth/AccountService.swift`
**To**: `apps/ios/PayBack/Tests/Mocks/MockAccountService.swift`

**Status**: [ ] Not Started

---

### Step 4: Create Unified Domain Error Type
**New File**: `apps/ios/PayBack/Sources/Services/Core/PayBackError.swift`

**Pattern**:
```swift
public enum PayBackError: Error, Sendable {
    // Auth errors
    case authSessionMissing
    case authInvalidCredentials(message: String)
    
    // Account errors
    case accountNotFound(email: String)
    case accountDuplicate(email: String)
    
    // Network errors
    case networkUnavailable
    case api(message: String, statusCode: Int, data: Data)
    
    // Expense errors
    case expenseInvalidAmount(amount: Decimal, reason: String)
    case expenseSplitMismatch(expected: Decimal, actual: Decimal)
}
```

**Status**: [ ] Not Started

---

### Step 5: Enhance Test Infrastructure

#### 5a: Add Memory Leak Detection
**Files**: All test files

**Pattern**:
```swift
override func tearDown() {
    let completion = { [weak sut] in
        XCTAssertNil(sut, "sut should not leak")
    }
    defer { completion() }
    sut = nil
    super.tearDown()
}
```

**Status**: [ ] Not Started

#### 5b: Add Deterministic Async Testing Helper
**New File**: `apps/ios/PayBack/Tests/Helpers/MainSerialExecutor.swift`

```swift
import ConcurrencyExtras

extension XCTestCase {
    func withMainSerialExecutor(_ operation: () -> Void) {
        ConcurrencyExtras.withMainSerialExecutor { operation() }
    }
}
```

**Status**: [ ] Not Started

#### 5c: Add HTTPClientMock
**New File**: `apps/ios/PayBack/Tests/Helpers/HTTPClientMock.swift`

**Status**: [ ] Not Started

---

### Step 6: Add Snapshot Testing & Strict Concurrency
**File**: `project.yml`

**Changes**:
1. Add `swift-snapshot-testing` dependency
2. Add `swift-concurrency-extras` dependency
3. Enable `SWIFT_STRICT_CONCURRENCY: complete`

**Status**: [ ] Not Started

---

## 4. Priority Matrix

### High Priority (Immediate)

| Action | File(s) | Effort |
|--------|---------|--------|
| Add `Sendable` to all model types | Models/*.swift | Low |
| Move `MockAccountService` to tests | AccountService.swift → Tests/Mocks/ | Low |
| Add memory leak detection to tests | All test files | Medium |
| Create centralized `Dependencies` container | New file in Services/Core/ | Medium |

### Medium Priority (Next Sprint)

| Action | File(s) | Effort |
|--------|---------|--------|
| Add snapshot testing for API calls | New test infrastructure | High |
| Implement `HTTPClientMock` pattern | New file in Tests/Helpers/ | Medium |
| Add deterministic async testing | Add ConcurrencyExtras dependency | Medium |
| Consolidate error types | New PayBackError.swift | Medium |

### Low Priority (Technical Debt)

| Action | File(s) | Effort |
|--------|---------|--------|
| Add `Internal/` subdirectories | All feature modules | Low |
| Create `Deprecated.swift` | New file | Low |
| Add `AnyJSON` type for metadata | New file in Models/ | Medium |
| Add strict concurrency checking | project.yml | Low (but may surface issues) |

---

## 5. Open Questions

1. **Snapshot testing scope** — Should we add inline HTTP request snapshots for all API calls, or start with critical auth/expense flows only? 
   - *Recommendation: Start with auth flows*

2. **Internal/ directory refactoring** — Do you want to reorganize each feature module with `Internal/` subdirectories for implementation details, or keep the current flat structure? 
   - *Recommendation: Add gradually per feature*

3. **`AnyJSON` type for metadata** — supabase-swift uses `AnyJSON` for flexible user metadata; should PayBack add this for expense metadata extensibility? 
   - *Recommendation: Add if you need flexible custom fields*

---

## 6. Progress Tracking

| Step | Description | Status | Notes |
|------|-------------|--------|-------|
| 1 | Add Sendable conformance | ⬜ Not Started | |
| 2 | Create Dependencies container | ⬜ Not Started | |
| 3 | Relocate MockAccountService | ⬜ Not Started | |
| 4 | Create PayBackError | ⬜ Not Started | |
| 5a | Memory leak detection | ⬜ Not Started | |
| 5b | Deterministic async helper | ⬜ Not Started | |
| 5c | HTTPClientMock | ⬜ Not Started | |
| 6 | Snapshot testing + strict concurrency | ⬜ Not Started | |

---

## References

- [supabase-swift repository](https://github.com/supabase/supabase-swift)
- [swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing)
- [swift-concurrency-extras](https://github.com/pointfreeco/swift-concurrency-extras)
