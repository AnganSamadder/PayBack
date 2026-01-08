-- Migration to fix Groups and Expenses RLS for Linked Members
-- Date: 2026-01-07
-- Description: Updates RLS policies to allow access to groups and expenses if the authenticated user's
-- linked_member_id (from accounts table) matches a member in the group or expense.

-- 1. Helper Function to get linked_member_id for current user
-- (Optimization to avoid repeated subqueries, though Postgres optimizer is usually smart enough)
-- Actually, using a direct subquery in policy is standard.

-- 2. Drop existing restrictive policies
drop policy if exists "groups_owner_rw" on groups;
drop policy if exists "expenses_owner_rw" on expenses;
drop policy if exists "groups_member_access" on groups; -- in case retry
drop policy if exists "expenses_member_access" on expenses; -- in case retry

-- 3. Groups Policy
-- Allow if:
-- - Owner (account_id or email)
-- - OR User's linked_member_id is in the members JSONB list
create policy "groups_member_access"
  on groups
  for all -- using 'all' to allow read/write? Original was 'all' but effectively owner-only.
          -- Ideally members should only READ? Or can they edit? 
          -- For now, let's keep it 'all' to avoid breaking edit features for members (if allowed later).
          -- But strictly speaking, allowing full WRITE to members is risky?
          -- The app logic controls edits. RLS usually just gatekeeps access.
          -- Let's stick to 'all' to mirror previous "owner_rw" intent, but effectively expanding it.
  using (
    owner_account_id = auth.uid()
    or lower(owner_email) = lower(jwt_email())
    or exists (
      select 1 from accounts a
      where a.id = auth.uid()
      and a.linked_member_id is not null
      and (groups.members @> jsonb_build_array(jsonb_build_object('id', a.linked_member_id)))
    )
  )
  with check (
    owner_account_id = auth.uid()
    or lower(owner_email) = lower(jwt_email())
    or exists (
      select 1 from accounts a
      where a.id = auth.uid()
      and a.linked_member_id is not null
      and (groups.members @> jsonb_build_array(jsonb_build_object('id', a.linked_member_id)))
    )
  );

-- 4. Expenses Policy
-- Allow if:
-- - Owner (account_id or email)
-- - OR User's linked_member_id is participant or payer
create policy "expenses_member_access"
  on expenses
  for all
  using (
    owner_account_id = auth.uid()
    or lower(owner_email) = lower(jwt_email())
    or exists (
      select 1 from accounts a
      where a.id = auth.uid()
      and a.linked_member_id is not null
      and (
        a.linked_member_id = expenses.paid_by_member_id
        or a.linked_member_id = any(expenses.involved_member_ids)
      )
    )
  )
  with check (
    owner_account_id = auth.uid()
    or lower(owner_email) = lower(jwt_email())
    or exists (
      select 1 from accounts a
      where a.id = auth.uid()
      and a.linked_member_id is not null
      and (
        a.linked_member_id = expenses.paid_by_member_id
        or a.linked_member_id = any(expenses.involved_member_ids)
      )
    )
  );
