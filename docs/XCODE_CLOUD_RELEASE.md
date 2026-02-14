# Xcode Cloud Release Process

This document describes the complete Xcode Cloud workflow setup for PayBack.

## Overview

| Workflow               | Trigger         | Scheme          | Convex DB   | Destination         |
| ---------------------- | --------------- | --------------- | ----------- | ------------------- |
| **Main CI**            | Push to `main`  | PayBack         | Development | None (CI only)      |
| **Alpha Release**      | Tag `alpha-*`   | PayBackInternal | Development | TestFlight Internal |
| **Beta Release**       | Tag `beta-*`    | PayBack         | Production  | TestFlight External |
| **Production Release** | Tag `release-*` | PayBack         | Production  | App Store           |

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
- **Post-Actions**: Notify on failure

---

### 2. Alpha Release (Internal TestFlight)

**Purpose**: Release to internal testers via TestFlight. Uses development Convex DB.

**Xcode Cloud Settings**:

- **Name**: `Alpha Release`
- **Start Condition**: Tag Changes → `alpha-*`
- **Scheme**: `PayBackInternal`
- **Actions**:
  - Test (iPhone 15 Pro, iOS 18)
  - Archive (Internal configuration)
  - Deploy to TestFlight: **Internal Testing**
- **Environment Variables**:
  ```
  CONVEX_DEPLOY_KEY = <your-convex-deploy-key>
  ```

**Tag Format**: `alpha-X.Y.Z` (e.g., `alpha-0.1.0`, `alpha-1.2.3`)

---

### 3. Beta Release (External TestFlight)

**Purpose**: Release to external testers via TestFlight. Uses production Convex DB.

**Xcode Cloud Settings**:

- **Name**: `Beta Release`
- **Start Condition**: Tag Changes → `beta-*`
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

**Tag Format**: `beta-X.Y.Z` (e.g., `beta-0.1.0`, `beta-1.0.0`)

---

### 4. Production Release (App Store)

**Purpose**: Release to App Store. Uses production Convex DB.

**Xcode Cloud Settings**:

- **Name**: `Production Release`
- **Start Condition**: Tag Changes → `release-*`
- **Scheme**: `PayBack`
- **Actions**:
  - Test (iPhone 15 Pro, iOS 18)
  - Archive (Release configuration)
  - Deploy to App Store: **Release**
- **Environment Variables**:
  ```
  CONVEX_DEPLOY_KEY = <your-convex-deploy-key>
  CONVEX_DEPLOY_ON_CI = 1
  ```

**Tag Format**: `release-X.Y.Z` (e.g., `release-1.0.0`, `release-2.1.0`)

---

## Release Process

### Creating an Alpha Release (Internal Testing)

```bash
git checkout main
git pull

git tag alpha-0.1.0
git push origin alpha-0.1.0

# Xcode Cloud automatically:
# - Runs tests
# - Archives with Internal config (development DB)
# - Uploads to TestFlight Internal Testing
```

### Creating a Beta Release (External Testing)

```bash
git checkout main
git pull

git tag beta-1.0.0
git push origin beta-1.0.0

# Xcode Cloud automatically:
# - Runs tests
# - Archives with Release config (production DB)
# - Deploys Convex backend
# - Uploads to TestFlight External Testing
```

### Creating a Production Release (App Store)

```bash
git checkout main
git pull

git tag release-1.0.0
git push origin release-1.0.0

# Xcode Cloud automatically:
# - Runs tests
# - Archives with Release config (production DB)
# - Deploys Convex backend
# - Submits to App Store for review
```

---

## Version Automation

Version numbers are extracted from git tags automatically:

| Tag             | Marketing Version | Build Number             |
| --------------- | ----------------- | ------------------------ |
| `alpha-0.1.0`   | 0.1.0             | Xcode Cloud build number |
| `beta-1.0.0`    | 1.0.0             | Xcode Cloud build number |
| `release-1.0.0` | 1.0.0             | Xcode Cloud build number |

---

## Convex DB Routing

| Config   | `PAYBACK_CONVEX_ENV` | Convex URL                       |
| -------- | -------------------- | -------------------------------- |
| Debug    | `development`        | flippant-bobcat-304.convex.cloud |
| Internal | `development`        | flippant-bobcat-304.convex.cloud |
| Release  | `production`         | tacit-marmot-746.convex.cloud    |

---

## Xcode Cloud Setup Checklist

1. [ ] Create **Main CI** workflow (branch changes on `main`)
2. [ ] Create **Alpha Release** workflow (tag changes `alpha-*`)
3. [ ] Create **Beta Release** workflow (tag changes `beta-*`)
4. [ ] Create **Production Release** workflow (tag changes `release-*`)
5. [ ] Add `CONVEX_DEPLOY_KEY` secret to Alpha/Beta/Production workflows
6. [ ] Set `CONVEX_DEPLOY_ON_CI=1` for Beta and Production workflows
7. [ ] Configure TestFlight groups for Internal and External testing
8. [ ] Test: `git tag alpha-0.0.1 && git push origin alpha-0.0.1`

---

## Troubleshooting

### Wrong Convex DB used

Check scheme's archive configuration:

- PayBackInternal → Internal config → development DB
- PayBack → Release config → production DB

### TestFlight upload fails

- Verify App Store Connect API key is configured
- Check provisioning profile/certificate setup
