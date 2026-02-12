# Android Scaffold

This workspace is intentionally a scaffold shell for future Android implementation.

## Current state

- Existing brand icon assets remain under `apps/android/PayBack/app/src/main/res`.
- No Gradle/Kotlin app is introduced in this phase.
- Turbo scripts are placeholders so Android can be integrated without reshaping the monorepo.

## Future intent

A full Android app (likely Jetpack Compose) can be added under `apps/android/PayBack` with:

- independent Gradle build pipeline
- optional shared API/domain contracts from `packages/*`
- coordinated CI job alongside iOS, backend, and web checks
