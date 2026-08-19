# Production Debug Data Containment Design

## Problem

The TestFlight screenshots contain the exact generated dataset embedded in `ActivityView`: the `Roommates`, `Work Team`, and `Weekend Trip` groups and the `Team Lunch` ($65.25) and `Groceries` ($85.50) expenses. Generated groups and expenses are intentionally marked with `is_payback_generated_mock_data`, but the production client currently loads them into the same store as real data. When the generated records carry an older member UUID, the expense rows remain visibly unsettled while balance calculations correctly find no current-user split and return zero.

## Chosen approach

Contain generated data at four boundaries. `AppStore` receives its Convex environment as an injectable dependency. In production it removes generated records from persisted local state before exposing it, rejects generated groups and expenses during both initial fetch and realtime updates, refuses debug seed writes, and requests authenticated cleanup concurrently with normal hydration. Development and internal builds retain existing debug behavior.

The backend cleanup mutations authorize and query by the canonical server-owned `owner_id` instead of payer/member UUIDs. A compound `owner_id` plus `is_payback_generated_mock_data` index keeps each cleanup bounded to the authenticated account, even if other accounts have hundreds of generated records. This lets a user remove their own stale generated records when those records are the source of the identity mismatch, while preserving every real record and every other account's generated records.

Client filtering remains in place even if cleanup fails or the backend has not deployed yet. This defense ensures generated data cannot corrupt production balances or activity again, including during offline startup from an older cache. Cleanup is best-effort and runs outside the hydration task so a slow or failed cleanup never blocks real groups, expenses, or friends from loading.

## Rejected approaches

- Coercing unmatched expense UUIDs into the current identity would make the displayed totals nonzero, but it would guess ownership and violate the repository's identity/security rules.
- A client-only filter would fix the screen but leave contaminated production records indefinitely.
- A one-off database edit would repair only today's account and would not prevent recurrence.

## Verification

Regression tests cover production filtering, development preservation, production seed-write blocking, and stale-ID backend cleanup ownership. Focused tests run red then green. Release validation includes the full monorepo CI, the canonical iOS CI script, Thread Sanitizer, Address Sanitizer, generated-project parity, and a signed Release archive before TestFlight upload.
