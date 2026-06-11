-- Scheduled calls: a caller proposes a date/time to call a peer; the backend
-- cron (server.js) fires a reminder push to BOTH parties a few minutes before
-- `scheduled_at`, then stamps `reminder_sent_at` so it never double-fires.
-- Mirrors `incoming_calls` (0008): uuid ids referencing auth.users, RLS keyed
-- on auth.uid(). The cron uses the service-role key and bypasses RLS.

create table if not exists public.scheduled_calls (
  id               uuid primary key default gen_random_uuid(),
  caller           uuid not null references auth.users(id) on delete cascade,
  callee           uuid not null references auth.users(id) on delete cascade,
  scheduled_at     timestamptz not null,
  reminder_sent_at timestamptz,
  created_at       timestamptz not null default now()
);

create index if not exists scheduled_calls_callee_idx
  on public.scheduled_calls (callee);
create index if not exists scheduled_calls_caller_idx
  on public.scheduled_calls (caller);
-- Hot path for the reminder cron: only the not-yet-reminded rows, by due time.
create index if not exists scheduled_calls_due_idx
  on public.scheduled_calls (scheduled_at)
  where reminder_sent_at is null;

alter table public.scheduled_calls enable row level security;

-- Caller can insert their own scheduled calls.
drop policy if exists "sched_caller_insert_own" on public.scheduled_calls;
create policy "sched_caller_insert_own"
  on public.scheduled_calls
  for insert
  to authenticated
  with check (auth.uid() = caller);

-- Either party can read upcoming scheduled calls that involve them (so both
-- sides can show the "call planned for …" chip).
drop policy if exists "sched_party_select" on public.scheduled_calls;
create policy "sched_party_select"
  on public.scheduled_calls
  for select
  to authenticated
  using (auth.uid() = caller or auth.uid() = callee);

-- Either party may delete to cancel a planned call.
drop policy if exists "sched_party_delete" on public.scheduled_calls;
create policy "sched_party_delete"
  on public.scheduled_calls
  for delete
  to authenticated
  using (auth.uid() = caller or auth.uid() = callee);
