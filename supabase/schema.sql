-- Supabase schema for PayBack (Auth + Postgres)
-- Run this in the SQL editor in Supabase.

-- Helpers --------------------------------------------------------------------
create extension if not exists "uuid-ossp";

-- Accounts -------------------------------------------------------------------
create table if not exists accounts (
  id uuid primary key,
  email text not null unique,
  display_name text not null,
  linked_member_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz
);

create table if not exists account_friends (
  account_email text not null,
  member_id uuid not null,
  name text not null,
  nickname text,
  has_linked_account boolean not null default false,
  linked_account_id uuid,
  linked_account_email text,
  updated_at timestamptz not null default now(),
  primary key (account_email, member_id)
);

create index if not exists idx_account_friends_account_email on account_friends (account_email);

-- Groups ---------------------------------------------------------------------
create table if not exists groups (
  id uuid primary key,
  name text not null,
  members jsonb not null, -- [{ "id": uuid, "name": text }]
  owner_email text not null,
  owner_account_id uuid not null,
  is_direct boolean default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_groups_owner_account on groups (owner_account_id);
create index if not exists idx_groups_owner_email on groups (owner_email);

-- Expenses -------------------------------------------------------------------
create table if not exists expenses (
  id uuid primary key,
  group_id uuid not null references groups (id) on delete cascade,
  description text not null,
  date timestamptz not null,
  total_amount double precision not null,
  paid_by_member_id uuid not null,
  involved_member_ids uuid[] not null,
  splits jsonb not null, -- [{ "id": uuid, "member_id": uuid, "amount": double, "is_settled": bool }]
  is_settled boolean not null default false,
  owner_email text not null,
  owner_account_id uuid not null,
  participant_member_ids uuid[] not null,
  participants jsonb not null, -- [{ "member_id": uuid, "name": text, "linked_account_id": uuid?, "linked_account_email": text? }]
  linked_participants jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  is_payback_generated_mock_data boolean
);

create index if not exists idx_expenses_owner_account on expenses (owner_account_id);
create index if not exists idx_expenses_owner_email on expenses (owner_email);
create index if not exists idx_expenses_group_id on expenses (group_id);

-- Link requests --------------------------------------------------------------
create table if not exists link_requests (
  id uuid primary key,
  requester_id uuid not null,
  requester_email text not null,
  requester_name text not null,
  recipient_email text not null,
  target_member_id uuid not null,
  target_member_name text not null,
  created_at timestamptz not null default now(),
  status text not null,
  expires_at timestamptz not null,
  rejected_at timestamptz
);

create index if not exists idx_link_requests_recipient on link_requests (recipient_email);
create index if not exists idx_link_requests_requester on link_requests (requester_id);

-- Invite tokens --------------------------------------------------------------
create table if not exists invite_tokens (
  id uuid primary key,
  creator_id uuid not null,
  creator_email text not null,
  target_member_id uuid not null,
  target_member_name text not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  claimed_by uuid,
  claimed_at timestamptz
);

create index if not exists idx_invite_tokens_creator on invite_tokens (creator_id);
create index if not exists idx_invite_tokens_claimed_by on invite_tokens (claimed_by);

-- Row Level Security (simple owner-based checks) -----------------------------
alter table accounts enable row level security;
alter table account_friends enable row level security;
alter table groups enable row level security;
alter table expenses enable row level security;
alter table link_requests enable row level security;
alter table invite_tokens enable row level security;

-- Drop existing policies to allow re-running this script safely
drop policy if exists "accounts_owner_rw" on accounts;
drop policy if exists "account_friends_owner_rw" on account_friends;
drop policy if exists "groups_owner_rw" on groups;
drop policy if exists "expenses_owner_rw" on expenses;
drop policy if exists "link_requests_read" on link_requests;
drop policy if exists "link_requests_write" on link_requests;
drop policy if exists "invite_tokens_read" on invite_tokens;
drop policy if exists "invite_tokens_write" on invite_tokens;

-- Helper to fetch the caller's email from JWT
create or replace function public.jwt_email() returns text language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email',
    ''
  );
$$;

-- Accounts: only owner can read/write their own row
create policy "accounts_owner_rw"
  on accounts
  for all
  using (id = auth.uid())
  with check (id = auth.uid());

-- Account friends: scoped by owning email
create policy "account_friends_owner_rw"
  on account_friends
  for all
  using (account_email = lower(jwt_email()))
  with check (account_email = lower(jwt_email()));

-- Groups: owner by account id or email
create policy "groups_owner_rw"
  on groups
  for all
  using (
    owner_account_id = auth.uid()
    or lower(owner_email) = lower(jwt_email())
  )
  with check (
    owner_account_id = auth.uid()
    or lower(owner_email) = lower(jwt_email())
  );

-- Expenses: owner by account id or email
create policy "expenses_owner_rw"
  on expenses
  for all
  using (
    owner_account_id = auth.uid()
    or lower(owner_email) = lower(jwt_email())
  )
  with check (
    owner_account_id = auth.uid()
    or lower(owner_email) = lower(jwt_email())
  );

-- Link requests: requester or recipient can see; only requester writes
create policy "link_requests_read"
  on link_requests
  for select
  using (
    requester_id = auth.uid()
    or lower(recipient_email) = lower(jwt_email())
  );

create policy "link_requests_write"
  on link_requests
  for all
  using (requester_id = auth.uid())
  with check (requester_id = auth.uid());

-- Invite tokens: creator owns write; creator or claimed user can read
create policy "invite_tokens_read"
  on invite_tokens
  for select
  using (
    creator_id = auth.uid()
    or claimed_by = auth.uid()
  );

create policy "invite_tokens_write"
  on invite_tokens
  for all
  using (creator_id = auth.uid())
  with check (creator_id = auth.uid());
