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
import { dayKey } from "./format";

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
  proCount: number;
  ultraCount: number;
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
  const rateRealtime = num(process.env.COST_REALTIME_USD_PER_MIN, 0);
  const rateLivekit = num(process.env.COST_LIVEKIT_USD_PER_MIN, 0);
  const rateText = num(process.env.COST_TEXT_USD_PER_1K_TOKENS, 0);
  const usdToEur = num(process.env.USD_TO_EUR, 0.92);
  const pricePro = num(process.env.PRICE_PRO_EUR, 29);
  const priceUltra = num(process.env.PRICE_ULTRA_EUR, 59);

  const [calls, texts, proCount, ultraCount, freeCount] = await Promise.all([
    safeRows("analytics_events", "props", (q) =>
      q.eq("event", "call_ended").gte("created_at", sinceISO(days)).limit(100000),
    ),
    safeRows("analytics_events", "props", (q) =>
      q
        .eq("event", "text_translation")
        .gte("created_at", sinceISO(days))
        .limit(100000),
    ),
    safeCount("profiles", (q) => q.eq("subscription_tier", "pro")),
    safeCount("profiles", (q) => q.eq("subscription_tier", "ultra")),
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
  const mrrEur = proCount * pricePro + ultraCount * priceUltra;

  return {
    callMinutes,
    translationMinutes,
    textTokens,
    costRealtimeUsd,
    costLivekitUsd,
    costTextUsd,
    costTotalEur,
    proCount,
    ultraCount,
    freeCount,
    mrrEur,
    marginEur: mrrEur - costTotalEur,
    ratesConfigured: rateRealtime > 0 || rateLivekit > 0 || rateText > 0,
    windowDays: days,
  };
}
