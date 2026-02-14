# Vercel Setup for PayBack Monorepo

## Project configuration

1. Import repository into Vercel.
2. Set **Root Directory** to `apps/web` for web project.
3. Keep framework preset as **Vite**.
4. Set environment variable:
   - `VITE_TESTFLIGHT_URL` = your public TestFlight invite link.

## Build behavior

- Build command: `bun run build`
- Install command: `bun install`
- Output directory: `dist`

## Preview deployments

- Enable preview deployments for pull requests/branches.
- Use previews to compare landing variants and share links.

## Routing

`apps/web/vercel.json` contains SPA rewrites so direct route loads like `/v7` resolve correctly.

## Analytics

Vercel Analytics is integrated in `apps/web/src/main.tsx` and events are emitted for:

- variant page views
- variant switch clicks
- TestFlight CTA clicks
