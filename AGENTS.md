# AGENTS.md

This file guides agentic coding assistants working in this repo.

## Scope
- Applies to the entire repository.
- No Cursor or Copilot instruction files were found in this repo.

## Tooling Standards
- **Runtime**: Always use `bun` or `bunx` for JavaScript/TypeScript tasks (e.g. `bunx convex ...`).
- **Dependencies**: Do not use `npm` or `yarn` unless strictly necessary.

## CI Environment Constraints
- Xcode Cloud runs on x86 and does not support Convex testing.
- Do not add build steps that require running the Convex backend in CI.

## Primary CI Parity Rule
- Always use the local CI simulation script for full test runs: `./scripts/test-ci-locally.sh`.
- This script must remain in lockstep with GitHub Actions. If `.github/workflows/ci.yml` changes, update `scripts/test-ci-locally.sh` to replicate CI behavior exactly (steps, flags, simulator selection, coverage settings).

## Git Commits
- Match the repo’s current commit style: conventional-commit prefix like `fix:` or `fix(tests):`, followed by a short, lowercase summary.
- Commit messages must be a single line (no body).

## Build Commands
- Build app (CI-like destination selection handled in script):
  - `./scripts/test-ci-locally.sh` (builds as part of its flow)
- Manual build (Debug, simulator):
  - `xcodebuild -project PayBack.xcodeproj -scheme PayBack -configuration Debug -destination "platform=iOS Simulator,id=<UDID>" clean build`

## Lint Commands
- SwiftLint (non-failing in CI, but still preferred locally):
  - `swiftlint lint`
- Install SwiftLint if missing:
  - `brew install swiftlint`

## Tests
- When running tests, use the full local CI simulation: `./scripts/test-ci-locally.sh`.
- This script must stay in lockstep with the GitHub Actions test workflow. If CI changes, update `scripts/test-ci-locally.sh` so local runs replicate CI behavior exactly (same steps, simulator selection, and flags).

## Zero Warnings Policy
- Test runs must be warning-free (treat warnings as failures).
- Before pushing, run: `FAIL_ON_WARNINGS=1 ./scripts/test-ci-locally.sh`.
- If Xcode emits non-actionable tool warnings, update `./scripts/test-ci-locally.sh` warning filtering rather than ignoring warnings in code.

## Test Commands
- Full CI-equivalent test run (preferred):
  - `./scripts/test-ci-locally.sh`
- Unit tests (no sanitizer, matches CI "none" job):
  - `xcodebuild test -project PayBack.xcodeproj -scheme PayBackTests -configuration Debug -destination "platform=iOS Simulator,id=<UDID>" -parallel-testing-enabled NO -enableCodeCoverage YES -resultBundlePath TestResults.xcresult`
- Unit tests with Thread Sanitizer:
  - `xcodebuild test -project PayBack.xcodeproj -scheme PayBackTests -configuration Debug -destination "platform=iOS Simulator,id=<UDID>" -parallel-testing-enabled NO -enableThreadSanitizer YES -resultBundlePath TestResults.xcresult`
- Unit tests with Address Sanitizer:
  - `xcodebuild test -project PayBack.xcodeproj -scheme PayBackTests -configuration Debug -destination "platform=iOS Simulator,id=<UDID>" -parallel-testing-enabled NO -enableAddressSanitizer YES -resultBundlePath TestResults.xcresult`
- Resolve dependencies (CI step):
  - `xcodebuild -resolvePackageDependencies -project PayBack.xcodeproj -scheme PayBack`

## Running a Single Test
- Use `-only-testing` with `PayBackTests`:
  - `xcodebuild test -project PayBack.xcodeproj -scheme PayBackTests -configuration Debug -destination "platform=iOS Simulator,id=<UDID>" -only-testing:PayBackTests/StylesTests/testAvatarViewWithWhitespace`
- To run a full test class:
  - `xcodebuild test -project PayBack.xcodeproj -scheme PayBackTests -configuration Debug -destination "platform=iOS Simulator,id=<UDID>" -only-testing:PayBackTests/StylesTests`

## Simulator Selection
- CI dynamically chooses the newest iOS runtime with preferred iPhone models.
- For local parity, use the same logic by running `./scripts/test-ci-locally.sh`.
- If running manually, use `xcrun simctl list devices iPhone available` and pick a matching UDID.

## Coverage
- CI expects coverage when sanitizer is `none`.
- Coverage output is stored in `coverage.json` and `coverage-report.txt`.
- Coverage threshold in CI is `48.0%`.

## Code Style Guidelines (Swift)

### Imports
- Keep imports minimal and file-scoped.
- Prefer standard ordering:
  1. Apple frameworks (SwiftUI, UIKit, Foundation)
  2. Third-party frameworks
  3. Internal modules
- Avoid unused imports.

### Formatting
- Follow existing indentation (spaces, 4-space standard in Swift files here).
- Keep line length reasonable (match local style; wrap long argument lists onto new lines).
- Prefer trailing closures when it improves readability.
- Align chained modifiers vertically in SwiftUI.

### Types and Naming
- Types use `UpperCamelCase` (structs, enums, protocols, classes).
- Functions, variables, and properties use `lowerCamelCase`.
- Boolean names should read clearly (`isValid`, `hasAccount`, `shouldSync`).
- Avoid single-letter names except in very small scopes (e.g., map/forEach closures).

### SwiftUI
- Keep views small and composable.
- Prefer private computed subviews for complex layouts.
- Keep `body` readable; extract complex logic into helpers.
- Use `@State`, `@StateObject`, and `@EnvironmentObject` consistently with existing patterns.

### Error Handling
- Prefer typed errors (enums conforming to `Error`) over string-based errors.
- Use `Result` or `throws` consistently with the existing API style.
- Keep user-facing error messages sanitized (no PII).

### Concurrency
- Respect actor isolation in existing services.
- Use `async`/`await` rather than completion callbacks in new code.
- Avoid blocking the main thread with long-running tasks.

### Testing
- Add tests alongside feature changes when a logical location exists.
- Keep tests deterministic and avoid reliance on external state.
- Use existing test helpers and fixtures where possible.

#### Test Data Hygiene
- Never use real people names, team member names, or any personal emails/handles in tests or test fixtures.
- Prefer generic placeholders: `Example User`, `Example Person`, `Sample Member`, `example@example.com`.
- Avoid hard-coding names that can be confused with real users (e.g. do not use the repo owner's name).

### Colors and Styling
- Use `AppTheme` for colors; avoid hard-coded UIColor/Color values.
- Follow design-system components (`AvatarView`, `GroupIcon`, `EmptyStateView`) rather than reinventing.

### Data Models
- Keep Codable conformance and hashing consistent with existing implementations.
- Prefer explicit initializers when adding new fields to models.
- Avoid breaking `Equatable` or `Hashable` semantics.

## Repo-Specific Notes
- iOS app lives in `apps/ios/PayBack`.
- Design system components are in `apps/ios/PayBack/Sources/DesignSystem`.
- Tests are in `apps/ios/PayBack/Tests`.

## Convex Data Model (PayBack)

### Deployments

- Debug iOS builds use the **development** deployment URL in `apps/ios/PayBack/Sources/Services/Convex/ConvexConfig.swift`.
- Release iOS builds use the **production** deployment URL in `apps/ios/PayBack/Sources/Services/Convex/ConvexConfig.swift`.

### Key Tables + Relationships

- `accounts`: canonical user record; `id` is the Clerk subject used by `user_expenses.user_id`.
- `groups`: `id` is a client UUID (string). `members[].id` is a member UUID string. `is_direct=true` indicates a 1:1 group.
- `account_friends`: keyed by (`account_email`, `member_id`); controls direct-expense validation.
- `expenses`: `id` is a client UUID (string). `group_id` matches `groups.id`. `participant_emails` drives visibility.
- `user_expenses`: denormalized fanout for `expenses:list`; `user_id == accounts.id` and `expense_id == expenses.id`.
- `member_aliases`: alias member IDs to canonical member IDs to preserve history across linking.

### Fast Convex Snapshot (1 command)

Use this when debugging "missing expenses" issues.

```bash
python - <<'PY'
import json, subprocess

DEPLOYMENT = "flippant-bobcat-304"  # Debug. Production is "tacit-marmot-746".

def get(table, limit=1000):
    out = subprocess.check_output(
        ["npx", "convex", "data", table, "--deployment-name", DEPLOYMENT, "--limit", str(limit), "--format", "json"],
        text=True,
    ).strip()
    if out.startswith("There are no documents"):
        return []
    return json.loads(out)

tables = ["accounts", "groups", "account_friends", "expenses", "user_expenses"]
data = {t: get(t) for t in tables}
print("counts=", {t: len(v) for t, v in data.items()})

groups_by_id = {g.get("id"): g for g in data["groups"] if isinstance(g, dict) and g.get("id")}
direct_group_ids = {gid for gid, g in groups_by_id.items() if g.get("is_direct")}

expense_counts_by_group = {}
for e in data["expenses"]:
    gid = e.get("group_id")
    if gid:
        expense_counts_by_group[gid] = expense_counts_by_group.get(gid, 0) + 1

direct_expenses = sum(expense_counts_by_group.get(gid, 0) for gid in direct_group_ids)
print("direct_groups=", len(direct_group_ids), "direct_expenses=", direct_expenses)
PY
```

### Direct Expense Rule (Important)

`convex/expenses.ts` rejects creating a direct expense unless every non-current-user involved member has a matching `account_friends` row with `status == "friend"`.

This is the most common reason direct expenses don't appear after CSV import.

## Lint/Test Parity Reminder
- If you change CI steps in `.github/workflows/ci.yml`, update `./scripts/test-ci-locally.sh` to match.
- If you add a new testing/linting command, document it here.

## Data Consistency & Imports

### Data Integrity Principles
- **Source of Truth**: `member_id` is the immutable identifier for an account (assigned at creation).
- **Identity Resolution**: Always use `resolveCanonicalMemberIdInternal` helper to resolve any ID (alias or canonical) to the canonical ID.
- **Legacy Support**: `linked_member_id` persists links, but `member_aliases` table handles the actual ID redirection.

### Import robustness
- **Drift Prevention**: Imports must assume the local data (CSV) might be stale or contain old IDs.
- **Canonical Alias Resolution**: The `bulkImport` mutation implements ID Remapping:
  1. Checks if an imported ID is a known alias.
  2. If yes, remaps all references (Friends, Groups, Expenses) to the Canonical ID.
  3. Checks if a friend already exists for the Canonical ID and merges instead of creating a duplicate.
- **Self-Healing**: This logic automatically upgrades legacy IDs to canonical ones during import, preventing "Ghost Members" or duplicate friends.

### Common Data Issues & Fixes

| Symptom | Cause | Solution |
|---------|-------|----------|
| **"Paid by Unknown"** | Expense uses Legacy ID (Alias) but Account uses Canonical ID | Run migration (e.g. `fixIdsByName`) to create alias record. |
| **Duplicate Friends** | Import created new friend because ID didn't match existing | Use `bulkImport`'s built-in deduplication (matches by ID *or* Name). |
| **Ghost Member** | Group member has different ID than Friend List record | Ensure `bulkImport` remaps *all* tables (Groups, Expenses) to the same Canonical ID. |
| **Missing History** | User linked but expenses not visible | Trigger `reconcileExpensesForMember` when linking to backfill `user_expenses`. |

### Ghost Data Handling
- **Scenario**: User hard deletes account, then re-imports data from a backup.
- **Risk**: Import creates "Manual Friend" with old ID. User recreates account (new ID). Result: Ghost (unlinked) friend.
- **Fix**: `bulkImport` detects this via aliases/name matching and merges the old data into the new account identity if possible, or keeps it consistent as a manual friend.

## User Lifecycle & Cleanup Logic

### The "Ghost User" State
When a user deletes their account via the app (`selfDeleteAccount`), it is a **Soft Delete**:
- The `accounts` row is deleted.
- The `account_friends` list is deleted.
- **BUT** `groups` and `expenses` owned by them are **PRESERVED**.
- This leaves a "Ghost User" visible to friends (so they can still see expense history).

### The "Clean Slate" Guarantee
When a user registers (or re-registers) with an email (`store` mutation):
1. System checks if an `accounts` row exists.
2. If **NO** account exists (New or Re-registering user):
   - **Self-Heal Triggered**: `cleanupOrphanedDataForEmail` runs.
   - **Wipe**: Deletes ALL old `groups`, `expenses`, `link_requests`, and `invite_tokens` owned by that email.
   - **Unlink**: Removes the email from other users' friend lists (converting them from "Linked" to "Manual" friends).
3. **Result**: A fresh account NEVER inherits old/ghost data. It always starts with a blank slate.

### Hard Delete
- **Function**: `performHardDelete` (internal/admin).
- **Scope**: Wipes EVERYTHING immediately (Account, Friends, Groups, Expenses, Invites, Aliases).
- **Use Case**: Admin tools or total data removal requests.

### Account Deletion & Auto-Login Behavior
- **Constraint**: Accounts should NOT be auto-created during session restoration (app restart).
- **Explicit Login**: Explicit Sign In (entering credentials) SHOULD create the account if it's missing (e.g. recreating after wipe), as it indicates user intent.
- **Problem**: Previously, `checkSession` (auto-login) would auto-create data if Clerk session persisted but Convex account was gone.
- **Fix**: Updated `AppStore.checkSession` to throw `accountNotFound` and trigger `signOut` instead of creating. `login` and `signup` allow creation.

## Testing Strategy & Standards

### Philosophy
- **TDD (Test Driven Development)**: Write the test *before* the fix.
- **Regression Testing**: Every bug fix MUST include a permanent regression test to prevent recurrence.
- **Integration over Unit**: Use `convex-test` to test the full mutation logic against a real-like database schema.

### How We Test
1.  **Convex Tests**: Located in `convex/tests/`. Use `convex-test` and `vitest`.
2.  **Schema Compliance**: Tests must use `schema` definition to ensure data validity.
3.  **Data Integrity**: Tests should verify relationships (e.g., "Does the group member ID match the friend ID?").

### Critical Test Patterns
- **Import Robustness**: Verify that imports handle alias IDs, ID mismatches, and name matching correctly. (See `convex/tests/import_robustness.test.ts`).
- **Lifecycle**: Verify account creation, deletion, and linking flows.

## Balance Calculation Logic
- **Rule**: Fully settled expenses (`is_settled: true`) must be EXCLUDED from net balance calculations.
- **Partial Settlements**: For partially settled expenses, credit must be reduced by the sum of *settled splits*.
- **Implementation**: See `GroupDetailView.swift` logic.