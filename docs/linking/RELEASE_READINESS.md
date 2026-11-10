# Authentication and stability rollout

This change prepares configuration and validation. It does not create a Clerk production
instance, migrate users, deploy Convex, change production records, or prove account continuity.
The existing production app uses the verified provider `https://accurate-eagle-80.clerk.accounts.dev`
with application ID `convex` on `https://tacit-marmot-746.convex.cloud`. Maintaining that provider
preserves its auth subjects; migrating to a new Clerk production instance is a separate rollout.
Replacing the issuer without a verified continuity plan can strand existing accounts. Do not flip
the issuer simply to pass a build.

## Development

Debug and Internal retain the existing public development publishable key, issuer, webcredentials
domain, and development Convex deployment in `project.yml`. These public values are not secrets.
The known development Convex URL selects the development issuer. For local config evaluation
without `CONVEX_CLOUD_URL`, set `PAYBACK_AUTH_ENV=development`. Release credentials remain externally
supplied.

## Maintain the verified existing production provider

The explicit profile `legacy-production-tacit-marmot-746` accepts only this existing deployment and
provider. It defaults to unset, is never inferred from a URL or key, and rejects unknown profile
names. It does not enable old-client writes or alter account subjects, authorization, readiness
gates, financial contract versions, or backend URL mappings.

For a separately approved rollout, supply all of these backend settings explicitly:

- `PAYBACK_AUTH_PROFILE=legacy-production-tacit-marmot-746`
- `PAYBACK_AUTH_ENV=production`
- `CLERK_JWT_ISSUER_DOMAIN=https://accurate-eagle-80.clerk.accounts.dev`
- `PAYBACK_AUTH_CONTINUITY_VERIFIED=YES`, only after documenting account continuity

The backend additionally requires `CONVEX_CLOUD_URL` to be exactly
`https://tacit-marmot-746.convex.cloud` and keeps application ID `convex`. The profile rejects every
other deployment, issuer, mode, and missing verification; it never falls back to credentials.

For PayBack/Release, supply `PAYBACK_PRODUCTION_AUTH_PROFILE=legacy-production-tacit-marmot-746`
and the existing external release settings:

- `PAYBACK_PRODUCTION_CLERK_PUBLISHABLE_KEY`: the exact existing public `pk_test_` key in
  `project.yml` Debug/Internal settings; alternative encodings and keys are rejected
- `PAYBACK_PRODUCTION_CLERK_ISSUER=https://accurate-eagle-80.clerk.accounts.dev`
- `PAYBACK_PRODUCTION_AUTH_ASSOCIATED_DOMAIN=webcredentials:accurate-eagle-80.clerk.accounts.dev`
- `PAYBACK_PRODUCTION_AUTH_CONTINUITY_VERIFIED=YES`, only after verification

The Release validator requires `PAYBACK_CONVEX_ENV=production`, which retains the existing routing
to the known production deployment. No Release key, profile selection, or `YES` assertion is checked
in. PayBackInternal/Internal continues to use development data.

## Migrate to a new Clerk production instance

Leave `PAYBACK_AUTH_PROFILE` and `PAYBACK_PRODUCTION_AUTH_PROFILE` unset for the default modern
production path. It still requires a `pk_live_` key, a matching HTTPS production issuer and
associated domain, production backend routing, and explicit continuity verification. A development
issuer is rejected without the exact legacy profile above.

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
   development issuer in this default modern production path. Coordinate this change with the
   verified client/provider rollout; deploying this configuration without its prerequisites
   intentionally fails.

## Release evidence and cutover approval

For either profile, run `python3 scripts/test-auth-config.py`, backend auth tests, and repository CI.
These local checks validate configuration contracts only. A real PayBack/Release archive and export
remain required: inspect the actual app Info.plist, signed entitlements, source commit, version/build,
production environment, issuer, key, domain, and approved distribution options. Verify provider
settings, associated-domain hosting, and a real signed-JWT login with existing account visibility.
Simulated identities do not prove live authentication. Source tests do not complete these gates.

The planned mandatory old-client upgrade requires separate explicit user approval before backend
deployment or distribution. Existing build 134 / distributed build 146 omits
`financial_contract_version`, and the new server rejects its expense creation and linking writes
that require the current financial contract. Preserve those guards. A source profile that preserves
the issuer does not provide full old-client write compatibility. Present the affected internal and
external TestFlight audiences, available update path, and Apple processing/review dependencies
before approval; an internal-only build does not
cover external testers. Approval to use usual live data does not approve that disruption.

Production/cloud configuration, data repair, migrations, upload, and distribution remain blocked
pending their separate explicit approval. If the upgrade impact is declined, stop this rollout and
prepare a separately reviewed backwards-compatible staging plan; do not weaken protective guards.

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
