# PayBack Monorepo Foundation + 10-Variant Landing (Bun + Turbo + TanStack + Vite + Tailwind v4)

## Summary

Implement from `/Users/angansamadder/Code/PayBack` on branch `feat/landing-page` (already aligned to main commit `56115e7`), and keep this branch as the working branch.

Convert repo to Bun-first Turbo monorepo, move Convex backend into `apps/backend`, keep iOS running with existing XCTest/XcodeCloud flows, add Android scaffold shell, and ship `apps/web` landing with 10 seamless route-based variants.

Use a design-first system where variants are intentionally hand-crafted and unique; first 5 keep PayBack iOS color mood, last 5 are high-creativity with broader visual freedom.

Add Vercel deployment config (monorepo app-dir mode), basic Vercel Analytics, and CI that unifies JS/web/backend checks while preserving iOS jobs.

## Agent Instructions: Skills & Tools

**FOR IMPLEMENTING AGENTS:**

Use ANY skills that could be useful for this work. Suggested skills based on scope:

### Core Built-in Skills

- **Discovery & Planning:** `find-skills`, `brainstorming`, `writing-plans`, `avoid-feature-creep`
- **Frontend/Design Work:** `frontend-design`, `ui-ux-pro-max`, `frontend-ui-ux`, `web-design-guidelines`
- **Convex Backend:** `convex`, `convex-functions`, `convex-best-practices`, `convex-testing`, `convex-schema-validator`
- **iOS/XcodeGen:** `xcodegen`, `test-driven-development`, `systematic-debugging`
- **Git Operations:** `git-master`, `git-commit`, `commit-work`
- **Quality & Review:** `verification-before-completion`, `requesting-code-review`, `receiving-code-review`
- **Execution:** `executing-plans`, `subagent-driven-development`, `dispatching-parallel-agents`

### External Skills (Optional - Install via `npx skills add <owner/repo@skill>`)

**Monorepo & Turborepo:**

- `ovachiever/droid-tings@monorepo-management`
- `mindrally/skills@turborepo`
- `secondsky/claude-skills@turborepo`
- `timelessco/recollect@turborepo`

**Vite & Tailwind v4:**

- `jezweb/claude-skills@tailwind-v4-shadcn`
- `existential-birds/beagle@tailwind-v4`
- `igorwarzocha/opencode-workflows@vite-shadcn-tailwind4`

**TanStack Router:**

- `jezweb/claude-skills@tanstack-router`
- `deckardger/tanstack-agent-skills@tanstack-router-best-practices`
- `secondsky/claude-skills@tanstack-router`

**Accessibility (WCAG AA compliance):**

- `mindrally/skills@accessibility-a11y`
- `webflow/webflow-skills@accessibility-audit`
- `supercent-io/skills-template@web-accessibility`

**Vercel Deployment:**

- `sickn33/antigravity-awesome-skills@vercel-deployment`
- `bobmatnyc/claude-mpm-skills@vercel-deployments-builds`

**CI/CD & GitHub Actions:**

- `bobmatnyc/claude-mpm-skills@github-actions`
- `wshobson/agents@monorepo-management`

**E2E Testing (Playwright):**

- `bobmatnyc/claude-mpm-skills@playwright-e2e-testing`
- `alinaqi/claude-bootstrap@playwright-testing`

**Bun Package Manager:**

- `lammesen/skills@bun-expert`
- `secondsky/claude-skills@bun-package-manager`

**IMPORTANT:** This is NOT an exhaustive list. Read ALL available skill descriptions and load ANY skill whose domain overlaps with your task. When in doubt, load the skill—subagents are stateless and only know what you tell them.

## Implementation Plan

### 1) Workspace Preparation

- Remove local artifact directories per your instruction: `.sisyphus/`, `LocalPackages/`, `Packages/`, `roadmap/` from local workspace only; keep ignore behavior intact.
- Normalize repo root for Bun workspaces by introducing Bun lockfile and removing npm lockfile from canonical workflow.
- Keep existing iOS source tree intact; do not perform full iOS project relocation in this phase.

### 2) Monorepo Core (Turbo + Bun)

- Add `turbo.json` with tasks for `dev`, `build`, `typecheck`, `lint`, `test`, `test:e2e`, and `ci`.
- Update `package.json` to Bun workspace root with workspaces for `apps/*` and `packages/*`.
- Add shared config packages in `/Users/angansamadder/Code/PayBack/packages`:
  - `/Users/angansamadder/Code/PayBack/packages/config-eslint`
  - `/Users/angansamadder/Code/PayBack/packages/config-prettier`
  - `/Users/angansamadder/Code/PayBack/packages/config-typescript`
  - `/Users/angansamadder/Code/PayBack/packages/design-tokens` (web tokens + iOS-inspired brand constants for v1-v5).

### 3) Backend Move to apps/backend

- Move `/Users/angansamadder/Code/PayBack/convex` to `/Users/angansamadder/Code/PayBack/apps/backend/convex`.
- Add `package.json` with Bun scripts for Convex dev/deploy/codegen/test.
- Add root `convex.json` and point `"functions"` to `apps/backend/convex` (inference from Convex docs: supported relocation pattern).
- Update all references in `project.yml`, `README.md`, scripts, and CI to new backend path.
- Add backend test baseline in `/Users/angansamadder/Code/PayBack/apps/backend/tests` and wire into Turbo `test`.

### 4) Web Landing App (apps/web)

- Create `/Users/angansamadder/Code/PayBack/apps/web` using React + TanStack Router + Vite + Tailwind v4.
- Tailwind v4 setup uses Vite plugin and CSS-first theme tokens; no legacy Tailwind config dependency required unless needed for advanced plugin behavior.

**Route structure:**

- `/` serves Variant 1.
- `/v1` ... `/v10` are explicit route URLs.
- Fixed bottom-right numeric switcher (1..10) navigates routes with near-instant crossfade.

**Variant switching behavior:**

- Route change updates URL immediately.
- Preload variant route chunks on idle to avoid visible loading.
- Persist last selected variant in localStorage; root still renders Variant 1 for canonical entry.

**Content structure common to each variant:**

- Header CTA, hero CTA, footer CTA with text "Try PayBack on iPhone".
- Product story sections: hero, key features, trust/social signal block, final CTA, minimal footer links.
- Use stylized mock UI cards (not real screenshots in this phase).

**CTA config:**

- `VITE_TESTFLIGHT_URL` required env variable.
- If missing, show controlled fallback state and warning in console.

### 5) 10 Variant Design Spec (Hand-Crafted)

Variants v1-v5 keep PayBack vibe using iOS-inspired brand tokens (`#0FB8C7`, `#00CCE6`, black/white surface contrasts), but each must have distinct composition, typography, motion, and section rhythm.

Variants v6-v10 are high-liberty creative explorations.

**Variant directions:**

| Route  | Direction                    | Theme Group   |
| ------ | ---------------------------- | ------------- |
| `/v1`  | Liquid Glass Ledger          | App-vibe      |
| `/v2`  | Swiss Precision Finance      | App-vibe      |
| `/v3`  | Story-Driven Expense Journey | App-vibe      |
| `/v4`  | Trust & Authority Cards      | App-vibe      |
| `/v5`  | Minimal Teal Editorial       | App-vibe      |
| `/v6`  | Memphis Pop Playground       | Free-creative |
| `/v7`  | Neo-Brutalist Receipt Board  | Free-creative |
| `/v8`  | Retro-Futurist Neon Terminal | Free-creative |
| `/v9`  | E-Ink Paper Calm             | Free-creative |
| `/v10` | Kinetic Typography Motion    | Free-creative |

**Uniqueness guardrails:**

- No shared layout skeleton across more than one variant.
- No repeated font pairing across variants.
- Distinct background system per variant (mesh, texture, geometry, paper, etc.).
- Motion variety allowed, but all variants honor `prefers-reduced-motion`.
- WCAG AA-critical accessibility constraints must pass for every variant.

### 6) Analytics + Deployment

- Add Vercel Analytics to `/Users/angansamadder/Code/PayBack/apps/web`.
- Track basic events: page view by route, variant switch click, TestFlight CTA click.
- Add Vercel config for monorepo app-dir deployment and SPA fallback for route refreshes.
- Enable preview deployments for PR/branch changes; production root serves Variant 1.

### 7) Android Future-Proof Scaffold

- Keep `/Users/angansamadder/Code/PayBack/apps/android` as scaffold shell with package metadata and docs only.
- Add Android architecture/readiness doc defining future native app boundaries and shared package contracts.

### 8) CI and Local Parity

- Preserve existing iOS GitHub Actions jobs and XcodeCloud scripts.
- Add JS/web/backend CI jobs (Bun + Turbo) for lint/typecheck/test/build.
- Update `test-ci-locally.sh` so local CI parity includes newly added JS checks in addition to iOS.
- Keep iOS architecture compatibility behavior intact (arm64-first, CI target scheme handling, existing x86 constraints).
- Keep iOS full relocation as plan-only by adding migration doc, not by moving project files now.

## Public APIs / Interfaces / Types Changes

**New env interface:**

- `VITE_TESTFLIGHT_URL` in `.env.example`.

**New route contract:**

- `/`, `/v1`.../`/v10` as public landing URLs.

**New workspace scripts:**

- Root `dev`, `build`, `lint`, `typecheck`, `test`, `test:e2e`, `ci` via Turbo.

**Backend path contract:**

- Convex functions path relocated to `/Users/angansamadder/Code/PayBack/apps/backend/convex` with root `convex.json` indirection.

**New shared token interface:**

- `/Users/angansamadder/Code/PayBack/packages/design-tokens` exports web token constants (including PayBack theme tokens used by variants 1-5).

## Test Cases and Scenarios

**Monorepo integrity:**

- `bun install`, `bun turbo run lint typecheck test build` succeeds.

**Backend relocation:**

- Convex dev/codegen/deploy commands resolve with new functions path.
- iOS prebuild script references updated Convex paths correctly.

**Route UX:**

- All routes `/v1`.../`/v10` render and switch from dock without full-page reload.
- URL updates correctly on every switch.
- LocalStorage persistence restores last variant in switcher state.

**CTA correctness:**

- All variant CTAs resolve to `VITE_TESTFLIGHT_URL`.

**Accessibility:**

- Keyboard access for dock buttons.
- Focus-visible states and landmarks.
- Contrast checks for all variants (AA-critical).

**E2E smoke:**

- Playwright visits all 10 routes, validates CTA visibility and switcher behavior.

**Analytics:**

- Vercel Analytics pageview and click events emitted on route/CTA interactions.

**Regression safety:**

- Existing iOS local CI script and GitHub Actions jobs continue passing.

## iOS Relocation (Plan-Only Deliverable)

Add `PROJECT_RELOCATION_PLAN.md` with exact future steps to move `PayBack.xcodeproj` and related path anchors under `apps/ios`.

Include impact matrix for CI paths, XcodeGen root expectations, and migration rollback strategy.

## Assumptions and Defaults Locked

- **Branch:** `feat/landing-page` is the implementation branch and is already based on main.
- **Package manager:** Bun-only workflow is canonical.
- **Web stack:** TanStack Router + Vite + Tailwind v4 + ESLint + Prettier.
- **Landing:** English-only, stylized mock cards, CTA in header/hero/footer, minimal footer links, basic analytics.
- **Deployment:** Vercel monorepo app-dir config with preview deploys enabled.
- **Android:** scaffold docs + package shell only.
- **iOS full project relocation:** explicitly deferred; only documented this phase.

## References (Official Docs Used)

- [Bun workspaces](https://bun.sh/docs/install/workspaces)
- [Turborepo configuration](https://turbo.build/repo/docs/core-concepts/monorepos/configuring-workspaces)
- [TanStack Router docs](https://tanstack.com/router/latest)
- [Tailwind CSS v4 with Vite](https://tailwindcss.com/docs/installation/vite)
- [Tailwind CSS v4 theme variables](https://tailwindcss.com/docs/theme)
- [Convex monorepo/functions path via convex.json](https://docs.convex.dev/production/hosting/convex-json)
- [Vercel project configuration](https://vercel.com/docs/projects/project-configuration)
