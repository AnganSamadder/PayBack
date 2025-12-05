# PayBack Scripts

The scripts directory now only contains optional tooling helpers. Supabase configuration is loaded from the environment or `SupabaseConfig.plist` at runtime; no emulator setup is required.

- `setup-git-hooks.sh`: installs git hooks for local workflows (optional).
- `test-ci-locally.sh`: runs the PayBack scheme tests with Supabase env vars loaded from `.env.supabase.local`.
- `test-with-coverage.sh`: runs tests with code coverage enabled and writes `coverage.json` + `coverage-report.txt`.

To run tests locally:

```bash
xcodegen generate
xcodebuild -scheme PayBack -destination "platform=iOS Simulator,name=iPhone 16" test
```

Environment variables for Supabase:
- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
