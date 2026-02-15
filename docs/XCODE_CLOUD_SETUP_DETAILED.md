# Xcode Cloud Setup - Detailed Step-by-Step

Complete instructions for creating 4 workflows in App Store Connect.

---

## Prerequisites

Before starting, ensure:

- [ ] Apple Developer Account is connected to Xcode
- [ ] App created in App Store Connect (Bundle ID: `com.angansamadder.PayBack`)
- [ ] GitHub repo connected to Xcode Cloud

---

## How to Access Xcode Cloud

1. Open **Xcode**
2. Go to **Settings** (or Preferences) → **Accounts**
3. Select your Apple ID
4. Click **Manage Cloud Workflows**
5. Browser opens to App Store Connect → Xcode Cloud

---

## Workflow 1: Main CI

**Purpose**: Run tests on every push to main. No TestFlight upload.

### Step-by-Step Creation

1. In App Store Connect → Xcode Cloud → **Workflows**
2. Click **+** → **Create Workflow**
3. **Name**: Type `Main CI`
4. **Repository**: Select `AnganSamadder/PayBack`
5. Click **Next**

### Start Condition

| Setting               | Value                           |
| --------------------- | ------------------------------- |
| **Trigger Type**      | Branch Changes                  |
| **Branch**            | `main`                          |
| **File Restrictions** | Leave empty (all files trigger) |

### Build Settings

| Setting           | Value                     |
| ----------------- | ------------------------- |
| **Scheme**        | `PayBack`                 |
| **Configuration** | Debug                     |
| **Destination**   | iPhone 15 Pro (or latest) |
| **iOS Version**   | iOS 18 (or latest)        |

### Actions

1. **Test Action** (default - keep it)
2. **Build Action** - click **Add Action** → **Build**

### Post-Actions

1. Click **Add Post-Action**
2. Select **Notify**
3. Choose **On Failure**
4. Add your email/team

### Summary for Main CI

```
Name:           Main CI
Repository:     AnganSamadder/PayBack
Trigger:        Branch changes on 'main'
Scheme:         PayBack
Configuration:  Debug
Actions:        Test + Build
TestFlight:     None
```

---

## Workflow 2: Alpha Release

**Purpose**: Release to internal testers. Uses development Convex DB.

### Step-by-Step Creation

1. Click **+** → **Create Workflow**
2. **Name**: Type `Alpha Release`
3. **Repository**: Select `AnganSamadder/PayBack`
4. Click **Next**

### Start Condition

| Setting          | Value          |
| ---------------- | -------------- |
| **Trigger Type** | Tag Changes    |
| **Tag Pattern**  | `alpha-*`      |
| **Pattern Type** | Glob (default) |

### Build Settings

| Setting           | Value             |
| ----------------- | ----------------- |
| **Scheme**        | `PayBackInternal` |
| **Configuration** | Internal          |
| **Destination**   | iPhone 15 Pro     |
| **iOS Version**   | iOS 18            |

### Actions

1. **Test Action** (keep)
2. **Archive Action** - click **Add Action** → **Archive**
   - Configuration: `Internal`
3. **TestFlight Action** - click **Add Action** → **Deploy to TestFlight**
   - **Testing Type**: Internal Testing
   - **Groups**: Select your internal group (or create one)

### Environment Variables

1. Scroll to **Environment** section
2. Click **+ Add Variable**
3. Add:

| Name                | Value                      | Secret |
| ------------------- | -------------------------- | ------ |
| `CONVEX_DEPLOY_KEY` | `<your-convex-deploy-key>` | ✅ Yes |

### Summary for Alpha Release

```
Name:           Alpha Release
Repository:     AnganSamadder/PayBack
Trigger:        Tag 'alpha-*'
Scheme:         PayBackInternal
Configuration:  Internal
Actions:        Test + Archive + TestFlight Internal
TestFlight:     Internal Testing
Convex DB:      Development
Env Vars:       CONVEX_DEPLOY_KEY
```

---

## Workflow 3: Beta Release

**Purpose**: Release to external testers. Uses production Convex DB.

### Step-by-Step Creation

1. Click **+** → **Create Workflow**
2. **Name**: Type `Beta Release`
3. **Repository**: Select `AnganSamadder/PayBack`
4. Click **Next**

### Start Condition

| Setting          | Value          |
| ---------------- | -------------- |
| **Trigger Type** | Tag Changes    |
| **Tag Pattern**  | `beta-*`       |
| **Pattern Type** | Glob (default) |

### Build Settings

| Setting           | Value         |
| ----------------- | ------------- |
| **Scheme**        | `PayBack`     |
| **Configuration** | Release       |
| **Destination**   | iPhone 15 Pro |
| **iOS Version**   | iOS 18        |

### Actions

1. **Test Action** (keep)
2. **Archive Action** - click **Add Action** → **Archive**
   - Configuration: `Release`
3. **TestFlight Action** - click **Add Action** → **Deploy to TestFlight**
   - **Testing Type**: External Testing
   - **Groups**: Select your external group (or create one)

### Environment Variables

1. Scroll to **Environment** section
2. Click **+ Add Variable**
3. Add:

| Name                  | Value                      | Secret |
| --------------------- | -------------------------- | ------ |
| `CONVEX_DEPLOY_KEY`   | `<your-convex-deploy-key>` | ✅ Yes |
| `CONVEX_DEPLOY_ON_CI` | `1`                        | ❌ No  |

### Summary for Beta Release

```
Name:           Beta Release
Repository:     AnganSamadder/PayBack
Trigger:        Tag 'beta-*'
Scheme:         PayBack
Configuration:  Release
Actions:        Test + Archive + TestFlight External
TestFlight:     External Testing
Convex DB:      Production
Env Vars:       CONVEX_DEPLOY_KEY, CONVEX_DEPLOY_ON_CI=1
```

---

## Workflow 4: Production Release

**Purpose**: Release to App Store. Uses production Convex DB.

### Step-by-Step Creation

1. Click **+** → **Create Workflow**
2. **Name**: Type `Production Release`
3. **Repository**: Select `AnganSamadder/PayBack`
4. Click **Next**

### Start Condition

| Setting          | Value          |
| ---------------- | -------------- |
| **Trigger Type** | Tag Changes    |
| **Tag Pattern**  | `release-*`    |
| **Pattern Type** | Glob (default) |

### Build Settings

| Setting           | Value         |
| ----------------- | ------------- |
| **Scheme**        | `PayBack`     |
| **Configuration** | Release       |
| **Destination**   | iPhone 15 Pro |
| **iOS Version**   | iOS 18        |

### Actions

1. **Test Action** (keep)
2. **Archive Action** - click **Add Action** → **Archive**
   - Configuration: `Release`
3. **App Store Action** - click **Add Action** → **Deploy to App Store**
   - **Release Type**: Release
   - **Phased Release**: Optional (can enable for gradual rollout)

### Environment Variables

1. Scroll to **Environment** section
2. Click **+ Add Variable**
3. Add:

| Name                  | Value                      | Secret |
| --------------------- | -------------------------- | ------ |
| `CONVEX_DEPLOY_KEY`   | `<your-convex-deploy-key>` | ✅ Yes |
| `CONVEX_DEPLOY_ON_CI` | `1`                        | ❌ No  |

### Summary for Production Release

```
Name:           Production Release
Repository:     AnganSamadder/PayBack
Trigger:        Tag 'release-*'
Scheme:         PayBack
Configuration:  Release
Actions:        Test + Archive + App Store Release
TestFlight:     None (goes directly to App Store)
Convex DB:      Production
Env Vars:       CONVEX_DEPLOY_KEY, CONVEX_DEPLOY_ON_CI=1
```

---

## Quick Comparison Table

| Setting         | Main CI       | Alpha               | Beta                    | Production              |
| --------------- | ------------- | ------------------- | ----------------------- | ----------------------- |
| **Trigger**     | `main` branch | `alpha-*` tag       | `beta-*` tag            | `release-*` tag         |
| **Scheme**      | PayBack       | PayBackInternal     | PayBack                 | PayBack                 |
| **Config**      | Debug         | Internal            | Release                 | Release                 |
| **Convex DB**   | Development   | Development         | Production              | Production              |
| **Destination** | None          | TestFlight Internal | TestFlight External     | App Store               |
| **Env Vars**    | None          | CONVEX_DEPLOY_KEY   | + CONVEX_DEPLOY_ON_CI=1 | + CONVEX_DEPLOY_ON_CI=1 |

---

## After Creating Workflows

### 1. Create TestFlight Groups

1. In App Store Connect → **TestFlight**
2. **Internal Testing**:
   - Click **+** next to Internal Testing
   - Name: `Developers` or `Internal`
   - Add team members by Apple ID
3. **External Testing**:
   - Click **+** next to External Testing
   - Name: `Beta Testers`
   - Add testers by email or enable public link

### 2. Test the Setup

```bash
# Test alpha workflow
git tag alpha-0.0.1
git push origin alpha-0.0.1

# Wait 10-15 minutes
# Check App Store Connect → Xcode Cloud → Builds
# Verify build appears in TestFlight → Internal Testing
```

### 3. Common Issues

| Issue                    | Solution                                                                                        |
| ------------------------ | ----------------------------------------------------------------------------------------------- |
| "Scheme not found"       | Open Xcode → Product → Scheme → Manage Schemes → Check "Shared" for PayBack and PayBackInternal |
| "No signing certificate" | Xcode Cloud Settings → Signing → Let Xcode Cloud manage certificates                            |
| "Build fails"            | Check CI logs in App Store Connect for specific error                                           |

---

## Tag Naming Convention

| Tag             | Version          | Example                          |
| --------------- | ---------------- | -------------------------------- |
| `alpha-X.Y.Z`   | Internal testing | `alpha-0.1.0`, `alpha-0.2.0`     |
| `beta-X.Y.Z`    | External testing | `beta-1.0.0`, `beta-1.1.0`       |
| `release-X.Y.Z` | App Store        | `release-1.0.0`, `release-2.0.0` |

**Example workflow:**

```bash
# During development - just push to main
git push origin main

# Ready for internal testing
git tag alpha-0.1.0
git push origin alpha-0.1.0

# Ready for external beta testing
git tag beta-1.0.0
git push origin beta-1.0.0

# Ready for App Store submission
git tag release-1.0.0
git push origin release-1.0.0
```
