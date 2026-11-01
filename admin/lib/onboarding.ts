// Suivi de l'onboarding : qui le termine, et ce que ces personnes font ensuite.
//
// Tout est déduit de données qui existent déjà (lecture seule, comme le reste de
// l'admin). L'app n'envoie PAS d'événement par écran d'onboarding, et
// l'onboarding se déroule AVANT la connexion : le profil n'est écrit qu'à la fin
// (main.dart::_hydrateAuthedSession). Quelqu'un qui quitte avant de se connecter
// ne laisse donc aucune ligne dans `profiles` ; on en voit seulement la trace
// indirecte via les sessions `app_open` sans utilisateur (anonymousSessions).
//
// Comptes comptés : humains uniquement (is_ai = false, hors profils de test
// « seed_… »).

import { dayKey } from "./format";
import { sinceISO } from "./metrics";
import { aiIdSet, pagedRows, type Row } from "./db";

// Lecture complète, page par page (l'API plafonne chaque réponse à 1 000 lignes).
const rows = pagedRows;

const s = (v: unknown): string => (typeof v === "string" ? v.trim() : "");

export type FunnelStep = { label: string; hint?: string; count: number; pct: number };

export type RecentSignup = {
  id: string;
  createdAt: string;
  name: string;
  country: string;
  language: string;
  complete: boolean;
  hasPhoto: boolean;
  liked: boolean;
  messaged: boolean;
  returned: boolean;
};

/** Une étape de l'assistant, vue côté app (événements onboarding_step). */
export type StopStep = {
  label: string;
  /** Sessions qui ont affiché cet écran. */
  count: number;
  /** Part de ceux qui sont arrivés sur le premier écran. */
  pct: number;
  /** Sessions arrêtées ici : vues de cet écran moins celles de l'écran suivant. */
  lost: number;
};

/** Écrans de l'assistant, dans l'ordre où ils s'affichent. */
const STOP_STEPS: { key: string; label: string }[] = [
  { key: "welcome", label: "Bienvenue (prénom)" },
  { key: "language", label: "Langue" },
  { key: "location", label: "Pays" },
  { key: "gender", label: "Genre" },
  { key: "persona", label: "Catégorie" },
  { key: "photo", label: "Photo" },
  { key: "verification", label: "Vérification" },
];

export type OnboardingReport = {
  days: number;
  created: number;
  completed: number;
  /** Sessions ayant ouvert le premier écran (0 = pas encore de données de l'app). */
  startedSessions: number;
  stops: StopStep[];
  /** Sessions allées jusqu'au bout de l'assistant (onboarding_done). */
  doneSessions: number;
  photoSkipped: number;
  /** Sessions app_open sans utilisateur connecté (avant ou sans inscription). */
  anonymousSessions: number;
  funnel: FunnelStep[];
  /** Parmi ceux qui ont terminé l'onboarding. */
  after: FunnelStep[];
  recent: RecentSignup[];
};

const pct = (n: number, d: number): number => (d > 0 ? n / d : 0);

export async function getOnboardingReport(days = 30): Promise<OnboardingReport> {
  const since = sinceISO(days);

  const [profilesRaw, aiIds, friendships, messages, events, anon, wizard] = await Promise.all([
    // Vrais comptes seulement (les profils IA sont exclus de toutes les stats).
    rows(
      "profiles",
      "id, created_at, display_name, handle, language, gender, persona_category, country, city, discover_photo_url, photos, avatar_url, is_pro, subscription_tier",
      (q) => q.eq("is_ai", false).gte("created_at", since),
    ),
    aiIdSet(),
    rows("friendships", "requester, addressee, status", (q) => q.gte("created_at", since)),
    rows("messages", "sender", (q) => q.gte("created_at", since)),
    rows("analytics_events", "user_id, event, created_at, props", (q) =>
      q.not("user_id", "is", null).gte("created_at", since),
    ),
    rows("analytics_events", "session_id", (q) =>
      q.eq("event", "app_open").is("user_id", null).gte("created_at", since),
    ),
    // Événements de l'assistant (app ≥ build qui les envoie), invités compris.
    rows("analytics_events", "event, session_id, props", (q) =>
      q
        .in("event", ["onboarding_step", "onboarding_done", "onboarding_photo_skipped"])
        .gte("created_at", since),
    ),
  ]);
  // Plus récents d'abord (le tri par id imposé par la lecture par pages ne
  // reflète pas la date d'inscription).
  const profiles = [...profilesRaw].sort((a, b) =>
    s(b.created_at).localeCompare(s(a.created_at)),
  );

  // Sessions distinctes par écran de l'assistant.
  const bySession = new Map<string, Set<string>>();
  const doneSet = new Set<string>();
  const skipSet = new Set<string>();
  for (const e of wizard) {
    const sid = s(e.session_id);
    if (!sid) continue;
    const ev = s(e.event);
    if (ev === "onboarding_done") doneSet.add(sid);
    else if (ev === "onboarding_photo_skipped") skipSet.add(sid);
    else {
      const step = s(((e.props ?? {}) as Record<string, unknown>).step);
      if (!step) continue;
      if (!bySession.has(step)) bySession.set(step, new Set());
      bySession.get(step)!.add(sid);
    }
  }
  const startedSessions = bySession.get("welcome")?.size ?? 0;
  // Écrans réellement vus au moins une fois (location/genre/… peuvent être
  // sautés quand la réponse est déjà connue) : on compare chaque écran au
  // suivant ÉCRAN VU, pas au suivant théorique.
  const seen = STOP_STEPS.filter((st) => (bySession.get(st.key)?.size ?? 0) > 0);
  const stops: StopStep[] = seen.map((st, i) => {
    const count = bySession.get(st.key)!.size;
    const nextCount =
      i + 1 < seen.length ? bySession.get(seen[i + 1].key)!.size : doneSet.size;
    return {
      label: st.label,
      count,
      pct: pct(count, startedSessions),
      lost: Math.max(0, count - nextCount),
    };
  });

  // Profils de test exclus.
  const people = profiles.filter((p) => !s(p.handle).startsWith("seed_"));

  const hasPhoto = (p: Row): boolean => {
    const gallery = Array.isArray(p.photos) ? (p.photos as unknown[]) : [];
    return [p.discover_photo_url, p.avatar_url, ...gallery].some((u) => s(u) !== "");
  };
  // Le genre et la catégorie ne sont écrits que par l'assistant d'onboarding ;
  // le prénom peut être pré-rempli par une connexion Google / Apple.
  const isComplete = (p: Row): boolean =>
    s(p.display_name) !== "" &&
    s(p.language) !== "" &&
    s(p.gender) !== "" &&
    s(p.persona_category) !== "";

  const created = people.length;
  const cohort = people.filter(isComplete);
  const completed = cohort.length;
  const cohortIds = new Set(cohort.map((p) => s(p.id)));

  const count = (f: (p: Row) => boolean) => people.filter(f).length;
  const funnel: FunnelStep[] = [
    { label: "Comptes créés", count: created, pct: 1 },
    { label: "Prénom", count: count((p) => s(p.display_name) !== ""), pct: 0 },
    { label: "Langue parlée", count: count((p) => s(p.language) !== ""), pct: 0 },
    { label: "Genre", count: count((p) => s(p.gender) !== ""), pct: 0 },
    { label: "Catégorie", count: count((p) => s(p.persona_category) !== ""), pct: 0 },
    { label: "Pays", count: count((p) => s(p.country) !== ""), pct: 0 },
    { label: "Photo", count: count(hasPhoto), pct: 0 },
    {
      label: "Onboarding terminé",
      hint: "prénom + langue + genre + catégorie",
      count: completed,
      pct: 0,
    },
  ].map((st) => ({ ...st, pct: pct(st.count, created) }));

  // ── Ce qu'ils font ensuite (parmi ceux qui ont terminé) ──────────────────
  const liked = new Set<string>();
  const likedHuman = new Set<string>();
  const matchAi = new Set<string>();
  const matchHuman = new Set<string>();
  for (const f of friendships) {
    const a = s(f.requester);
    const b = s(f.addressee);
    if (cohortIds.has(a)) {
      liked.add(a);
      if (!aiIds.has(b)) likedHuman.add(a);
    }
    if (s(f.status) === "accepted") {
      for (const [me, other] of [[a, b], [b, a]]) {
        if (!cohortIds.has(me)) continue;
        (aiIds.has(other) ? matchAi : matchHuman).add(me);
      }
    }
  }

  const messaged = new Set<string>();
  for (const m of messages) {
    const u = s(m.sender);
    if (cohortIds.has(u)) messaged.add(u);
  }

  const peopleIds = new Set(people.map((p) => s(p.id)));
  const daysByUser = new Map<string, Set<string>>();
  for (const e of events) {
    const u = s(e.user_id);
    if (!peopleIds.has(u)) continue;
    const t = s(e.created_at);
    if (t) {
      if (!daysByUser.has(u)) daysByUser.set(u, new Set());
      daysByUser.get(u)!.add(dayKey(new Date(t)));
    }
  }
  const withEvent = (name: string, prop?: [string, string]): number => {
    const seen = new Set<string>();
    for (const e of events) {
      const u = s(e.user_id);
      if (!cohortIds.has(u) || s(e.event) !== name || seen.has(u)) continue;
      if (prop) {
        const props = (e.props ?? {}) as Record<string, unknown>;
        if (s(props[prop[0]]) !== prop[1]) continue;
      }
      seen.add(u);
    }
    return seen.size;
  };
  const returned = new Set(
    [...daysByUser.entries()].filter(([, d]) => d.size >= 2).map(([u]) => u),
  );
  const subscribers = cohort.filter(
    (p) => p.is_pro === true || (s(p.subscription_tier) !== "" && s(p.subscription_tier) !== "free"),
  ).length;

  const afterRaw: { label: string; hint?: string; count: number }[] = [
    { label: "Ont ouvert Discover", count: withEvent("screen_view", ["screen", "discover"]) },
    { label: "Ont liké quelqu'un", count: liked.size },
    { label: "… dont un vrai humain", count: likedHuman.size },
    { label: "Ont envoyé un message", count: messaged.size },
    { label: "Ont un match avec une IA", count: matchAi.size },
    { label: "Ont un match avec un humain", count: matchHuman.size },
    { label: "Ont vu le paywall", count: withEvent("paywall_open") },
    { label: "Ont regardé une pub (like débloqué)", count: withEvent("ad_watched") },
    { label: "Ont lancé un appel", count: withEvent("call_started") },
    {
      label: "Sont retournés dans l'app un autre jour",
      hint: "événements sur au moins 2 jours",
      count: [...returned].filter((u) => cohortIds.has(u)).length,
    },
    { label: "Abonnés (Pro)", count: subscribers },
  ];
  const after = afterRaw.map((st) => ({ ...st, pct: pct(st.count, completed) }));

  const recent: RecentSignup[] = people.slice(0, 15).map((p) => {
    const id = s(p.id);
    return {
      id,
      createdAt: s(p.created_at),
      name: s(p.display_name) || "—",
      country: s(p.country),
      language: s(p.language),
      complete: isComplete(p),
      hasPhoto: hasPhoto(p),
      // Relus pour tout le monde (pas seulement la cohorte « terminé »), afin de
      // montrer aussi ce que font les comptes incomplets.
      liked: friendships.some((f) => s(f.requester) === id),
      messaged: messages.some((m) => s(m.sender) === id),
      returned: returned.has(id),
    };
  });

  const anonymousSessions = new Set(anon.map((r) => s(r.session_id)).filter(Boolean)).size;

  return {
    days,
    created,
    completed,
    startedSessions,
    stops,
    doneSessions: doneSet.size,
    photoSkipped: skipSet.size,
    anonymousSessions,
    funnel,
    after,
    recent,
  };
}
