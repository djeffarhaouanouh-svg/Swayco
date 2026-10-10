// "Où investir ?" — par pays : combien de profils (et d'actifs) on a, et combien
// de personnes ont demandé l'ouverture (liste d'attente « Me prévenir » du
// globe, table country_waitlist, migration 0069). Lit via le client service
// (hors RLS) et reste défensif : table absente = zéro, jamais une page cassée.

import { createSupabaseServiceClient } from "./supabase/service";

const DAY_MS = 86_400_000;

/** Pays déjà ouverts dans l'app (kGlobeCountries) : clés = name du GeoJSON. */
const OPEN_KEYS = new Set([
  "France",
  "Germany",
  "Canada",
  "Japan",
  "Belgium",
  "Brazil",
  "Spain",
  "Sweden",
  "Morocco",
  "Mexico",
  "Argentina",
  "Colombia",
  "Philippines",
]);

/** profiles.country (libellé français stocké) -> clé du globe (GeoJSON). */
const FR_TO_KEY: Record<string, string> = {
  France: "France",
  Belgique: "Belgium",
  Suisse: "Switzerland",
  Canada: "Canada",
  "États-Unis": "United States of America",
  "Royaume-Uni": "United Kingdom",
  Espagne: "Spain",
  Portugal: "Portugal",
  Italie: "Italy",
  Allemagne: "Germany",
  "Pays-Bas": "Netherlands",
  Mexique: "Mexico",
  Argentine: "Argentina",
  Colombie: "Colombia",
  Brésil: "Brazil",
  Maroc: "Morocco",
  Algérie: "Algeria",
  Tunisie: "Tunisia",
  Sénégal: "Senegal",
  "Côte d'Ivoire": "Côte d'Ivoire",
  Égypte: "Egypt",
  "Arabie Saoudite": "Saudi Arabia",
  "Émirats arabes unis": "United Arab Emirates",
  Turquie: "Turkey",
  Russie: "Russia",
  Chine: "China",
  Japon: "Japan",
  "Corée du Sud": "South Korea",
  Inde: "India",
  Australie: "Australia",
  Luxembourg: "Luxembourg",
  Islande: "Iceland",
  Norvège: "Norway",
  Suède: "Sweden",
  Danemark: "Denmark",
  Finlande: "Finland",
  Irlande: "Ireland",
  Pologne: "Poland",
  Ukraine: "Ukraine",
  Grèce: "Greece",
  Philippines: "Philippines",
};

const KEY_TO_FR: Record<string, string> = Object.fromEntries(
  Object.entries(FR_TO_KEY).map(([fr, key]) => [key, fr]),
);

export type CountryDemandRow = {
  key: string;
  /** Nom affiché (français quand on le connaît). */
  label: string;
  open: boolean;
  /** Profils dont c'est le pays. */
  profiles: number;
  /** Profils vus (last_seen) dans les 30 derniers jours. */
  active: number;
  /** Personnes qui attendent l'ouverture. */
  demand: number;
};

export async function getCountryDemand(): Promise<CountryDemandRow[]> {
  const sb = createSupabaseServiceClient();
  const since = Date.now() - 30 * DAY_MS;

  const profiles = new Map<string, { total: number; active: number }>();
  try {
    const { data } = await sb
      .from("profiles")
      .select("country, last_seen")
      .not("country", "is", null)
      .neq("country", "")
      .limit(100000);
    for (const r of (data ?? []) as { country: string; last_seen: string | null }[]) {
      const key = FR_TO_KEY[r.country] ?? r.country;
      const cur = profiles.get(key) ?? { total: 0, active: 0 };
      cur.total += 1;
      if (r.last_seen && new Date(r.last_seen).getTime() >= since) cur.active += 1;
      profiles.set(key, cur);
    }
  } catch {
    /* table illisible : on affiche ce qu'on a */
  }

  const demand = new Map<string, number>();
  try {
    const { data } = await sb.from("country_waitlist").select("country_key").limit(200000);
    for (const r of (data ?? []) as { country_key: string }[]) {
      demand.set(r.country_key, (demand.get(r.country_key) ?? 0) + 1);
    }
  } catch {
    /* migration 0069 pas encore appliquée */
  }

  const keys = new Set([...profiles.keys(), ...demand.keys()]);
  return [...keys]
    .map((key) => ({
      key,
      label: KEY_TO_FR[key] ?? key,
      open: OPEN_KEYS.has(key),
      profiles: profiles.get(key)?.total ?? 0,
      active: profiles.get(key)?.active ?? 0,
      demand: demand.get(key) ?? 0,
    }))
    .sort((a, b) => b.demand - a.demand || b.active - a.active || b.profiles - a.profiles);
}
