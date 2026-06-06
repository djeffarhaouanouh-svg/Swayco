-- Dashboard-editable remote config (key/value). Readable by everyone (anon +
-- authed); only the service role / Supabase dashboard can change values. This
-- is the remote kill-switch layer: a feature can be turned off in seconds
-- without shipping an app update.
--
-- First use: the "X people online" badge on Discover. The count is a random
-- number the client picks within [online_min, online_max]; flip
-- online_badge_enabled to '0' in the dashboard to hide it entirely (e.g. if
-- App Review objects to it).
create table if not exists public.app_config (
  key text primary key,
  value text not null,
  updated_at timestamptz not null default now()
);

alter table public.app_config enable row level security;

drop policy if exists "app_config readable by all" on public.app_config;
create policy "app_config readable by all"
  on public.app_config for select using (true);

insert into public.app_config (key, value) values
  ('online_badge_enabled', '1'),
  ('online_min', '40'),
  ('online_max', '180')
on conflict (key) do nothing;
