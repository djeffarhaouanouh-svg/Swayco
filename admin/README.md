# Swayco Admin

Off-site administration dashboard for the Swayco app — built with
Next.js 16 (App Router), Tailwind v4, Recharts and Supabase. Styled to
match the app's current "Midnight" palette (`lib/theme/swayco_theme.dart`
in the main repo) — dark mesh background, glass surfaces, cyan accent.

It reads the `analytics_events` table (populated by the app + backend,
see migration `0017` and `backend/analytics.js`) plus the existing
`profiles` / `friendships` / `messages` / `likes` / `blocked_users` /
`reports` / `incoming_calls` tables, and never writes anything.

## Sections

- **Vue d'ensemble** — headline KPIs, live snapshot, growth trends, top
  countries & languages.
- **Tableau global** — every metric in one flat table, grouped.
- **Live** — calls in progress, users on a call, online users, active
  countries & languages, auto-refresh every 20 s.
- **Social** — friends, requests, conversations that stick, messages.
- **Rétention** — D1 / D7 / D30, DAU / WAU / MAU, stickiness, cohorts.

## Setup

```bash
cd admin
cp env.example .env.local      # then fill in the values
npm install
npm run dev                    # http://localhost:3000
```

### Environment

See `env.example`. You need the Supabase URL + anon key + **service-role
key** (the dashboard reads the RLS-locked analytics table with it).

## Access control

Auth is Supabase Auth against the same project. A user can sign in only
if their `profiles` row has `is_admin = true`:

```sql
update public.profiles set is_admin = true where id = '<your-user-uuid>';
```

The check runs both at login and in `app/(dashboard)/layout.tsx`.

## Deploy

`railway.json` targets Railway. Set the same environment variables in
the Railway project. `proxy.ts` (Next 16's renamed middleware) keeps the
Supabase session fresh.

## Notes / next steps

- Aggregations run in JS over bounded query windows — fine while the
  app is young. Once `analytics_events` gets large, move the heavy
  aggregates (`getRetention`, `getCountries`, …) to SQL views / RPCs.
- The old `live_lobby` waiting-queue table was dropped in migration
  `0025` (the Random Call lobby was removed from the app) — the Live
  page no longer reads it. "Live" now means: open calls (`call_started`
  without a matching `call_ended`), online users (`profiles.last_seen`
  heartbeat), and ringing calls (`incoming_calls`).
- Monétisation was removed with this rebuild — prices/tiers were about
  to change; re-add once the new pricing is final.
