// Dashboard data layer. Every function reads through the service-role
// client (bypasses RLS) and is defensive: a missing table, an empty
// table, or a query error resolves to a safe zero/empty value so the
// dashboard always renders.
//
// Aggregation note: counts use PostgREST `head: true` (no rows fetched);
// everything else fetches a bounded row window and aggregates in JS.
// That is correct and simple for a young app — once `analytics_events`
// grows large, promote the heavy aggregates to SQL views / RPCs.

import { createSupabaseServiceClient } from "./supabase/service";
import {
  dayKey,
  fmtEur,
  fmtInt,
  fmtMinutes,
  fmtNum,
  fmtPct,
} from "./format";

const DAY_MS = 86_400_000;

/** ISO timestamp `days` days ago (fractional days allowed: 0.25 = 6 h). */
export function sinceISO(days: number): string {
  return new Date(Date.now() - days * DAY_MS).toISOString();
}

type Row = Record<string, unknown>;
// The Supabase query-builder generics are deep; for these dynamic,
// table-name-by-string queries a loose builder type is the pragmatic call.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type QueryFn = (q: any) => any;

async function safeCount(table: string, apply?: QueryFn): Promise<number> {
  try {
    const sb = createSupabaseServiceClient();
    let q = sb.from(table).select("*", { count: "exact", head: true });
    if (apply) q = apply(q);
    const { count, error } = await q;
    return error ? 0 : count ?? 0;
  } catch {
    return 0;
  }
}

async function safeRows(
  table: string,
  columns: string,
  apply?: QueryFn,
): Promise<Row[]> {
  try {
    const sb = createSupabaseServiceClient();
    let q = sb.from(table).select(columns);
    if (apply) q = apply(q);
    const { data, error } = await q;
    return error || !data ? [] : (data as unknown as Row[]);
  } catch {
    return [];
  }
}

function num(v: unknown, def: number): number {
  const n = Number(v);
  return Number.isFinite(n) ? n : def;
}

// ─── series helpers ───────────────────────────────────────────────────────

export type DayPoint = { day: string; value: number };

/** Bucket a list of timestamps into the last `days` daily counts. */
function bucketByDay(timestamps: unknown[], days: number): DayPoint[] {
  const buckets = new Map<string, number>();
  for (let i = days - 1; i >= 0; i--) {
    buckets.set(dayKey(new Date(Date.now() - i * DAY_MS)), 0);
  }
  for (const ts of timestamps) {
    if (typeof ts !== "string") continue;
    const k = dayKey(new Date(ts));
    if (buckets.has(k)) buckets.set(k, (buckets.get(k) ?? 0) + 1);
  }
  return [...buckets.entries()].map(([day, value]) => ({ day, value }));
}

export type Pair = { label: string; value: number };

function topPairs(m: Map<string, number>, limit: number): Pair[] {
  return [...m.entries()]
    .map(([label, value]) => ({ label, value }))
    .sort((a, b) => b.value - a.value)
    .slice(0, limit);
}

function percentile(sorted: number[], p: number): number {
  if (sorted.length === 0) return 0;
  const idx = Math.min(sorted.length - 1, Math.floor(p * sorted.length));
  return sorted[idx];
}

// ─── live ─────────────────────────────────────────────────────────────────

export type LiveSnapshot = {
  liveCalls: number;
  liveUsers: number;
  waitingLobby: number;
  countries: string[];
  languages: string[];
};

/**
 * Best-effort "right now" picture. A call_started with no matching
 * call_ended (by room) inside the last 6 h is treated as still live —
 * so a crashed client that never sent call_ended lingers up to 6 h.
 */
export async function getLiveSnapshot(): Promise<LiveSnapshot> {
  const [starts, ends, waitingLobby] = await Promise.all([
    safeRows(
      "analytics_events",
      "room_name, user_id, lang_from, lang_to, country",
      (q) =>
        q
          .eq("event", "call_started")
          .gte("created_at", sinceISO(0.25))
          .limit(3000),
    ),
    safeRows("analytics_events", "room_name", (q) =>
      q.eq("event", "call_ended").gte("created_at", sinceISO(0.25)).limit(3000),
    ),
    safeCount("live_lobby", (q) => q.eq("status", "waiting")),
  ]);

  const endedRooms = new Set(
    ends.map((e) => e.room_name).filter(Boolean) as string[],
  );
  const open = starts.filter(
    (s) => s.room_name && !endedRooms.has(s.room_name as string),
  );

  const countries = new Set<string>();
  const languages = new Set<string>();
  for (const s of open) {
    if (s.country) countries.add(s.country as string);
    if (s.lang_from) languages.add(s.lang_from as string);
    if (s.lang_to) languages.add(s.lang_to as string);
  }

  return {
    liveCalls: new Set(open.map((s) => s.room_name)).size,
    liveUsers: open.length,
    waitingLobby,
    countries: [...countries],
    languages: [...languages],
  };
}

// ─── overview ─────────────────────────────────────────────────────────────

export type Overview = {
  totalUsers: number;
  newUsers24h: number;
  newUsers7d: number;
  calls24h: number;
  sessions24h: number;
  live: LiveSnapshot;
};

export async function getOverview(): Promise<Overview> {
  const [totalUsers, newUsers24h, newUsers7d, calls24h, sessions24h, live] =
    await Promise.all([
      safeCount("profiles"),
      safeCount("profiles", (q) => q.gte("created_at", sinceISO(1))),
      safeCount("profiles", (q) => q.gte("created_at", sinceISO(7))),
      safeCount("analytics_events", (q) =>
        q.eq("event", "call_started").gte("created_at", sinceISO(1)),
      ),
      safeCount("analytics_events", (q) =>
        q.eq("event", "app_open").gte("created_at", sinceISO(1)),
      ),
      getLiveSnapshot(),
    ]);
  return { totalUsers, newUsers24h, newUsers7d, calls24h, sessions24h, live };
}

export async function getCallsSeries(days = 14): Promise<DayPoint[]> {
  const rows = await safeRows("analytics_events", "created_at", (q) =>
    q
      .eq("event", "call_started")
      .gte("created_at", sinceISO(days))
      .limit(100000),
  );
  return bucketByDay(
    rows.map((r) => r.created_at),
    days,
  );
}

export async function getNewUsersSeries(days = 14): Promise<DayPoint[]> {
  const rows = await safeRows("profiles", "created_at", (q) =>
    q.gte("created_at", sinceISO(days)).limit(100000),
  );
  return bucketByDay(
    rows.map((r) => r.created_at),
    days,
  );
}

// ─── languages & countries ────────────────────────────────────────────────

export async function getLanguagePairs(days = 30): Promise<Pair[]> {
  const rows = await safeRows("analytics_events", "lang_from, lang_to", (q) =>
    q
      .eq("event", "call_ended")
      .gte("created_at", sinceISO(days))
      .limit(50000),
  );
  const m = new Map<string, number>();
  for (const r of rows) {
    if (!r.lang_from && !r.lang_to) continue;
    const label = `${r.lang_from ?? "?"} → ${r.lang_to ?? "?"}`;
    m.set(label, (m.get(label) ?? 0) + 1);
  }
  return topPairs(m, 12);
}

export type CountryStat = { code: string; users: number };

export async function getCountries(days = 30): Promise<CountryStat[]> {
  const rows = await safeRows(
    "analytics_events",
    "country, user_id, session_id",
    (q) =>
      q
        .not("country", "is", null)
        .gte("created_at", sinceISO(days))
        .limit(100000),
  );
  // Distinct user (or session, for guests) per country.
  const m = new Map<string, Set<string>>();
  for (const r of rows) {
    const code = r.country as string | null;
    if (!code) continue;
    const key = (r.user_id as string) ?? (r.session_id as string) ?? "anon";
    if (!m.has(code)) m.set(code, new Set());
    m.get(code)!.add(key);
  }
  return [...m.entries()]
    .map(([code, set]) => ({ code, users: set.size }))
    .sort((a, b) => b.users - a.users);
}

// ─── translation ──────────────────────────────────────────────────────────

export type TranslationStats = {
  avgLatency: number;
  p95Latency: number;
  latencySamples: number;
  sessions: number;
  errors: number;
  sessionFails: number;
  callFails: number;
  textTranslations: number;
  errorRate: number;
};

export async function getTranslationStats(days = 7): Promise<TranslationStats> {
  const [latRows, sessions, errors, sessionFails, callFails, textTranslations] =
    await Promise.all([
      safeRows("analytics_events", "latency_ms", (q) =>
        q
          .eq("event", "translation_connected")
          .not("latency_ms", "is", null)
          .gte("created_at", sinceISO(days))
          .limit(50000),
      ),
      safeCount("analytics_events", (q) =>
        q.eq("event", "translation_session").gte("created_at", sinceISO(days)),
      ),
      safeCount("analytics_events", (q) =>
        q.eq("event", "translation_error").gte("created_at", sinceISO(days)),
      ),
      safeCount("analytics_events", (q) =>
        q
          .eq("event", "translation_session_failed")
          .gte("created_at", sinceISO(days)),
      ),
      safeCount("analytics_events", (q) =>
        q.eq("event", "call_failed").gte("created_at", sinceISO(days)),
      ),
      safeCount("analytics_events", (q) =>
        q.eq("event", "text_translation").gte("created_at", sinceISO(days)),
      ),
    ]);

  const lat = latRows
    .map((r) => Number(r.latency_ms))
    .filter((n) => Number.isFinite(n) && n > 0)
    .sort((a, b) => a - b);
  const avgLatency = lat.length
    ? Math.round(lat.reduce((a, b) => a + b, 0) / lat.length)
    : 0;
  const totalErr = errors + sessionFails;
  const totalAttempts = sessions + sessionFails;

  return {
    avgLatency,
    p95Latency: Math.round(percentile(lat, 0.95)),
    latencySamples: lat.length,
    sessions,
    errors,
    sessionFails,
    callFails,
    textTranslations,
    errorRate: totalAttempts > 0 ? totalErr / totalAttempts : 0,
  };
}

export async function getLatencySeries(days = 14): Promise<DayPoint[]> {
  const rows = await safeRows(
    "analytics_events",
    "created_at, latency_ms",
    (q) =>
      q
        .eq("event", "translation_connected")
        .not("latency_ms", "is", null)
        .gte("created_at", sinceISO(days))
        .limit(100000),
  );
  // Daily average latency.
  const sum = new Map<string, number>();
  const cnt = new Map<string, number>();
  for (let i = days - 1; i >= 0; i--) {
    const k = dayKey(new Date(Date.now() - i * DAY_MS));
    sum.set(k, 0);
    cnt.set(k, 0);
  }
  for (const r of rows) {
    if (typeof r.created_at !== "string") continue;
    const k = dayKey(new Date(r.created_at));
    if (!sum.has(k)) continue;
    sum.set(k, (sum.get(k) ?? 0) + Number(r.latency_ms || 0));
    cnt.set(k, (cnt.get(k) ?? 0) + 1);
  }
  return [...sum.entries()].map(([day, total]) => ({
    day,
    value: cnt.get(day) ? Math.round(total / (cnt.get(day) as number)) : 0,
  }));
}

// ─── social ───────────────────────────────────────────────────────────────

export type SocialStats = {
  friendsTotal: number;
  friendsNew: number;
  pendingRequests: number;
  conversationsActive: number;
  messages: number;
  recurringUsers: number;
  recurringRate: number;
  /** Conversations with messages on ≥ 2 distinct days. */
  repeatConversations: number;
  /** repeatConversations / conversationsActive. */
  repeatConversationRate: number;
};

export async function getSocial(days = 30): Promise<SocialStats> {
  const [friendsTotal, friendsNew, pendingRequests, msgs, appOpens] =
    await Promise.all([
      safeCount("friendships", (q) => q.eq("status", "accepted")),
      safeCount("friendships", (q) =>
        q.eq("status", "accepted").gte("responded_at", sinceISO(days)),
      ),
      safeCount("friendships", (q) => q.eq("status", "pending")),
      safeRows("messages", "conversation_id, created_at", (q) =>
        q.gte("created_at", sinceISO(days)).limit(50000),
      ),
      safeRows("analytics_events", "user_id, created_at", (q) =>
        q
          .eq("event", "app_open")
          .not("user_id", "is", null)
          .gte("created_at", sinceISO(days))
          .limit(100000),
      ),
    ]);

  const conversations = new Set(
    msgs.map((m) => m.conversation_id).filter(Boolean),
  );

  // "Revient parler à la même personne": a conversation carrying messages
  // on ≥ 2 distinct days means at least one side came back to that person
  // — a relationship that stuck, not a one-off. The GOLD engagement signal.
  const convDays = new Map<string, Set<string>>();
  for (const m of msgs) {
    if (
      typeof m.conversation_id !== "string" ||
      typeof m.created_at !== "string"
    ) {
      continue;
    }
    if (!convDays.has(m.conversation_id)) {
      convDays.set(m.conversation_id, new Set());
    }
    convDays.get(m.conversation_id)!.add(dayKey(new Date(m.created_at)));
  }
  let repeatConversations = 0;
  for (const [, dset] of convDays) if (dset.size >= 2) repeatConversations++;

  // Recurring = a real user who opened the app on ≥ 2 distinct days.
  const userDays = new Map<string, Set<string>>();
  for (const r of appOpens) {
    if (typeof r.user_id !== "string" || typeof r.created_at !== "string") {
      continue;
    }
    if (!userDays.has(r.user_id)) userDays.set(r.user_id, new Set());
    userDays.get(r.user_id)!.add(dayKey(new Date(r.created_at)));
  }
  let recurring = 0;
  for (const [, dset] of userDays) if (dset.size >= 2) recurring++;

  return {
    friendsTotal,
    friendsNew,
    pendingRequests,
    conversationsActive: conversations.size,
    messages: msgs.length,
    recurringUsers: recurring,
    recurringRate: userDays.size > 0 ? recurring / userDays.size : 0,
    repeatConversations,
    repeatConversationRate:
      conversations.size > 0 ? repeatConversations / conversations.size : 0,
  };
}

// ─── retention ────────────────────────────────────────────────────────────

export type CohortRow = {
  cohort: string; // YYYY-MM-DD
  size: number;
  d1: number | null; // null = not yet measurable
  d7: number | null;
  d30: number | null;
};

export type Retention = {
  cohorts: CohortRow[];
  overall: { d1: number; d7: number; d30: number };
  lostUsers: number;
  dau: DayPoint[];
};

/**
 * Classic day-N retention: a user counts toward DN if they opened the
 * app on exactly `firstSeen + N`. A cohort's DN is null until that day
 * has actually passed for the whole cohort.
 */
export async function getRetention(days = 30): Promise<Retention> {
  // Wide enough window that D30 of the oldest shown cohort still has data.
  const rows = await safeRows("analytics_events", "user_id, created_at", (q) =>
    q
      .eq("event", "app_open")
      .not("user_id", "is", null)
      .gte("created_at", sinceISO(days + 32))
      .limit(200000),
  );

  const today = Math.floor(Date.now() / DAY_MS);
  // user → set of day indices.
  const userDays = new Map<string, Set<number>>();
  for (const r of rows) {
    if (typeof r.user_id !== "string" || typeof r.created_at !== "string") {
      continue;
    }
    const di = Math.floor(new Date(r.created_at).getTime() / DAY_MS);
    if (!userDays.has(r.user_id)) userDays.set(r.user_id, new Set());
    userDays.get(r.user_id)!.add(di);
  }

  type Acc = { size: number; d1: number; d7: number; d30: number };
  const cohorts = new Map<number, Acc>();
  let lostUsers = 0;
  for (const [, dset] of userDays) {
    const sorted = [...dset].sort((a, b) => a - b);
    const first = sorted[0];
    const last = sorted[sorted.length - 1];
    if (last < today - 30) lostUsers++;
    if (!cohorts.has(first)) {
      cohorts.set(first, { size: 0, d1: 0, d7: 0, d30: 0 });
    }
    const c = cohorts.get(first)!;
    c.size++;
    if (dset.has(first + 1)) c.d1++;
    if (dset.has(first + 7)) c.d7++;
    if (dset.has(first + 30)) c.d30++;
  }

  const cohortRows: CohortRow[] = [...cohorts.entries()]
    .sort((a, b) => b[0] - a[0])
    .slice(0, 14)
    .map(([dayIdx, c]) => ({
      cohort: dayKey(new Date(dayIdx * DAY_MS)),
      size: c.size,
      d1: today >= dayIdx + 1 ? c.d1 / c.size : null,
      d7: today >= dayIdx + 7 ? c.d7 / c.size : null,
      d30: today >= dayIdx + 30 ? c.d30 / c.size : null,
    }));

  // Overall = pooled across cohorts mature enough for each milestone.
  const overall = { d1: 0, d7: 0, d30: 0 };
  for (const key of ["d1", "d7", "d30"] as const) {
    const n = key === "d1" ? 1 : key === "d7" ? 7 : 30;
    let ret = 0;
    let size = 0;
    for (const [dayIdx, c] of cohorts) {
      if (today < dayIdx + n) continue;
      ret += c[key];
      size += c.size;
    }
    overall[key] = size > 0 ? ret / size : 0;
  }

  // DAU series for the requested window.
  const dauSets = new Map<string, Set<string>>();
  for (let i = days - 1; i >= 0; i--) {
    dauSets.set(dayKey(new Date(Date.now() - i * DAY_MS)), new Set());
  }
  for (const r of rows) {
    if (typeof r.user_id !== "string" || typeof r.created_at !== "string") {
      continue;
    }
    const k = dayKey(new Date(r.created_at));
    dauSets.get(k)?.add(r.user_id);
  }
  const dau: DayPoint[] = [...dauSets.entries()].map(([day, set]) => ({
    day,
    value: set.size,
  }));

  return { cohorts: cohortRows, overall, lostUsers, dau };
}

// ─── referrals ────────────────────────────────────────────────────────────

export type ReferralStats = {
  /** Profiles whose `referred_by` is non-null = filleuls captured by
   *  the `attribute_referral` RPC since the system shipped. */
  totalAttributed: number;
  /** Number of distinct referrers that have at least one filleul. */
  activeReferrers: number;
  /** Sum of bonus tranches already paid (1 tranche = 3 filleuls = 30 min
   *  of credits credited to a referrer). */
  bonusTranchesPaid: number;
  /** Bonus tranches × 30 min = total free minutes given out via referrals. */
  bonusMinutesGranted: number;
};

/**
 * Snapshot of the "Invite 3 amis = +30 min" growth loop. Reads the
 * referral columns added by migration 0028 — falls back to zeros when
 * the columns aren't there yet (e.g. on a stale DB), so the dashboard
 * still renders during a rolling deploy.
 */
export async function getReferralStats(): Promise<ReferralStats> {
  const [attributed, refRows] = await Promise.all([
    safeCount("profiles", (q) => q.not("referred_by", "is", null)),
    safeRows("profiles", "referral_credits_granted", (q) =>
      q.gt("referral_credits_granted", 0).limit(100000),
    ),
  ]);

  const activeReferrers = refRows.length;
  let tranches = 0;
  for (const r of refRows) {
    // referral_credits_granted is stored in "filleuls counted" (multiples
    // of 3 = paid tranches). One tranche = 30 min.
    const counted = num(r.referral_credits_granted, 0);
    tranches += Math.floor(counted / 3);
  }

  return {
    totalAttributed: attributed,
    activeReferrers,
    bonusTranchesPaid: tranches,
    bonusMinutesGranted: tranches * 30,
  };
}

// ─── consolidated single table ──────────────────────────────────────────────

export type MetricGroup =
  | "Croissance"
  | "Rétention"
  | "Social"
  | "Appels"
  | "Profil"
  | "Monétisation";

/** One line of the "Tableau global" page — already formatted for display. */
export type MetricRow = {
  group: MetricGroup;
  label: string;
  /** Total / valeur globale. */
  total: string;
  /** Moyenne par utilisateur — "—" quand la notion n'a pas de sens. */
  perUser: string;
  /** Contexte (fenêtre temporelle, définition) — "" si rien à dire. */
  detail: string;
};

/**
 * Everything the app tracks, on ONE table, one row per metric. Reuses
 * the per-section aggregates (overview / retention / social / costs /
 * referrals) and adds the per-user averages no other page computes:
 * likes, voice messages, calls, photos, interests and profile
 * completion.
 *
 * Per-user averages divide an ALL-TIME total by the total user count (a
 * lifetime average), while activity metrics (DAU, retention, new users)
 * keep their natural time window — each row's `detail` says which. Every
 * underlying query is defensive (safeCount / safeRows resolve to 0 / []),
 * so a table that doesn't exist yet just shows 0 instead of crashing.
 */
export async function getGlobalTable(): Promise<MetricRow[]> {
  const [
    overview,
    retention,
    social,
    costs,
    referrals,
    newUsers30d,
    friendshipsTotal,
    messagesTotal,
    voiceMessages,
    likeRows,
    callsTotal,
    callRows,
    blocks,
    reports,
    profileRows,
  ] = await Promise.all([
    getOverview(),
    getRetention(30),
    getSocial(30),
    getCosts(30),
    getReferralStats(),
    safeCount("profiles", (q) => q.gte("created_at", sinceISO(30))),
    safeCount("friendships"),
    safeCount("messages"),
    safeCount("messages", (q) =>
      q.not("audio_url", "is", null).neq("audio_url", ""),
    ),
    safeRows("likes", "liker, liked", (q) => q.limit(200000)),
    safeCount("incoming_calls"),
    safeRows("incoming_calls", "duration_seconds", (q) =>
      q.not("duration_seconds", "is", null).limit(200000),
    ),
    safeCount("blocked_users"),
    safeCount("reports"),
    safeRows("profiles", "photos, interests, missions_done", (q) =>
      q.limit(200000),
    ),
  ]);

  const users = overview.totalUsers || 0;
  const per = (n: number) => (users > 0 ? n / users : 0);

  // Likes: distinct (liker → liked) pairs, so liking three photos of the
  // same person counts once toward "people liked".
  const likePairs = new Set<string>();
  for (const r of likeRows) {
    if (r.liker && r.liked) likePairs.add(`${r.liker}→${r.liked}`);
  }

  // Calls: average + cumulative duration over ended calls only.
  let callSecs = 0;
  let endedCalls = 0;
  for (const c of callRows) {
    const s = Number(c.duration_seconds);
    if (Number.isFinite(s) && s > 0) {
      callSecs += s;
      endedCalls++;
    }
  }
  const avgCallMin = endedCalls > 0 ? callSecs / endedCalls / 60 : 0;

  // Profiles: photos, interests, and mission-based completion. The app's
  // onboarding has 6 missions (see lib/services/missions_service.dart);
  // completion = filled missions / 6, averaged across all profiles.
  const MISSIONS = 6;
  let photoTotal = 0;
  let withPhoto = 0;
  let interestTotal = 0;
  let missionTotal = 0;
  for (const p of profileRows) {
    const photos = Array.isArray(p.photos) ? p.photos : [];
    const interests = Array.isArray(p.interests) ? p.interests : [];
    const missions = Array.isArray(p.missions_done) ? p.missions_done : [];
    photoTotal += photos.length;
    if (photos.length > 0) withPhoto++;
    interestTotal += interests.length;
    missionTotal += Math.min(missions.length, MISSIONS);
  }
  const seen = profileRows.length || 0;
  const avgPhotos = seen > 0 ? photoTotal / seen : 0;
  const avgInterests = seen > 0 ? interestTotal / seen : 0;
  const avgMissions = seen > 0 ? missionTotal / seen : 0;
  const withPhotoRate = seen > 0 ? withPhoto / seen : 0;

  const todayDau = retention.dau.length
    ? retention.dau[retention.dau.length - 1].value
    : 0;

  return [
    // ─── Croissance & activité ───
    {
      group: "Croissance",
      label: "Nombre d'utilisateurs",
      total: fmtInt(users),
      perUser: "—",
      detail: "total cumulé",
    },
    {
      group: "Croissance",
      label: "Nouveaux utilisateurs",
      total: fmtInt(newUsers30d),
      perUser: "—",
      detail: `${fmtInt(overview.newUsers24h)} (24 h) · ${fmtInt(
        overview.newUsers7d,
      )} (7 j) · ${fmtInt(newUsers30d)} (30 j)`,
    },
    {
      group: "Croissance",
      label: "Actifs aujourd'hui (DAU)",
      total: fmtInt(todayDau),
      perUser: "—",
      detail: "ouvertures d'app, jour J",
    },
    {
      group: "Croissance",
      label: "Utilisateurs récurrents",
      total: fmtInt(social.recurringUsers),
      perUser: fmtPct(social.recurringRate),
      detail: "≥ 2 jours actifs (30 j)",
    },
    {
      group: "Croissance",
      label: "Utilisateurs perdus",
      total: fmtInt(retention.lostUsers),
      perUser: "—",
      detail: "aucune ouverture depuis 30 j",
    },

    // ─── Rétention ───
    {
      group: "Rétention",
      label: "Rétention J1",
      total: fmtPct(retention.overall.d1),
      perUser: "—",
      detail: "reviennent le lendemain",
    },
    {
      group: "Rétention",
      label: "Rétention J7",
      total: fmtPct(retention.overall.d7),
      perUser: "—",
      detail: "reviennent à 7 jours",
    },
    {
      group: "Rétention",
      label: "Rétention J30",
      total: fmtPct(retention.overall.d30),
      perUser: "—",
      detail: "reviennent à 30 jours",
    },

    // ─── Social & engagement ───
    {
      group: "Social",
      label: "Amis (acceptés)",
      total: fmtInt(social.friendsTotal),
      perUser: fmtNum(per(social.friendsTotal * 2)),
      detail: "moyenne d'amis par utilisateur",
    },
    {
      group: "Social",
      label: "Demandes d'ami envoyées",
      total: fmtInt(friendshipsTotal),
      perUser: fmtNum(per(friendshipsTotal)),
      detail: "acceptées + en attente + refusées",
    },
    {
      group: "Social",
      label: "Messages envoyés",
      total: fmtInt(messagesTotal),
      perUser: fmtNum(per(messagesTotal)),
      detail: "texte, image et vocal",
    },
    {
      group: "Social",
      label: "Messages vocaux",
      total: fmtInt(voiceMessages),
      perUser: fmtNum(per(voiceMessages)),
      detail: "",
    },
    {
      group: "Social",
      label: "Likes",
      total: fmtInt(likePairs.size),
      perUser: fmtNum(per(likePairs.size)),
      detail: "personnes likées distinctes",
    },
    {
      group: "Social",
      label: "Conversations actives",
      total: fmtInt(social.conversationsActive),
      perUser: "—",
      detail: "30 j",
    },
    {
      group: "Social",
      label: "Blocages",
      total: fmtInt(blocks),
      perUser: fmtNum(per(blocks)),
      detail: "",
    },
    {
      group: "Social",
      label: "Signalements",
      total: fmtInt(reports),
      perUser: "—",
      detail: "total cumulé",
    },

    // ─── Appels ───
    {
      group: "Appels",
      label: "Appels passés",
      total: fmtInt(callsTotal),
      perUser: fmtNum(per(callsTotal)),
      detail: "appels entre amis (hors invités)",
    },
    {
      group: "Appels",
      label: "Durée moyenne d'un appel",
      total: fmtMinutes(avgCallMin),
      perUser: "—",
      detail: `${fmtInt(endedCalls)} appels terminés`,
    },
    {
      group: "Appels",
      label: "Minutes d'appel cumulées",
      total: fmtMinutes(callSecs / 60),
      perUser: `${fmtNum(per(callSecs / 60))} min`,
      detail: "",
    },

    // ─── Profil ───
    {
      group: "Profil",
      label: "Complétion de profil",
      total: fmtPct(avgMissions / MISSIONS),
      perUser: `${fmtNum(avgMissions)} / ${MISSIONS}`,
      detail: "missions d'onboarding remplies",
    },
    {
      group: "Profil",
      label: "Photos",
      total: fmtInt(photoTotal),
      perUser: fmtNum(avgPhotos),
      detail: `${fmtPct(withPhotoRate)} ont ≥ 1 photo`,
    },
    {
      group: "Profil",
      label: "Centres d'intérêt",
      total: "—",
      perUser: fmtNum(avgInterests),
      detail: "tags choisis par utilisateur",
    },

    // ─── Monétisation ───
    {
      group: "Monétisation",
      label: "Abonnés Plus",
      total: fmtInt(costs.plusCount),
      perUser: "—",
      detail: "7,97 €/mois",
    },
    {
      group: "Monétisation",
      label: "Abonnés Ultra+",
      total: fmtInt(costs.ultraPlusCount),
      perUser: "—",
      detail: "15,97 €/mois",
    },
    {
      group: "Monétisation",
      label: "MRR",
      total: fmtEur(costs.mrrEur),
      perUser: "—",
      detail: "revenu mensuel récurrent",
    },
    {
      group: "Monétisation",
      label: "Filleuls (parrainage)",
      total: fmtInt(referrals.totalAttributed),
      perUser: "—",
      detail: `${fmtInt(referrals.activeReferrers)} parrains actifs`,
    },
  ];
}

// ─── engagement par surface ─────────────────────────────────────────────────

export type SurfaceBreakdown = {
  /** Total events of this kind in the window. */
  total: number;
  /** Per-source counts, sorted desc. */
  bySource: Pair[];
};

export type SurfaceEngagement = {
  windowDays: number;
  messages: SurfaceBreakdown;
  messagesByType: SurfaceBreakdown;
  friendRequests: SurfaceBreakdown;
  likes: SurfaceBreakdown;
  screenViews: SurfaceBreakdown;
};

/** Count rows by a string field inside `props`, sorted desc. */
function countByProp(rows: Row[], field: string): Pair[] {
  const m = new Map<string, number>();
  for (const r of rows) {
    const p = (r.props as Record<string, unknown> | null) ?? {};
    const v = p[field];
    const key = typeof v === "string" && v ? v : "inconnu";
    m.set(key, (m.get(key) ?? 0) + 1);
  }
  return [...m.entries()]
    .map(([label, value]) => ({ label, value }))
    .sort((a, b) => b.value - a.value);
}

/**
 * WHERE engagement happens. Reads the surface-tagged events the app now
 * emits — `message_sent`, `friend_request_sent`, `like_sent`,
 * `screen_view` — and breaks each down by its `source` (or `screen` /
 * `type`) prop. These events ship from the app's action sites (see
 * lib/screens/*), so the numbers only start the day a build carrying the
 * instrumentation is live and used — older history has no surface tag.
 */
export async function getSurfaceEngagement(
  days = 30,
): Promise<SurfaceEngagement> {
  const [msgRows, frRows, likeRows, svRows] = await Promise.all([
    safeRows("analytics_events", "props", (q) =>
      q
        .eq("event", "message_sent")
        .gte("created_at", sinceISO(days))
        .limit(200000),
    ),
    safeRows("analytics_events", "props", (q) =>
      q
        .eq("event", "friend_request_sent")
        .gte("created_at", sinceISO(days))
        .limit(200000),
    ),
    safeRows("analytics_events", "props", (q) =>
      q.eq("event", "like_sent").gte("created_at", sinceISO(days)).limit(200000),
    ),
    safeRows("analytics_events", "props", (q) =>
      q
        .eq("event", "screen_view")
        .gte("created_at", sinceISO(days))
        .limit(200000),
    ),
  ]);

  return {
    windowDays: days,
    messages: {
      total: msgRows.length,
      bySource: countByProp(msgRows, "source"),
    },
    messagesByType: {
      total: msgRows.length,
      bySource: countByProp(msgRows, "type"),
    },
    friendRequests: {
      total: frRows.length,
      bySource: countByProp(frRows, "source"),
    },
    likes: {
      total: likeRows.length,
      bySource: countByProp(likeRows, "source"),
    },
    screenViews: {
      total: svRows.length,
      bySource: countByProp(svRows, "screen"),
    },
  };
}

// ─── monetisation ─────────────────────────────────────────────────────────

export type CostBreakdown = {
  callMinutes: number;
  /** Minutes the OpenAI translation pipeline was actually live. */
  translationMinutes: number;
  textTokens: number;
  costRealtimeUsd: number;
  costLivekitUsd: number;
  costTextUsd: number;
  costTotalEur: number;
  /** Paying subscribers on the entry tier (€7,97 — was "pro"). */
  plusCount: number;
  /** Paying subscribers on the top tier (€15,97 — was "ultra"). */
  ultraPlusCount: number;
  freeCount: number;
  mrrEur: number;
  marginEur: number;
  ratesConfigured: boolean;
  windowDays: number;
};

/**
 * Costs are derived from usage × per-unit rates pulled from env vars —
 * deliberately NOT hardcoded. Set them in admin/.env.local from the
 * current OpenAI / LiveKit pricing pages. Until then the rates are 0
 * and the cost panels show a "configure the rates" hint.
 */
export async function getCosts(days = 30): Promise<CostBreakdown> {
  // Defaults reflect public pricing as of 2026-05 — see admin/env.example
  // for the source links. Override via .env.local when rates change.
  const rateRealtime = num(process.env.COST_REALTIME_USD_PER_MIN, 0.10);
  const rateLivekit = num(process.env.COST_LIVEKIT_USD_PER_MIN, 0.0005);
  const rateText = num(process.env.COST_TEXT_USD_PER_1K_TOKENS, 0.001);
  const usdToEur = num(process.env.USD_TO_EUR, 0.92);
  const pricePlus = num(process.env.PRICE_PLUS_EUR, 7.97);
  const priceUltraPlus = num(process.env.PRICE_ULTRA_PLUS_EUR, 15.97);

  const [calls, texts, plusCount, ultraPlusCount, freeCount] = await Promise.all([
    safeRows("analytics_events", "props", (q) =>
      q.eq("event", "call_ended").gte("created_at", sinceISO(days)).limit(100000),
    ),
    safeRows("analytics_events", "props", (q) =>
      q
        .eq("event", "text_translation")
        .gte("created_at", sinceISO(days))
        .limit(100000),
    ),
    safeCount("profiles", (q) => q.eq("subscription_tier", "plus")),
    safeCount("profiles", (q) => q.eq("subscription_tier", "ultra_plus")),
    safeCount("profiles", (q) => q.eq("subscription_tier", "free")),
  ]);

  let totalMs = 0;
  let translationMs = 0;
  for (const c of calls) {
    const props = c.props as Record<string, unknown> | null;
    const d = props?.duration_ms;
    if (typeof d === "number" && d > 0) totalMs += d;
    const t = props?.translation_ms;
    if (typeof t === "number" && t > 0) translationMs += t;
  }
  const callMinutes = totalMs / 60000;
  // OpenAI Realtime only runs while translation is actually live — not for
  // the whole call. call_ended carries translation_ms for exactly this;
  // calls from before that instrumentation contribute 0 (slight
  // under-count until they roll out of the window).
  const translationMinutes = translationMs / 60000;

  let textTokens = 0;
  for (const t of texts) {
    const p = (t.props as Record<string, unknown> | null) ?? {};
    textTokens += num(p.prompt_tokens, 0) + num(p.completion_tokens, 0);
  }

  // Realtime = translation time only; LiveKit = whole call (it carries
  // every call's audio/video transport regardless of translation).
  const costRealtimeUsd = translationMinutes * rateRealtime;
  const costLivekitUsd = callMinutes * rateLivekit;
  const costTextUsd = (textTokens / 1000) * rateText;
  const costTotalEur =
    (costRealtimeUsd + costLivekitUsd + costTextUsd) * usdToEur;
  const mrrEur = plusCount * pricePlus + ultraPlusCount * priceUltraPlus;

  return {
    callMinutes,
    translationMinutes,
    textTokens,
    costRealtimeUsd,
    costLivekitUsd,
    costTextUsd,
    costTotalEur,
    plusCount,
    ultraPlusCount,
    freeCount,
    mrrEur,
    marginEur: mrrEur - costTotalEur,
    ratesConfigured: rateRealtime > 0 || rateLivekit > 0 || rateText > 0,
    windowDays: days,
  };
}
