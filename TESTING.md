# Testing & CI Strategy

## CI Architecture: Split-OS, 2-Tier Pipeline

All CI runs through `.github/workflows/ci.yml` with a **cost-optimized split-OS design**.

### Job Graph

```
                    quality-gate (ubuntu, ~1min)
                    ┌──────────┴──────────┐
           Linux (cheap)              macOS (10x cost)
     ┌──────┼──────┐──────┐        ┌──────┼──────┐
  backend  web   web    web     ios-build  ios-tests
  tests   tests  build  e2e              (3x sanitizer matrix)
```

### Jobs Summary

| Job             | Runner        | Timeout | Purpose                                                       |
| --------------- | ------------- | ------- | ------------------------------------------------------------- |
| `quality-gate`  | ubuntu-latest | 10 min  | Lint + format + typecheck. **All other jobs depend on this.** |
| `backend-tests` | ubuntu-latest | 10 min  | Vitest for `@payback/backend`                                 |
| `web-tests`     | ubuntu-latest | 10 min  | Vitest for `@payback/web`                                     |
| `web-build`     | ubuntu-latest | 15 min  | Vite production build                                         |
| `web-e2e`       | ubuntu-latest | 15 min  | Playwright smoke tests (needs web-build)                      |
| `ios-build`     | macos-14      | 45 min  | Xcode build + SwiftLint                                       |
| `ios-tests`     | macos-14      | 45 min  | Unit tests with sanitizer matrix (none, thread, address)      |

### Cost Rationale

- **macOS runners cost ~10x** more than Linux per minute
- The `quality-gate` job catches lint/type/format errors on cheap Ubuntu (~1 min)
- If quality-gate fails, **zero macOS minutes are consumed**
- iOS jobs use `macos-14` (cheaper than `macos-15`)

### Skipping iOS Jobs

Add `[skip-ios]` to your PR title to skip all macOS jobs. Useful for web-only or backend-only PRs.

## Local Commands

### Development

```bash
bun run dev            # Start web + convex backend together
bun run dev:web        # Start only the web app (Vite)
bun run dev:backend    # Start only the Convex backend
bun run dev:ios        # Prints hint to open Xcode
```

### Quality Checks

```bash
bun run lint           # ESLint across all workspaces
bun run lint:fix       # ESLint with --fix
bun run format         # Prettier --write on all files
bun run format:check   # Prettier --check (CI mode)
bun run typecheck      # TypeScript check across workspaces
```

### Testing

```bash
bun run test           # Vitest across all workspaces
bun run test:web       # Vitest for web only
bun run test:backend   # Vitest for backend only
bun run test:e2e       # Playwright E2E tests
```

### Building

```bash
bun run build          # Build all workspaces
bun run build:web      # Build web only
```

### Full Local CI

```bash
bun run ci             # Runs: lint + typecheck, then format:check, then test + build
```

This mirrors the CI pipeline locally. Catches the same errors before pushing.

### Deployment

```bash
bun run deploy:web       # Vercel production deploy
bun run deploy:backend   # Convex deploy
```

### Cleanup

```bash
bun run clean            # Remove all build artifacts, node_modules, and turbo cache
bun install              # Reinstall after clean
```

## Caching Strategy

### Turbo (Local)

Turborepo caches task outputs locally in `.turbo/`. Each task declares `inputs` arrays so cache invalidation is precise (e.g., `build` only re-runs when `src/**`, config files, or `package.json` change).

To clear the local turbo cache:

```bash
rm -rf .turbo
# or
bun run clean
```

### CI: Bun Dependencies

All Linux CI jobs cache `~/.bun/install/cache` keyed on `bun.lock`. This makes `bun install --frozen-lockfile` near-instant on cache hits.

### CI: SPM (Swift Package Manager)

macOS jobs cache `~/Library/Caches/org.swift.swiftpm` and `~/Library/Developer/Xcode/DerivedData`, keyed on `Package.resolved` and `project.pbxproj`.

### CI: Concurrency

The workflow uses a concurrency group (`ci-${{ github.ref }}`). Pushing a new commit to the same PR branch **cancels any in-progress CI run** for that branch, saving runner minutes.
