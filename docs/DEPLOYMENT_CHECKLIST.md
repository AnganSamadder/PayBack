# PayBack Deployment Checklist

This document outlines the steps required to safely deploy the PayBack backend (Convex) and ensure compatibility with the iOS application.

## 1. Pre-Deployment

- [ ] **Run All Tests**: Ensure all backend tests pass.
  ```bash
  bun run test
  ```
- [ ] **Schema Validation**: Verify the schema is valid and there are no linting errors.
  ```bash
  npx convex dev --once
  ```
- [ ] **Verify iOS Compatibility**:
  - Ensure `AppConfig.swift` in the iOS project is pointing to the correct production environment.
  - Check for any breaking changes in API signatures (queries/mutations).
- [ ] **Environment Variables**:
  - Verify `ADMIN_EMAILS` is set for admin access.
  - Verify Clerk authentication secrets are configured in the production dashboard.
- [ ] **Database Backup**: Perform a manual export in the Convex dashboard if significant data migrations are involved.

## 2. Deployment

- [ ] **Standard Deployment**:
  ```bash
  npx convex deploy
  ```
- [ ] **Handling Breaking Schema Changes (e.g., Strong IDs Migration)**:
  1. **Phase 1**: Update `schema.ts` to make new fields `v.optional(...)`.
  2. **Phase 2**: Deploy the optional schema and functions: `npx convex deploy`.
  3. **Phase 3**: Run the migration script:
     ```bash
     npx convex run migrations/backfill_ids:backfillIds
     ```
  4. **Phase 4**: Verify data in the Convex dashboard.
  5. **Phase 5**: Update `schema.ts` to make fields required and redeploy.

## 3. Post-Deployment

- [ ] **Functional Verification**:
  - [ ] Verify user registration and login.
  - [ ] Test group creation and expense addition.
  - [ ] Verify paginated lists (groups and expenses) load correctly.
- [ ] **Admin Check**: Access a secure debug endpoint to verify admin authorization logic.
- [ ] **Monitoring**:
  - [ ] Monitor Convex "Logs" tab for errors.
  - [ ] Check for any spike in "429 Too Many Requests" (Rate Limiting).
  - [ ] Verify Clerk webhooks are being processed successfully.

## 4. Rollback Plan

- [ ] **Function Rollback**: Redeploy the previous stable version from git.
- [ ] **Schema Rollback**:
  - Revert `schema.ts` to the previous state.
  - **Caution**: If data was migrated or deleted, a custom "down" migration may be needed to restore state.
- [ ] **Client Mitigation**: If the iOS app is broken by the deployment, coordinate a hotfix or notify users if service is degraded.
