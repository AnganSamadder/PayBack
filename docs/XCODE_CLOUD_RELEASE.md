# Xcode Cloud Release Process

This document describes the complete Xcode Cloud workflow setup for PayBack.

## Overview

| Workflow               | Trigger                     | Scheme          | Convex DB   | TestFlight |
| ---------------------- | --------------------------- | --------------- | ----------- | ---------- |
| **Main CI**            | Push to `main`              | PayBack         | Development | No         |
| **Beta Release**       | Tag `beta-*`                | PayBackInternal | Development | Internal   |
| **Production Release** | Tag `release-*` or `prod-*` | PayBack         | Production  | External   |

## Workflow Configuration

### 1. Main CI (Continuous Integration)

**Purpose**: Validate every push to main branch. No TestFlight upload.

**Xcode Cloud Settings**:

- **Name**: `Main CI`
- **Start Condition**: Branch Changes → `main`
- **Scheme**: `PayBack`
- **Actions**:
  - Test (iPhone 15 Pro, iOS 18)
  - Build (Debug configuration)
- **Environment Variables**: None needed (uses Debug config)
- **Post-Actions**: Notify on failure

---

### 2. Beta Release (Internal TestFlight)

**Purpose**: Release to internal testers via TestFlight. Uses development Convex DB.

**Xcode Cloud Settings**:

- **Name**: `Beta Release`
- **Start Condition**: Tag Changes → `beta-*`
- **Scheme**: `PayBackInternal`
- **Actions**:
  - Test (iPhone 15 Pro, iOS 18)
  - Archive (Internal configuration)
  - Deploy to TestFlight: **Internal Testing**
- **Environment Variables**:
  ```
  CONVEX_DEPLOY_KEY = <your-convex-deploy-key>
  ```
- **Post-Actions**:
  - Notify on success/failure

**Tag Format**: `beta-X.Y.Z` (e.g., `beta-0.1.0`, `beta-1.2.3`)

---

### 3. Production Release (External TestFlight / App Store)

**Purpose**: Release to external testers and App Store. Uses production Convex DB.

**Xcode Cloud Settings**:

- **Name**: `Production Release`
- **Start Condition**: Tag Changes → `release-*` or `prod-*`
- **Scheme**: `PayBack`
- **Actions**:
  - Test (iPhone 15 Pro, iOS 18)
  - Archive (Release configuration)
  - Deploy to TestFlight: **External Testing**
- **Environment Variables**:
  ```
  CONVEX_DEPLOY_KEY = <your-convex-deploy-key>
  CONVEX_DEPLOY_ON_CI = 1
  ```
- **Post-Actions**:
  - Notify on success/failure

**Tag Format**: `release-X.Y.Z` or `prod-X.Y.Z` (e.g., `release-1.0.0`, `prod-2.1.0`)

---

## Release Process

### Creating a Beta Release

```bash
# 1. Ensure you're on main with all changes committed
git checkout main
git pull

# 2. Create and push the beta tag
git tag beta-0.1.0
git push origin beta-0.1.0

# 3. Xcode Cloud automatically:
#    - Detects the tag
#    - Runs tests
#    - Archives with Internal config (development DB)
#    - Uploads to TestFlight Internal Testing
#    - Notifies the team
```

### Creating a Production Release

```bash
# 1. Ensure you're on main with all changes committed
git checkout main
git pull

# 2. Create and push the production tag
git tag release-1.0.0
git push origin release-1.0.0

# 3. Xcode Cloud automatically:
#    - Detects the tag
#    - Runs tests
#    - Archives with Release config (production DB)
#    - Deploys Convex backend (if CONVEX_DEPLOY_ON_CI=1)
#    - Uploads to TestFlight External Testing
#    - Notifies the team
```

---

## Version Automation

Version numbers are extracted from git tags automatically:

| Tag             | Marketing Version | Build Number             |
| --------------- | ----------------- | ------------------------ |
| `beta-0.1.0`    | 0.1.0             | Xcode Cloud build number |
| `beta-1.2.3`    | 1.2.3             | Xcode Cloud build number |
| `release-1.0.0` | 1.0.0             | Xcode Cloud build number |

The `ci_pre_xcodebuild.sh` script:

1. Detects if a tag triggered the build
2. Extracts the version from the tag
3. Updates `project.yml` with the version
4. Regenerates the Xcode project

---

## CI Scripts

### ci_pre_xcodebuild.sh

Runs before xcodebuild:

- Logs environment info
- Extracts version from tags
- Updates project.yml with version
- Regenerates Xcode project

### ci_post_xcodebuild.sh

Runs after xcodebuild:

- Generates TestFlight release notes from git commits
- Logs deployment summary

---

## Environment Variables

| Variable              | Set In         | Purpose                       |
| --------------------- | -------------- | ----------------------------- |
| `CI_TAG`              | Xcode Cloud    | Git tag that triggered build  |
| `CI_BUILD_NUMBER`     | Xcode Cloud    | Build number                  |
| `CONVEX_DEPLOY_KEY`   | Workflow       | Deploy backend on release     |
| `CONVEX_DEPLOY_ON_CI` | Workflow       | Set to `1` to enable deploy   |
| `PAYBACK_CONVEX_ENV`  | Build Settings | `development` or `production` |

---

## Convex DB Routing

The correct Convex database is selected based on build configuration:

| Config   | `PAYBACK_CONVEX_ENV` | Convex URL                       |
| -------- | -------------------- | -------------------------------- |
| Debug    | `development`        | flippant-bobcat-304.convex.cloud |
| Internal | `development`        | flippant-bobcat-304.convex.cloud |
| Release  | `production`         | tacit-marmot-746.convex.cloud    |

This is configured in `project.yml` and automatically applied based on the scheme's archive configuration.

---

## Xcode Cloud Setup Checklist

1. [ ] Create **Main CI** workflow (branch changes on `main`)
2. [ ] Create **Beta Release** workflow (tag changes `beta-*`)
3. [ ] Create **Production Release** workflow (tag changes `release-*`, `prod-*`)
4. [ ] Add `CONVEX_DEPLOY_KEY` secret to release workflows
5. [ ] Set `CONVEX_DEPLOY_ON_CI=1` for Production Release workflow
6. [ ] Configure TestFlight groups for Internal and External testing
7. [ ] Test with a beta tag: `git tag beta-0.0.1 && git push origin beta-0.0.1`

---

## Troubleshooting

### Build fails with "No iOS 18 simulators"

- Check Xcode Cloud is using Xcode 16+
- The pre-build script logs available runtimes

### Version not updating from tag

- Check tag format: must be `beta-X.Y.Z` or `release-X.Y.Z`
- Check ci_pre_xcodebuild.sh logs for version extraction

### Wrong Convex DB used

- Check scheme's archive configuration:
  - PayBackInternal → Internal config → development DB
  - PayBack → Release config → production DB

### TestFlight upload fails

- Verify App Store Connect API key is configured
- Check provisioning profile/certificate setup
