# Authentication and stability rollout

This change prepares configuration and validation. It does not create a Clerk production
instance, migrate users, deploy Convex, change production records, or prove account continuity.
The existing production app uses development Clerk identities. Replacing its issuer without a
verified continuity plan can strand existing accounts. Do not flip the issuer simply to pass a build.

## Development

Debug and Internal retain the existing public development publishable key, issuer, webcredentials
domain, and development Convex deployment in `project.yml`. These public values are not secrets.
The known development Convex URL selects the development issuer. For local config evaluation
without `CONVEX_CLOUD_URL`, set `PAYBACK_AUTH_ENV=development`. No production key is checked in.

## Production prerequisites

1. Configure the Clerk production instance and its JWT template with application ID `convex`,
   production domain, native app identifiers, redirect settings, and Apple associated-domain file.
2. Verify how every existing Clerk account ID and Convex `accounts.id` remains associated with the
   same person. A matching email alone is not authorization. Rehearse the provider-supported
   migration/recovery process on a nonproduction copy. Account continuity is an external blocker.
3. External auth email changes remain unsupported. Do not rewrite email-keyed ownership or create
   a replacement account. Use an identity-preserving operator recovery procedure until a dedicated
   migration exists.
4. Supply build settings `PAYBACK_PRODUCTION_CLERK_PUBLISHABLE_KEY`,
   `PAYBACK_PRODUCTION_CLERK_ISSUER`, and `PAYBACK_PRODUCTION_AUTH_ASSOCIATED_DOMAIN` through the
   release build environment or an untracked xcconfig. The domain is `webcredentials:<issuer host>`.
   Set `PAYBACK_PRODUCTION_AUTH_CONTINUITY_VERIFIED=YES` only after step 2 is documented.
5. On the matching Convex production deployment configure `PAYBACK_AUTH_ENV=production`,
   `CLERK_JWT_ISSUER_DOMAIN`, and `PAYBACK_AUTH_CONTINUITY_VERIFIED=YES`. The backend rejects a
   development issuer in production. Coordinate this change with the verified client/provider
   rollout; deploying this configuration without its prerequisites intentionally fails.
6. Run `python3 scripts/test-auth-config.py`, backend auth tests, and a Release archive. The
   prebuild script checks resolved key/issuer/domain/environment and continuity settings. It does
   not prove provider dashboard settings, entitlements hosting, or live login. Verify those in
   staging and record evidence before release.

## Data rollout

Deploy additive schema/backend changes and dual-maintained member references first. Run the
bounded resumable reference backfill, inspect completeness/readiness, and only then enable V3
identity operations and financial contract version 2 clients. Never set a readiness marker to
bypass incomplete work. Snapshot and inspect financial totals, split IDs and settlement states
before and after a nonproduction rehearsal. Unknown historical currency stays unknown.

Backup version 2 preserves numeric Double text, source member UUIDs, all raw shares and their
settlement flags, subexpenses, notes, context, and absent currency. Explicit friend rows alone
create confirmed relationships. Linked metadata in backups cannot grant trusted account links.
Restore keeps the original group roster and declares every raw financial participant of each
GROUP/DIRECT expense in a request-local history manifest. Declarations preserve private financial
history; they grant no group membership, friendship, alias, account link, or automatic sharing.
Current server authorization controls sharing, and deleted-party display details may be scrubbed
without changing financial rows. Grouped-individual history uses its existing separate rules.
Repeated export/restore does not grow group rosters or weaken restored-history restrictions.

The client sends bounded friend, group, then expense requests. It subdivides only after the exact
structured rollback-budget error, and retries an uncertain request with identical IDs at most three
times. A missing/malformed item acknowledgement, rejected row, cancellation, or failed final snapshot
returns incomplete progress. Earlier confirmed requests remain saved. An uncertain committed write
later acknowledged as already present is reported as present, not provably newly created. Completed
import requires a successful actor/generation-bound authoritative refresh; source arrays are never
replayed locally over server suppression or sanitized data.

Legacy backups remain readable, but prior exports already discarded notes/context, rounded
amounts, and removed tiny/zero shares; that information cannot be reconstructed. Invalid financial
rows fail with an actionable error instead of inventing payer liability. Import is not an unhide
operation for previously cleared history. A partially completed network import may have durable
server chunks; repeat uses stable source IDs and does not invent replacement identities.

## Rollback

Disable new authoring and new identity-job initiation if necessary. Preserve alias, suppression,
currency, capability-floor, job and reference records. Keep upgraded authorization/read validators;
resume or forward-fix outstanding operations. Never restore vulnerable bootstrap/participant
validation or downgrade the issuer independently of the account-continuity plan. Restore data only
through a separately reviewed, precisely scoped operator procedure. This PR authorizes none of
those production actions.
