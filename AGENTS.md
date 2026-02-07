# PROJECT KNOWLEDGE BASE

**This is a LIVING DOCUMENT. Agents: Update this file after solving hard or recurring issues. Do not treat as a changelog.**

**Generated:** 2026-02-07 02:59:11
**Commit:** 8a34b1
**Branch:** main

## OVERVIEW
PayBack is an expense sharing app featuring a native Swift iOS client (MVVM + Central Store) and a Convex backend (TypeScript).

## STRUCTURE
```
.
├── apps/ios/PayBack/  # Native iOS application
├── convex/            # Backend (Schema, Functions, Auth)
├── packages/          # Shared packages
└── scripts/           # CI/CD utilities
```

## WHERE TO LOOK
| Task | Location | Notes |
|------|----------|-------|
| iOS UI/Views | `apps/ios/PayBack/Sources/Features` | Organized by domain |
| iOS State | `apps/ios/PayBack/Sources/Services/State` | `AppStore.swift` is the God Object |
| Backend Schema | `convex/schema.ts` | Source of truth for data model |
| Backend Logic | `convex/` | Mutations, queries, actions |
| Tests | `apps/ios/PayBack/Tests` & `convex/tests` | Integration focused |

## COMMANDS
```bash
# Full CI Simulation (Build + Test)
./scripts/test-ci-locally.sh

# Convex Development
bunx convex dev

# iOS Build
xcodebuild -scheme PayBack -destination "platform=iOS Simulator,name=iPhone 15"
```

## CONVENTIONS
- **Commits**: Conventional Commits (`feat:`, `fix:`). Single line.
- **Linting**: Zero warnings policy (`FAIL_ON_WARNINGS=1`).
- **Runtime**: `bun` / `bunx` preferred over `npm`.

## NOTES
- **CI Parity**: `test-ci-locally.sh` mirrors GitHub Actions.
- **Architecture**: iOS uses a Central Store; avoid local `@State` for shared data.
- **Backend**: `accounts` table is the user source of truth; handle ghost data via `bulkImport`.
