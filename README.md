# PayBack

PayBack is a simple app to help organize shared expenses. Create groups, add expenses, and keep track of who owes what. The goal is to make splitting bills and settling up quick and clear.

## Getting Started

1. Install dependencies:
   ```bash
   # Install Node.js (for Convex CLI)
   brew install node
   
   # Install XcodeGen
   brew install xcodegen
   ```

2. Generate the Xcode project:
   ```bash
   xcodegen generate
   ```

3. Open and run:
   - Open `PayBack.xcodeproj` in Xcode
   - Select the PayBack scheme
   - Build and run on iOS Simulator or device

## Backend (Convex)

The app uses [Convex](https://convex.dev) for its backend. Backend functions are in the `convex/` directory.

### Local Development

```bash
# Start Convex dev server (watches for changes)
npx convex dev

# Deploy to production
npx convex deploy
```

### Environment URLs

The app automatically selects the correct Convex URL:
- **Debug builds**: Uses development Convex deployment
- **Release builds**: Uses production Convex deployment

No environment variables are required for the iOS app itself - URLs are configured in `AppConfig.swift`.

## Authentication

Authentication is handled by [Clerk](https://clerk.dev). The Clerk publishable key is configured in `AppConfig.swift`.

## License

MIT License - see LICENSE for details.
