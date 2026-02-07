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

### Canonical Identity & Aliasing (2026-02-04)

### New Model
- **Source of Truth**: `member_id` is the immutable identifier for an account (assigned at creation).
- **Legacy Removal**: `linked_member_id` and `equivalent_member_ids` have been removed from the schema and codebase.
- **Linking**: Account linking creates records in `member_aliases` table mapping `alias_member_id` -> `canonical_member_id`.
- **Resolution**: Use `resolveCanonicalMemberIdInternal` helper to resolve any ID (alias or canonical) to the canonical ID.

### Import & Linking Logic (2026-02-07)
- **Validation**: `bulkImport` must explicitly validate `linked_account_email` against the `accounts` table.
- **Ghost Links**: If the linked account does not exist (deleted), the link MUST be stripped, reverting the friend to "Manual" status.
- **Updates**: Existing "Manual" friends must be upgraded to "Linked" if a valid link is provided during import.
- **Reconciliation**: Linking a user triggers `reconcileExpensesForMember` to backfill `user_expenses` visibility for past expenses.
- **Schema**: `account_friends` includes `linked_member_id` to persist the canonical link.

### Migration Learnings
- **Data Integrity**: When migrating, ensure `member_aliases` are populated (e.g. from `invite_tokens`) *before* removing legacy fields, to preserve link history.
- **iOS Compatibility**: The backend returns `canonical_member_id`. iOS DTOs (`ConvexLinkAcceptResultDTO`) map this to the `linked_member_id` property to maintain app compatibility without full refactor.
- **Import Logic**: `bulkImport` uses `resolveCanonicalMemberIdInternal` to ensure legacy IDs in import files are correctly mapped to current canonical IDs.

### Direct Groups & Balance Calculation
- **is_direct Flag**: Direct groups (1:1 friendships) MUST have `is_direct: true`. If this flag is missing, iOS treats it as a group.
- **Import ID Resolution**: When importing, IDs may differ from current canonical IDs. Always ensure aliases exist or merge IDs by name if "Paid by Unknown" occurs.
- **Fix**: Run `fixIdsByName` (merge by name) if import creates mismatched IDs.

### Import ID Consistency (2026-02-07)
- **Problem**: CSV imports may contain inconsistent IDs (e.g., Friend List uses ID A, Group Member uses ID B) or drift from the database.
- **Solution**: `bulkImport` implements **ID Remapping**.
  - It builds a map of `Import ID -> Database ID`.
  - If a friend matches by ID or Name, the existing Database ID is used.
  - All references in Groups and Expenses are remapped to this consistent ID.
  - This ensures `isFriend` checks in iOS pass and prevents "Ghost Members" (Group members who aren't recognized as friends).

### "Paid by Unknown" Symptom
- **Symptom**: Expenses appear in activity but show "Paid by Unknown" and are excluded from friend balance (0 balance).
- **Cause**: The expense record uses a Legacy ID (Alias) for the payer, but the user's Account uses a Canonical ID, and no link exists between them.
- **Resolution**: Run a migration (like `fixIdsByName`) to detect expenses where the Payer Name matches the Account Name but IDs differ, then create an alias record and canonicalize the expense ID.

### Account Deletion & Auto-Login Behavior (2026-02-06)
- **Constraint**: Accounts should NOT be auto-created during session restoration (app restart).
- **Explicit Login**: Explicit Sign In (entering credentials) SHOULD create the account if it's missing (e.g. recreating after wipe), as it indicates user intent.
- **Problem**: Previously, `checkSession` (auto-login) would auto-create data if Clerk session persisted but Convex account was gone.
- **Fix**: Updated `AppStore.checkSession` to throw `accountNotFound` and trigger `signOut` instead of creating. `login` and `signup` allow creation.