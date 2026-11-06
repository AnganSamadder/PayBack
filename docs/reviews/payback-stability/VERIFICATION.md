# Verification record

Source commit: `d20cd85c`. Documentation-only commits may follow this source snapshot.

| Gate                                | Observed result                                                                                                  |
| ----------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `bun run ci` in canonical wrapper   | Passed: lint, typecheck, formatting, 730 backend tests across 73 files, and web build.                           |
| Web smoke test                      | Passed: 1 test. The web package still has no unit tests.                                                         |
| Canonical SDK-enabled iOS suite     | Passed: 2,887 tests, 0 failures, 0 skips.                                                                        |
| Thread Sanitizer                    | Running; no final result yet.                                                                                    |
| Address Sanitizer                   | Pending.                                                                                                         |
| Production restore recording check  | Passed, including authoritative refresh, suppression, cancellation, account switching, and participant metadata. |
| Authentication configuration matrix | Passed: 4 Python checks and 4 backend tests.                                                                     |
| Final post-PR code reviews          | Pending. Earlier implementation rounds requested changes; their supported findings received repairs.             |

The canonical command was:

```bash
PAYBACK_SIMULATOR_UDID=AAE9A4B4-3497-47A5-AA36-B592783D8ECD \
DERIVED_DATA_PATH=/tmp/PayBackReviewDerivedData \
./scripts/test-ci-locally.sh
```

The dedicated device is an arm64 iPhone 17 Pro simulator on iOS 26.0.1, using
Xcode 26.0.1. JavaScript uses Bun 1.3.9 and the frozen lockfile. The installed
Convex versions are TypeScript 1.31.7 and Swift 0.7.0; Clerk Swift is 1.3.6.

These tests exercise production SDK adapters with injected network boundaries.
They do not establish live Clerk login, a production backfill, or a production
provider cutover. No production mutation or deployment was performed. Follow
[release readiness](../../linking/RELEASE_READINESS.md) and the
[linking runbook](../../linking/ACCOUNT_LINKING_PIPELINE_RUNBOOK.md) before rollout.

The first full iOS failure set and later four login-fixture failures were retained
in the local evidence. They were repaired and rerun; they are not omitted from the
[implementation review record](CODE_REVIEW_LOG.md). Current app coverage in the
standard report is 75.1% for functional source and 19.7% for UI source. Passing
suites do not prove every live integration case; the case matrix labels those
limits separately.

## Local evidence

Commands and regression source are committed for reproduction. Large local logs
and Xcode bundles are kept outside Git. Their hashes identify the recorded runs.

| Evidence             | Local artifact                               | SHA256                                                             |
| -------------------- | -------------------------------------------- | ------------------------------------------------------------------ |
| Canonical standard   | `/tmp/payback-repair-standard4.log`          | `a48693e41bf4137bd505913909f09f49c747870880e36ba1f266a4573f891e14` |
| Xcode result summary | `/tmp/payback-repair-standard4-summary.json` | `061ce5480da9c05112b58bcf916277547b20ef602927cde49aab2243372d5122` |
