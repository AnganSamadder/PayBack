# AGENTS.md

This file guides agentic coding assistants working in this repo.

## Scope
- Applies to the entire repository.
- No Cursor or Copilot instruction files were found in this repo.

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

## Lint/Test Parity Reminder
- If you change CI steps in `.github/workflows/ci.yml`, update `./scripts/test-ci-locally.sh` to match.
- If you add a new testing/linting command, document it here.
