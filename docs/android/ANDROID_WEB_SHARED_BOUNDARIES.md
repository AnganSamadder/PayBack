# Android and Web Shared Boundaries

## Goal

Define how future Android and current web/backend code share contracts without tightly coupling UI stacks.

## Shared layers

1. Design tokens (`packages/design-tokens`) for color/semantic constants.
2. Backend API contracts owned by Convex functions in `apps/backend/convex`.
3. Future optional domain utilities can be placed in `packages/*` and consumed by web/Android independently.

## Non-shared layers

1. Platform UI implementation (SwiftUI, Jetpack Compose, React) stays platform-native.
2. Navigation systems stay platform-native.
3. Persistence implementation details stay platform-native.

## Future Android integration checklist

1. Add Gradle wrapper and root `settings.gradle.kts` under `apps/android`.
2. Add Android CI lane (build + unit tests + lint).
3. Add interface compatibility tests against backend contracts.
4. Add release pipeline independent from web deployment.
