# PayBack

PayBack helps friends, trips, and groups split expenses with clarity.

## Monorepo Structure

- `apps/ios/PayBack`: iOS app (SwiftUI + XcodeGen)
- `apps/backend/convex`: Convex backend functions
- `apps/web`: landing page (TanStack Router + Vite + Tailwind v4)
- `apps/android`: Android scaffold shell
- `packages/*`: shared config and design token packages

## Getting Started

1. Install prerequisites:
   ```bash
   brew install bun xcodegen
   ```
2. Install workspace dependencies:
   ```bash
   bun install
   ```
3. Generate the Xcode project:
   ```bash
   xcodegen generate
   ```

## Common Commands

```bash
# Run all workspace checks
bun run ci

# iOS CI parity test run
./scripts/test-ci-locally.sh

# Backend dev server
bun run --filter @payback/backend dev

# Web landing dev server
bun run --filter @payback/web dev
```

## Convex Backend

Convex functions live in `apps/backend/convex` and are wired from root `convex.json`.

```bash
bunx convex dev
bunx convex deploy
```

The app automatically selects the correct Convex deployment using build config + scheme:

- **Debug config**: development Convex deployment (local runs)
- **Internal config**: development Convex deployment (internal testing archives)
- **Release config**: production Convex deployment (external TestFlight + App Store)

Scheme mapping:

- `PayBackInternal` archives with `Internal`
- `PayBack` archives with `Release`

No runtime env vars are required for iOS app routing; `PAYBACK_CONVEX_ENV` is baked into `Info.plist` at build time.

## Authentication

Authentication is handled by [Clerk](https://clerk.dev). The Clerk publishable key is configured in `AppConfig.swift`.

## License

MIT License - see `LICENSE`.
