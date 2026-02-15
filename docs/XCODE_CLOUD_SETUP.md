# Xcode Cloud Setup Guide

Complete step-by-step instructions to set up Xcode Cloud for PayBack.

## Prerequisites

- [ ] Apple Developer Account (paid)
- [ ] App created in App Store Connect
- [ ] GitHub repository connected to Xcode Cloud
- [ ] Convex deploy key (for beta/release builds)

---

## Step 1: Connect GitHub to Xcode Cloud

1. Open **Xcode** → **Settings** (or Preferences)
2. Go to **Accounts** tab
3. Click **+** → Add your Apple ID
4. After signing in, click **Manage Cloud Workflows**
5. This opens App Store Connect in browser

OR directly:

1. Go to [App Store Connect](https://appstoreconnect.apple.com)
2. Go to **Xcode Cloud** tab
3. Click **Connect GitHub** if not already connected
4. Authorize access to your `AnganSamadder/PayBack` repository

---

## Step 2: Create App in App Store Connect

If not already done:

1. Go to **Apps** → Click **+** → **New App**
2. Fill in:
   - **Name**: PayBack
   - **Primary Language**: English
   - **Bundle ID**: `com.angansamadder.PayBack`
   - **SKU**: PayBack (or any unique identifier)
3. Click **Create**

---

## Step 3: Create 4 Xcode Cloud Workflows

In App Store Connect → Xcode Cloud → Settings → Workflows:

### Workflow 1: Main CI (CI Only)

| Step                              | Setting                           |
| --------------------------------- | --------------------------------- |
| Click **+** → **Create Workflow** |                                   |
| **Name**                          | `Main CI`                         |
| **Repository**                    | `AnganSamadder/PayBack`           |
| **Branch**                        | `main`                            |
| **Start Condition**               | **Branch Changes** → `main`       |
| **Scheme**                        | `PayBack`                         |
| **Actions** → **Add Action**      |                                   |
| **Test**                          | iPhone 15 Pro, iOS 18 (or latest) |
| **Build**                         | Debug configuration               |
| **Post-Actions**                  | Notify on failure                 |

**No TestFlight upload for this workflow.**

---

### Workflow 2: Alpha Release (Internal TestFlight)

| Step                              | Setting                     |
| --------------------------------- | --------------------------- |
| Click **+** → **Create Workflow** |                             |
| **Name**                          | `Alpha Release`             |
| **Repository**                    | `AnganSamadder/PayBack`     |
| **Start Condition**               | **Tag Changes** → `alpha-*` |
| **Scheme**                        | `PayBackInternal`           |
| **Actions** → **Add Action**      |                             |
| **Test**                          | iPhone 15 Pro, iOS 18       |
| **Archive**                       | Internal configuration      |
| **Deploy to TestFlight**          | **Internal Testing**        |

**Environment Variables:**
| Name | Value |
|------|-------|
| `CONVEX_DEPLOY_KEY` | `<your-convex-deploy-key>` |

---

### Workflow 3: Beta Release (External TestFlight)

| Step                              | Setting                    |
| --------------------------------- | -------------------------- |
| Click **+** → **Create Workflow** |                            |
| **Name**                          | `Beta Release`             |
| **Repository**                    | `AnganSamadder/PayBack`    |
| **Start Condition**               | **Tag Changes** → `beta-*` |
| **Scheme**                        | `PayBack`                  |
| **Actions** → **Add Action**      |                            |
| **Test**                          | iPhone 15 Pro, iOS 18      |
| **Archive**                       | Release configuration      |
| **Deploy to TestFlight**          | **External Testing**       |

**Environment Variables:**
| Name | Value |
|------|-------|
| `CONVEX_DEPLOY_KEY` | `<your-convex-deploy-key>` |
| `CONVEX_DEPLOY_ON_CI` | `1` |

---

### Workflow 4: Production Release (App Store)

| Step                              | Setting                       |
| --------------------------------- | ----------------------------- |
| Click **+** → **Create Workflow** |                               |
| **Name**                          | `Production Release`          |
| **Repository**                    | `AnganSamadder/PayBack`       |
| **Start Condition**               | **Tag Changes** → `release-*` |
| **Scheme**                        | `PayBack`                     |
| **Actions** → **Add Action**      |                               |
| **Test**                          | iPhone 15 Pro, iOS 18         |
| **Archive**                       | Release configuration         |
| **Deploy to App Store**           | **Release**                   |

**Environment Variables:**
| Name | Value |
|------|-------|
| `CONVEX_DEPLOY_KEY` | `<your-convex-deploy-key>` |
| `CONVEX_DEPLOY_ON_CI` | `1` |

---

## Step 4: Configure TestFlight Groups

1. In App Store Connect → **TestFlight**
2. Create **Internal Group**:
   - Click **+** next to Internal Testing
   - Name it `Internal` or `Alpha Testers`
   - Add your team members
3. Create **External Group**:
   - Click **+** next to External Testing
   - Name it `Beta Testers`
   - Add testers or invite via email

---

## Step 5: Add Environment Variables

In each workflow that needs Convex deploy:

1. Click **Edit Workflow**
2. Scroll to **Environment**
3. Click **+ Add Variable**
4. Add:
   - `CONVEX_DEPLOY_KEY` = your Convex deploy key (mark as **Secret**)
   - `CONVEX_DEPLOY_ON_CI` = `1` (for beta/release workflows)

---

## Step 6: Test the Setup

```bash
# Test Alpha workflow
git tag alpha-0.0.1
git push origin alpha-0.0.1

# Wait for build to complete
# Check Xcode Cloud for build status
# Verify build appears in TestFlight Internal Testing
```

---

## Summary Table

| Workflow           | Trigger         | Scheme          | Config   | DB   | Destination         |
| ------------------ | --------------- | --------------- | -------- | ---- | ------------------- |
| Main CI            | `main` push     | PayBack         | Debug    | Dev  | None                |
| Alpha Release      | `alpha-*` tag   | PayBackInternal | Internal | Dev  | TestFlight Internal |
| Beta Release       | `beta-*` tag    | PayBack         | Release  | Prod | TestFlight External |
| Production Release | `release-*` tag | PayBack         | Release  | Prod | App Store           |

---

## Troubleshooting

### "Scheme not found"

- Open Xcode, go to Product → Scheme → Manage Schemes
- Make sure `PayBack` and `PayBackInternal` are **Shared**
- Commit and push

### "No signing certificate"

- In Xcode Cloud Settings → Signing
- Download certificates or let Xcode Cloud manage them

### "Build fails with entitlements error"

- Check `project.yml` has correct entitlements paths
- Run `bunx xcodegen generate --spec project.yml` locally

### "Wrong Convex DB"

- Verify scheme settings in `project.yml`:
  - PayBackInternal archives with Internal config
  - PayBack archives with Release config
