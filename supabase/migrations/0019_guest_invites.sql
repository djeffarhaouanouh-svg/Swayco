-- 0019_guest_invites.sql
--
-- Short-code store for guest-call invite links. `POST /invite/create`
-- writes a row keyed by a tiny random `code`; the shared link becomes
-- `…/i/<code>` instead of carrying the room name + 43-char HMAC inline.
-- `GET /invite/resolve` reads it back.
--
-- Only the backend (service role) ever touches this table — RLS is on
-- with no policies, which denies anon / authenticated clients entirely.

create table if not exists public.guest_invites (
  code        text primary key,
  room        text not null,
  exp         bigint not null,
  sig         text not null,
  created_at  timestamptz not null default now()
);

alter table public.guest_invites enable row level security;
