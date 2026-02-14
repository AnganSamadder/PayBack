# iOS Project Relocation Plan (Plan-Only)

## Scope

This document defines a future relocation of Xcode project artifacts under `apps/ios` without executing it in this phase.

## Current state

- `project.yml` is at repository root.
- `PayBack.xcodeproj` is generated at repository root.
- Source and tests already live in `apps/ios/PayBack`.

## Target state

- Move `project.yml` to `apps/ios/project.yml`.
- Generate `apps/ios/PayBack.xcodeproj` as canonical location.
- Keep paths to `apps/ios/PayBack/Sources` and `apps/ios/PayBack/Tests` stable.

## Impact matrix

1. CI workflow paths:
   - update all `xcodebuild -project` arguments.
   - update dependency cache key globs for project path.
2. local scripts:
   - update `scripts/test-ci-locally.sh` path assumptions.
3. xcode cloud scripts:
   - validate working directory and generated project path.
4. docs and runbooks:
   - update command snippets and troubleshooting notes.

## Rollback strategy

1. Keep root-level generation script fallback during migration.
2. If CI fails, regenerate project at root and restore previous path references.
3. Release migration only after one full green run in GitHub Actions and Xcode Cloud.
