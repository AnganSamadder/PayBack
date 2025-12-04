# PayBack

PayBack is a simple app to help organize shared expenses. Create groups, add expenses, and keep track of who owes what. The goal is to make splitting bills and settling up quick and clear.

## Getting Started
- Open PayBack.xcodeproj in Xcode
- Select the PayBack scheme
- Build and run on iOS Simulator or a device

## Supabase Setup
- Provide your Supabase project credentials via environment variables or a plist:
  - `SUPABASE_URL`
  - `SUPABASE_ANON_KEY`
- The app will load these from the environment first, then `SupabaseConfig.plist` if bundled. See `apps/ios/PayBack/SupabaseConfig.example.plist` for the expected keys.
- Initialize your database by running `supabase/schema.sql` in the Supabase SQL editor (creates tables and RLS policies).
- No emulator setup is required; the app will fall back to local mock services when Supabase credentials are not present (useful for UI-only runs).

## License
MIT License – see LICENSE for details.
