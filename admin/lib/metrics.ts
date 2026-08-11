// Dashboard data layer. Every function reads through the service-role
// client (bypasses RLS) and is defensive: a missing table, an empty
// table, or a query error resolves to a safe zero/empty value so the
// dashboard always renders.
//
// Aggregation note: counts use PostgREST `head: true` (no rows fetched);
// everything else fetches a bounded row window and aggregates in JS.
// That is correct and simple for a young app — once `analytics_events`
// grows large, promote the heavy aggregates to SQL views / RPCs.
//
// Event vocabulary actually emitted by the app (lib/services/analytics.dart
// + its call sites) — nothing else is read here:
//   app_open · screen_view · call_started · call_ended · call_failed
//   message_sent · like_sent · friend_request_sent
// `call_ended` carries props.duration_ms and props.kind.

import { createSupabaseServiceClient } from "./supabase/service";
import { dayKey, fmtInt, fmtMinutes, fmtNum, fmtPct } from "./format";

const DAY_MS = 86_400_000;

/**
 * A user is "en ligne" when their presence heartbeat is fresh.
 * PresenceService bumps `profiles.last_seen` every 90 s while the app is
 * foregrounded, so 5 min tolerates two missed beats without going stale.
 */
const ONLINE_WINDOW_MIN = 5;

/**
 * A `call_started` with no matching `call_ended` for the same room is
 * treated as still live, but only inside this window — a client that
 * crashed without sending `call_ended` would otherwise linger forever.
 */
const LIVE_CALL_WINDOW_H = 6;

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

function str(v: unknown): string | null {
  return typeof v === "string" && v.length > 0 ? v : null;
}

/** Read a numeric field out of an event's jsonb `props`. */
function propNum(props: unknown, key: string): number | null {
  if (!props || typeof props !== "object") return null;
  const v = (props as Record<string, unknown>)[key];
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
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

/** Bucket timestamps into daily counts of DISTINCT keys (DAU-style). */
function bucketDistinctByDay(
  rows: Row[],
  tsField: string,
  keyField: string,
  days: number,
): DayPoint[] {
  const buckets = new Map<string, Set<string>>();
  for (let i = days - 1; i >= 0; i--) {
    buckets.set(dayKey(new Date(Date.now() - i * DAY_MS)), new Set());
  }
  for (const r of rows) {
    const ts = str(r[tsField]);
    const key = str(r[keyField]);
    if (!ts || !key) continue;
    buckets.get(dayKey(new Date(ts)))?.add(key);
  }
  return [...buckets.entries()].map(([day, set]) => ({
    day,
    value: set.size,
  }));
}

export type Pair = { label: string; value: number };

function topPairs(m: Map<string, number>, limit: number): Pair[] {
  return [...m.entries()]
    .map(([label, value]) => ({ label, value }))
    .sort((a, b) => b.value - a.value)
    .slice(0, limit);
}

// ─── live ─────────────────────────────────────────────────────────────────

export type LiveCall = {
  room: string;
  /** Seconds since the first `call_started` seen for this room. */
  ageSec: number;
  participants: number;
  country: string | null;
  langFrom: string | null;
  langTo: string | null;
};

export type LiveSnapshot = {
  /** Rooms with an open call right now. */
  liveCalls: number;
  /** Distinct users inside those rooms. */
  usersInCall: number;
  /** Fresh `profiles.last_seen` heartbeats — the app is open for them. */
  onlineUsers: number;
  /** Rings placed in the last 2 min and not yet cleared. */
  ringing: number;
  calls: LiveCall[];
  countries: Pair[];
  languages: Pair[];
};

/**
 * Best-effort "right now" picture, built from three independent signals
 * so one gap never blanks the page:
 *   * open calls  — analytics `call_started` unmatched by `call_ended`
 *   * online      — `profiles.last_seen` heartbeat (PresenceService)
 *   * ringing     — rows still sitting in `incoming_calls`
 *
 * Note: the old `live_lobby` waiting queue is gone (migration 0025 —
 * the Random Call lobby was removed from the app), so it is not read.
 */
export async function getLiveSnapshot(): Promise<LiveSnapshot> {
  const windowDays = LIVE_CALL_WINDOW_H / 24;
  const [starts, ends, onlineUsers, ringing] = await Promise.all([
    safeRows(
      "analytics_events",
      "room_name, user_id, session_id, lang_from, lang_to, country, created_at",
      (q) =>
        q
          .eq("event", "call_started")
          .gte("created_at", sinceISO(windowDays))
          .limit(5000),
    ),
    safeRows("analytics_events", "room_name", (q) =>
      q
        .eq("event", "call_ended")
        .gte("created_at", sinceISO(windowDays))
        .limit(5000),
    ),
    safeCount("profiles", (q) =>
      q.gte("last_seen", sinceISO(ONLINE_WINDOW_MIN / 1440)),
    ),
    safeCount("incoming_calls", (q) =>
      q.gte("created_at", sinceISO(2 / 1440)),
    ),
  ]);

  const endedRooms = new Set(
    ends.map((e) => str(e.room_name)).filter(Boolean) as string[],
  );

  // Group the still-open starts by room. Two participants each emit their
  // own `call_started` for the same room, so the room is the call and the
  // distinct users inside it are the participants.
  const byRoom = new Map<
    string,
    {
      oldest: number;
      people: Set<string>;
      country: string | null;
      langFrom: string | null;
      langTo: string | null;
    }
  >();
  const countryCounts = new Map<string, number>();
  const langCounts = new Map<string, number>();

  for (const s of starts) {
    const room = str(s.room_name);
    if (!room || endedRooms.has(room)) continue;
    const startedAt = str(s.created_at);
    const t = startedAt ? new Date(startedAt).getTime() : Date.now();
    let entry = byRoom.get(room);
    if (!entry) {
      entry = {
        oldest: t,
        people: new Set(),
        country: null,
        langFrom: null,
        langTo: null,
      };
      byRoom.set(room, entry);
    }
    entry.oldest = Math.min(entry.oldest, t);
    // Guests have no user_id — fall back to the session so they still count.
    const who = str(s.user_id) ?? str(s.session_id);
    if (who) entry.people.add(who);
    entry.country ??= str(s.country);
    entry.langFrom ??= str(s.lang_from);
    entry.langTo ??= str(s.lang_to);
  }

  const now = Date.now();
  const calls: LiveCall[] = [...byRoom.entries()]
    .map(([room, e]) => ({
      room,
      ageSec: Math.max(0, Math.round((now - e.oldest) / 1000)),
      participants: e.people.size,
      country: e.country,
      langFrom: e.langFrom,
      langTo: e.langTo,
    }))
    .sort((a, b) => b.ageSec - a.ageSec);

  for (const c of calls) {
    if (c.country) {
      countryCounts.set(c.country, (countryCounts.get(c.country) ?? 0) + 1);
    }
    for (const l of [c.langFrom, c.langTo]) {
      if (l) langCounts.set(l, (langCounts.get(l) ?? 0) + 1);
    }
  }

  const usersInCall = new Set<string>();
  for (const [, e] of byRoom) for (const p of e.people) usersInCall.add(p);

  return {
    liveCalls: calls.length,
    usersInCall: usersInCall.size,
    onlineUsers,
    ringing,
    calls,
    countries: topPairs(countryCounts, 8),
    languages: topPairs(langCounts, 8),
  };
}

// ─── overview ─────────────────────────────────────────────────────────────

export type Overview = {
  totalUsers: number;
  newUsers24h: number;
  newUsers7d: number;
  dauToday: number;
  calls24h: number;
  messages24h: number;
  live: LiveSnapshot;
};

export async function getOverview(): Promise<Overview> {
  const [
    totalUsers,
    newUsers24h,
    newUsers7d,
    openRows,
    calls24h,
    messages24h,
    live,
  ] = await Promise.all([
    safeCount("profiles"),
    safeCount("profiles", (q) => q.gte("created_at", sinceISO(1))),
    safeCount("profiles", (q) => q.gte("created_at", sinceISO(7))),
    safeRows("analytics_events", "user_id", (q) =>
      q
        .eq("event", "app_open")
        .not("user_id", "is", null)
        .gte("created_at", `${dayKey(new Date())}T00:00:00Z`)
        .limit(100000),
    ),
    safeCount("analytics_events", (q) =>
      q.eq("event", "call_started").gte("created_at", sinceISO(1)),
    ),
    safeCount("messages", (q) => q.gte("created_at", sinceISO(1))),
    getLiveSnapshot(),
  ]);

  const dauToday = new Set(
    openRows.map((r) => str(r.user_id)).filter(Boolean) as string[],
  ).size;

  return {
    totalUsers,
    newUsers24h,
    newUsers7d,
    dauToday,
    calls24h,
    messages24h,
    live,
  };
}

export async function getCallsSeries(days = 14): Promise<DayPoint[]> {
  const rows = await safeRows("analytics_events", "created_at", (q) =>
    q.eq("event", "call_started").gte("created_at", sinceISO(days)).limit(100000),
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

export async function getMessagesSeries(days = 14): Promise<DayPoint[]> {
  const rows = await safeRows("messages", "created_at", (q) =>
    q.gte("created_at", sinceISO(days)).limit(100000),
  );
  return bucketByDay(
    rows.map((r) => r.created_at),
    days,
  );
}

// ─── countries & languages ────────────────────────────────────────────────

export type CountryStat = { code: string; users: number };

/** Distinct users (sessions, for guests) seen per country in the window. */
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
  const m = new Map<string, Set<string>>();
  for (const r of rows) {
    const code = str(r.country);
    if (!code) continue;
    const key = str(r.user_id) ?? str(r.session_id) ?? "anon";
    if (!m.has(code)) m.set(code, new Set());
    m.get(code)!.add(key);
  }
  return [...m.entries()]
    .map(([code, set]) => ({ code, users: set.size }))
    .sort((a, b) => b.users - a.users);
}

/** Languages users actually speak, straight off their profile. */
export async function getLanguages(): Promise<Pair[]> {
  const rows = await safeRows("profiles", "language", (q) =>
    q.not("language", "is", null).limit(100000),
  );
  const m = new Map<string, number>();
  for (const r of rows) {
    const l = str(r.language);
    if (!l) continue;
    m.set(l, (m.get(l) ?? 0) + 1);
  }
  return topPairs(m, 12);
}

// ─── calls ────────────────────────────────────────────────────────────────

export type CallStats = {
  calls: number;
  failed: number;
  failRate: number;
  totalMinutes: number;
  avgMinutes: number;
  /** Calls that lasted over a minute — a real conversation, not a misfire. */
  realCalls: number;
};

export async function getCallStats(days = 30): Promise<CallStats> {
  const [ended, started, failed] = await Promise.all([
    safeRows("analytics_events", "props", (q) =>
      q.eq("event", "call_ended").gte("created_at", sinceISO(days)).limit(50000),
    ),
    safeCount("analytics_events", (q) =>
      q.eq("event", "call_started").gte("created_at", sinceISO(days)),
    ),
    safeCount("analytics_events", (q) =>
      q.eq("event", "call_failed").gte("created_at", sinceISO(days)),
    ),
  ]);

  let totalMs = 0;
  let samples = 0;
  let realCalls = 0;
  for (const r of ended) {
    const ms = propNum(r.props, "duration_ms");
    if (ms === null || ms < 0) continue;
    totalMs += ms;
    samples++;
    if (ms >= 60_000) realCalls++;
  }

  const attempts = started + failed;
  return {
    calls: started,
    failed,
    failRate: attempts > 0 ? failed / attempts : 0,
    totalMinutes: totalMs / 60_000,
    avgMinutes: samples > 0 ? totalMs / samples / 60_000 : 0,
    realCalls,
  };
}

// ─── social ───────────────────────────────────────────────────────────────

export type SocialStats = {
  friendsTotal: number;
  friendsNew: number;
  pendingRequests: number;
  requestsSent: number;
  /** friendsNew / requestsSent — how often an "Ajouter" is accepted. */
  acceptRate: number;
  conversationsActive: number;
  messages: number;
  likes: number;
  blocks: number;
  reports: number;
  recurringUsers: number;
  recurringRate: number;
  /** Conversations with messages on ≥ 2 distinct days. */
  repeatConversations: number;
  /** repeatConversations / conversationsActive. */
  repeatConversationRate: number;
};

export async function getSocial(days = 30): Promise<SocialStats> {
  const [
    friendsTotal,
    friendsNew,
    pendingRequests,
    requestsSent,
    likes,
    blocks,
    reports,
    msgs,
    appOpens,
  ] = await Promise.all([
    safeCount("friendships", (q) => q.eq("status", "accepted")),
    safeCount("friendships", (q) =>
      q.eq("status", "accepted").gte("responded_at", sinceISO(days)),
    ),
    safeCount("friendships", (q) => q.eq("status", "pending")),
    safeCount("friendships", (q) => q.gte("created_at", sinceISO(days))),
    safeCount("likes", (q) => q.gte("created_at", sinceISO(days))),
    safeCount("blocked_users"),
    safeCount("reports", (q) => q.gte("created_at", sinceISO(days))),
    safeRows("messages", "conversation_id, sender, created_at", (q) =>
      q.gte("created_at", sinceISO(days)).limit(100000),
    ),
    safeRows("analytics_events", "user_id, created_at", (q) =>
      q
        .eq("event", "app_open")
        .not("user_id", "is", null)
        .gte("created_at", sinceISO(days))
        .limit(100000),
    ),
  ]);

  // "Revient parler à la même personne": a conversation carrying messages
  // on ≥ 2 distinct days means at least one side came back to that person
  // — a relationship that stuck, not a one-off. The GOLD engagement signal.
  const convDays = new Map<string, Set<string>>();
  for (const m of msgs) {
    const conv = str(m.conversation_id);
    const ts = str(m.created_at);
    if (!conv || !ts) continue;
    if (!convDays.has(conv)) convDays.set(conv, new Set());
    convDays.get(conv)!.add(dayKey(new Date(ts)));
  }
  let repeatConversations = 0;
  for (const [, dset] of convDays) if (dset.size >= 2) repeatConversations++;

  // Recurring = a real user who opened the app on ≥ 2 distinct days.
  const userDays = new Map<string, Set<string>>();
  for (const r of appOpens) {
    const uid = str(r.user_id);
    const ts = str(r.created_at);
    if (!uid || !ts) continue;
    if (!userDays.has(uid)) userDays.set(uid, new Set());
    userDays.get(uid)!.add(dayKey(new Date(ts)));
  }
  let recurring = 0;
  for (const [, dset] of userDays) if (dset.size >= 2) recurring++;

  const conversations = convDays.size;
  return {
    friendsTotal,
    friendsNew,
    pendingRequests,
    requestsSent,
    acceptRate: requestsSent > 0 ? friendsNew / requestsSent : 0,
    conversationsActive: conversations,
    messages: msgs.length,
    likes,
    blocks,
    reports,
    recurringUsers: recurring,
    recurringRate: userDays.size > 0 ? recurring / userDays.size : 0,
    repeatConversations,
    repeatConversationRate:
      conversations > 0 ? repeatConversations / conversations : 0,
  };
}

/** Daily distinct senders — "combien de gens ont écrit ce jour-là". */
export async function getActiveSendersSeries(days = 14): Promise<DayPoint[]> {
  const rows = await safeRows("messages", "sender, created_at", (q) =>
    q.gte("created_at", sinceISO(days)).limit(100000),
  );
  return bucketDistinctByDay(rows, "created_at", "sender", days);
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
  /** Users whose last app_open is over 30 days old. */
  lostUsers: number;
  /** Users seen on exactly one day, ever. */
  oneAndDone: number;
  trackedUsers: number;
  dau: DayPoint[];
  wau: number;
  mau: number;
  /** dau(today) / mau — the classic stickiness ratio. */
  stickiness: number;
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
    const uid = str(r.user_id);
    const ts = str(r.created_at);
    if (!uid || !ts) continue;
    const di = Math.floor(new Date(ts).getTime() / DAY_MS);
    if (!userDays.has(uid)) userDays.set(uid, new Set());
    userDays.get(uid)!.add(di);
  }

  type Acc = { size: number; d1: number; d7: number; d30: number };
  const cohorts = new Map<number, Acc>();
  let lostUsers = 0;
  let oneAndDone = 0;
  for (const [, dset] of userDays) {
    const sorted = [...dset].sort((a, b) => a - b);
    const first = sorted[0];
    const last = sorted[sorted.length - 1];
    if (last < today - 30) lostUsers++;
    if (dset.size === 1) oneAndDone++;
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

  const dau = bucketDistinctByDay(rows, "created_at", "user_id", days);

  const wauSet = new Set<string>();
  const mauSet = new Set<string>();
  const weekAgo = today - 7;
  const monthAgo = today - 30;
  for (const [uid, dset] of userDays) {
    for (const di of dset) {
      if (di > weekAgo) wauSet.add(uid);
      if (di > monthAgo) mauSet.add(uid);
    }
  }
  const dauToday = dau.length > 0 ? dau[dau.length - 1].value : 0;

  return {
    cohorts: cohortRows,
    overall,
    lostUsers,
    oneAndDone,
    trackedUsers: userDays.size,
    dau,
    wau: wauSet.size,
    mau: mauSet.size,
    stickiness: mauSet.size > 0 ? dauToday / mauSet.size : 0,
  };
}

// ─── consolidated single table ────────────────────────────────────────────

export type MetricGroup =
  | "Croissance"
  | "Rétention"
  | "Social"
  | "Appels"
  | "Profil";

export type MetricRow = {
  group: MetricGroup;
  label: string;
  value: string;
  /** Same metric over the last 30 days, when that framing means something. */
  window?: string;
  hint?: string;
};

/**
 * Every headline number in one flat table — the page you open when you
 * want the state of the app without clicking through five tabs.
 */
export async function getGlobalTable(): Promise<MetricRow[]> {
  const [
    totalUsers,
    new24h,
    new7d,
    new30d,
    withPhoto,
    withInterests,
    withCity,
    live,
    social,
    retention,
    calls,
  ] = await Promise.all([
    safeCount("profiles"),
    safeCount("profiles", (q) => q.gte("created_at", sinceISO(1))),
    safeCount("profiles", (q) => q.gte("created_at", sinceISO(7))),
    safeCount("profiles", (q) => q.gte("created_at", sinceISO(30))),
    safeCount("profiles", (q) => q.not("photos", "is", null)),
    safeCount("profiles", (q) => q.not("interests", "is", null)),
    safeCount("profiles", (q) => q.neq("city", "")),
    getLiveSnapshot(),
    getSocial(30),
    getRetention(30),
    getCallStats(30),
  ]);

  const dauToday =
    retention.dau.length > 0 ? retention.dau[retention.dau.length - 1].value : 0;
  const pctOfUsers = (n: number) =>
    totalUsers > 0 ? fmtPct(n / totalUsers) : "—";

  return [
    // ── Croissance ──
    {
      group: "Croissance",
      label: "Nombre d'utilisateurs",
      value: fmtInt(totalUsers),
      window: `+${fmtInt(new30d)}`,
      hint: "Lignes dans profiles",
    },
    {
      group: "Croissance",
      label: "Nouveaux aujourd'hui",
      value: fmtInt(new24h),
      window: `${fmtInt(new7d)} sur 7 j`,
    },
    {
      group: "Croissance",
      label: "Actifs aujourd'hui (DAU)",
      value: fmtInt(dauToday),
      window: `${fmtInt(retention.wau)} WAU · ${fmtInt(retention.mau)} MAU`,
      hint: "Utilisateurs distincts ayant ouvert l'app",
    },
    {
      group: "Croissance",
      label: "Stickiness (DAU / MAU)",
      value: fmtPct(retention.stickiness),
      hint: "Au-dessus de 20 % = habitude installée",
    },
    {
      group: "Croissance",
      label: "En ligne maintenant",
      value: fmtInt(live.onlineUsers),
      hint: `Heartbeat last_seen < ${ONLINE_WINDOW_MIN} min`,
    },

    // ── Rétention ──
    {
      group: "Rétention",
      label: "Rétention J1",
      value: fmtPct(retention.overall.d1),
      hint: "Revenus le lendemain de leur 1ʳᵉ ouverture",
    },
    {
      group: "Rétention",
      label: "Rétention J7",
      value: fmtPct(retention.overall.d7),
    },
    {
      group: "Rétention",
      label: "Rétention J30",
      value: fmtPct(retention.overall.d30),
    },
    {
      group: "Rétention",
      label: "Utilisateurs récurrents",
      value: fmtInt(social.recurringUsers),
      window: fmtPct(social.recurringRate),
      hint: "Ouvert l'app au moins 2 jours différents",
    },
    {
      group: "Rétention",
      label: "Venus une seule fois",
      value: fmtInt(retention.oneAndDone),
      window:
        retention.trackedUsers > 0
          ? fmtPct(retention.oneAndDone / retention.trackedUsers)
          : "—",
    },
    {
      group: "Rétention",
      label: "Utilisateurs perdus",
      value: fmtInt(retention.lostUsers),
      hint: "Dernière ouverture il y a plus de 30 jours",
    },

    // ── Social ──
    {
      group: "Social",
      label: "Amis (acceptés)",
      value: fmtInt(social.friendsTotal),
      window: `+${fmtInt(social.friendsNew)}`,
    },
    {
      group: "Social",
      label: "Demandes envoyées",
      value: fmtInt(social.requestsSent),
      window: `${fmtPct(social.acceptRate)} acceptées`,
    },
    {
      group: "Social",
      label: "Demandes en attente",
      value: fmtInt(social.pendingRequests),
    },
    {
      group: "Social",
      label: "Messages envoyés",
      value: fmtInt(social.messages),
      window: "sur 30 j",
    },
    {
      group: "Social",
      label: "Conversations actives",
      value: fmtInt(social.conversationsActive),
    },
    {
      group: "Social",
      label: "Conversations qui durent",
      value: fmtInt(social.repeatConversations),
      window: fmtPct(social.repeatConversationRate),
      hint: "Messages sur au moins 2 jours différents — le signal fort",
    },
    { group: "Social", label: "Likes", value: fmtInt(social.likes) },
    {
      group: "Social",
      label: "Blocages",
      value: fmtInt(social.blocks),
      hint: "Total, toutes périodes",
    },
    {
      group: "Social",
      label: "Signalements",
      value: fmtInt(social.reports),
      window: "sur 30 j",
    },

    // ── Appels ──
    {
      group: "Appels",
      label: "Appels passés",
      value: fmtInt(calls.calls),
      window: "sur 30 j",
    },
    {
      group: "Appels",
      label: "Appels de plus d'une minute",
      value: fmtInt(calls.realCalls),
      window:
        calls.calls > 0 ? fmtPct(calls.realCalls / calls.calls) : "—",
      hint: "Une vraie conversation, pas un raccroché immédiat",
    },
    {
      group: "Appels",
      label: "Durée moyenne",
      value: fmtMinutes(calls.avgMinutes),
    },
    {
      group: "Appels",
      label: "Minutes cumulées",
      value: fmtMinutes(calls.totalMinutes),
    },
    {
      group: "Appels",
      label: "Échecs de connexion",
      value: fmtInt(calls.failed),
      window: fmtPct(calls.failRate),
      hint: "call_failed / (call_started + call_failed)",
    },
    {
      group: "Appels",
      label: "Appels en cours",
      value: fmtInt(live.liveCalls),
      window: `${fmtInt(live.usersInCall)} personnes`,
    },

    // ── Profil ──
    {
      group: "Profil",
      label: "Profils avec photo",
      value: fmtInt(withPhoto),
      window: pctOfUsers(withPhoto),
    },
    {
      group: "Profil",
      label: "Profils avec centres d'intérêt",
      value: fmtInt(withInterests),
      window: pctOfUsers(withInterests),
    },
    {
      group: "Profil",
      label: "Profils localisés",
      value: fmtInt(withCity),
      window: pctOfUsers(withCity),
      hint: "Ville renseignée",
    },
    {
      group: "Profil",
      label: "Messages par utilisateur",
      value:
        totalUsers > 0 ? fmtNum(social.messages / totalUsers) : "—",
      window: "sur 30 j",
    },
  ];
}
