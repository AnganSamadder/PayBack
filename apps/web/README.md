# PayBack Web Landing

Landing page implementation for PayBack using:
- React + TanStack Router
- Vite
- Tailwind CSS v4
- Vercel Analytics

## Routes

- `/` => Variant 1 (default)
- `/v1` => Liquid Glass Ledger
- `/v2` => Swiss Precision Finance
- `/v3` => Story-Driven Expense Journey
- `/v4` => Trust & Authority Cards
- `/v5` => Minimal Teal Editorial
- `/v6` => Memphis Pop Playground
- `/v7` => Neo-Brutalist Receipt Board
- `/v8` => Retro-Futurist Neon Terminal
- `/v9` => E-Ink Paper Calm
- `/v10` => Kinetic Typography Motion

## Local development

```bash
bun install
bun run dev
```

## Required env

Copy `.env.example` to `.env.local` in `apps/web` and set:

- `VITE_TESTFLIGHT_URL`

## Test commands

```bash
bun run lint
bun run typecheck
bun run test
bun run test:e2e
bun run build
```
