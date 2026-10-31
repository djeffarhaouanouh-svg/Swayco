// Lecture « toutes les lignes » + liste des comptes IA, partagées par les pages.
//
// Pourquoi par pages : l'API Supabase plafonne chaque réponse (1 000 lignes par
// défaut) quel que soit le `.limit(100000)` demandé. Avec ~3 000 comptes IA, un
// simple `select` tronquait donc silencieusement les totaux.
//
// Pourquoi un jeu d'identifiants IA : les comptes IA (profiles.is_ai) n'ont pas
// de vrai usage. Leurs profils, leurs amitiés et leurs messages ne doivent
// jamais entrer dans les statistiques, sinon ils masquent ce que font les vrais
// utilisateurs. La page « Comptes IA » reste l'endroit où on les suit.

import { createSupabaseServiceClient } from "./supabase/service";

export type Row = Record<string, unknown>;

const PAGE = 1000;
/** Garde-fou : au-delà, on s'arrête (200 requêtes) plutôt que de bloquer la page. */
const MAX_ROWS = 200_000;

/**
 * Toutes les lignes d'une requête, page par page. `apply` ajoute les filtres
 * (eq, gte, …) ; ne pas y mettre de `.limit()` ni de `.order()` : l'ordre par
 * `id` est imposé ici pour que les pages ne se chevauchent pas.
 */
export async function pagedRows(
  table: string,
  columns: string,
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  apply?: (q: any) => any,
): Promise<Row[]> {
  try {
    const sb = createSupabaseServiceClient();
    const out: Row[] = [];
    for (let from = 0; from < MAX_ROWS; from += PAGE) {
      let q = sb.from(table).select(columns);
      if (apply) q = apply(q);
      const { data, error } = await q
        .order("id", { ascending: true })
        .range(from, from + PAGE - 1);
      if (error || !data) break;
      out.push(...(data as unknown as Row[]));
      if (data.length < PAGE) break;
    }
    return out;
  } catch {
    return [];
  }
}

let aiCache: { at: number; ids: Set<string> } | null = null;

/** Identifiants des comptes IA (mis en cache 60 s : plusieurs pages en ont besoin). */
export async function aiIdSet(): Promise<Set<string>> {
  if (aiCache && Date.now() - aiCache.at < 60_000) return aiCache.ids;
  const rows = await pagedRows("profiles", "id", (q) => q.eq("is_ai", true));
  const ids = new Set(
    rows.map((r) => (typeof r.id === "string" ? r.id : "")).filter(Boolean),
  );
  aiCache = { at: Date.now(), ids };
  return ids;
}
