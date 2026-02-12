# PayBack Scripts

Helper scripts for local development and CI parity.

## Scripts

- `setup-git-hooks.sh`: installs git hooks for local workflows
- `test-ci-locally.sh`: full local CI parity (JS/TS + iOS)
- `test-with-coverage.sh`: iOS coverage helper output

## Running Tests Locally

```bash
# Install JS dependencies
bun install

# Run monorepo checks (web/backend/config)
bun run ci

# Run local CI parity script (includes JS + iOS)
./scripts/test-ci-locally.sh

# Skip web e2e smoke tests when needed
RUN_WEB_E2E=0 ./scripts/test-ci-locally.sh

# Run XcodeCloud-like flow
CI_FLAVOR=xcodecloud ./scripts/test-ci-locally.sh
```

## Convex Backend

Backend functions are in `apps/backend/convex` and routed via root `convex.json`.

```bash
bun run --filter @payback/backend dev
bun run --filter @payback/backend deploy
```

For CI/XcodeCloud deployment, set:

- `CONVEX_DEPLOY_KEY`: Convex deploy key (secret)
- `CONVEX_DEPLOY_ON_CI=1`: Safety switch to enable deploy from CI

For iOS app runtime database selection in Xcode Cloud:

- Internal testing workflow should build/archive scheme `PayBackInternal` (development Convex DB).
- External TestFlight / App Store workflow should build/archive scheme `PayBack` (production Convex DB).
