-- Re-engagement emails (Resend, see backend/email.js): per-user opt-out, a
-- throttle stamp so we email at most once per window, and a secret token that
-- gates the one-click unsubscribe link in every email footer.
--
-- All three are written by the backend service role (bypasses RLS); the client
-- never needs to touch them, so no new policies are required. Existing rows get
-- a unique token because gen_random_uuid() is evaluated per row.

alter table public.profiles
  add column if not exists email_notifications boolean not null default true,
  add column if not exists last_email_at timestamptz,
  add column if not exists email_unsub_token uuid not null default gen_random_uuid();
