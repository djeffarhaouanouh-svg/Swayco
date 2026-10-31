// Données du globe 3D — SERVER ONLY (même règle que lib/geo.ts : à importer
// uniquement depuis un Server Component, jamais depuis un module "use client").
//
// Le globe est dessiné en points (une grille régulière sur la sphère, gardée
// là où il y a de la terre). Le calcul « ce point est-il sur une terre ? »
// est fait ICI, une seule fois par processus (mis en cache), pour que le
// navigateur ne reçoive que des coordonnées : ~6 000 nombres (≈ 35 Ko).
//
// Aucune nouvelle dépendance : d3-geo, topojson-client, world-atlas et
// i18n-iso-countries sont déjà utilisés par lib/geo.ts.

import { geoArea, geoBounds, geoCentroid, geoContains } from "d3-geo";
import { feature } from "topojson-client";
import worldTopologyJson from "world-atlas/countries-110m.json";
import iso from "i18n-iso-countries";
import type { CountryStat } from "./metrics";

const worldTopology = worldTopologyJson as unknown;

type Feat = {
  type: "Feature";
  id?: string | number;
  geometry:
    | { type: "Polygon"; coordinates: number[][][] }
    | { type: "MultiPolygon"; coordinates: number[][][][] };
};
type Land = { f: Feat; id: string; w: number; s: number; e: number; n: number };

export type GlobeMarker = { code: string; lon: number; lat: number; count: number };

export type GlobeData = {
  /** Tous les points de terre, à plat : [lon0, lat0, lon1, lat1, …] en degrés. */
  dots: number[];
  /** Indices (dans `dots`, par paire) des points des pays actifs. */
  active: number[];
  /** Un marqueur par pays actif, du plus gros au plus petit. */
  markers: GlobeMarker[];
  /** Appels en cours entre deux pays (page Live) : un arc par liaison. */
  routes: GlobeRoute[];
};

export type GlobeEnd = { code: string; lon: number; lat: number };
export type GlobeRoute = { from: GlobeEnd; to: GlobeEnd; count: number };

/** Écart de la grille, en degrés. Plus petit = plus de points (et plus lourd). */
const STEP = 2.1;

let cache: { lands: Land[]; dots: number[]; owner: number[] } | null = null;

function inBox(l: Land, lon: number, lat: number) {
  if (lat < l.s || lat > l.n) return false;
  // w > e : la boîte traverse l'antiméridien (Russie, Fidji…).
  return l.w <= l.e ? lon >= l.w && lon <= l.e : lon >= l.w || lon <= l.e;
}

function land() {
  if (cache) return cache;
  const topo = worldTopology as { objects: { countries: unknown } };
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const col = feature(worldTopology as any, topo.objects.countries as any) as unknown as {
    features: Feat[];
  };
  const lands: Land[] = col.features
    .filter((f) => String(f.id) !== "010") // Antarctique : pas de point
    .map((f) => {
      const [[w, s], [e, n]] = geoBounds(f as never);
      return { f, id: f.id == null ? "" : String(f.id), w, s, e, n };
    });

  const dots: number[] = [];
  const owner: number[] = []; // owner[i] = index du pays du point i
  for (let lat = -80; lat <= 84; lat += STEP) {
    // Moins de points près des pôles, pour garder une densité à peu près égale.
    const n = Math.max(1, Math.round((360 * Math.cos((lat * Math.PI) / 180)) / STEP));
    const off = (Math.round((lat + 80) / STEP) % 2) * 0.5; // quinconce
    for (let i = 0; i < n; i++) {
      const lon = -180 + ((i + off) * 360) / n;
      const k = lands.findIndex(
        (l) => inBox(l, lon, lat) && geoContains(l.f as never, [lon, lat]),
      );
      if (k >= 0) {
        dots.push(Math.round(lon * 10) / 10, Math.round(lat * 10) / 10);
        owner.push(k);
      }
    }
  }
  cache = { lands, dots, owner };
  return cache;
}

/** Centre du plus grand polygone du pays (même raison que dans lib/geo.ts :
 *  la France inclut la Guyane, son centroïde global tomberait dans l'Atlantique). */
function mainlandCentroid(f: Feat): [number, number] {
  if (f.geometry.type === "Polygon") return geoCentroid(f as never);
  let best = f.geometry.coordinates[0];
  let bestArea = -1;
  for (const coordinates of f.geometry.coordinates) {
    const area = geoArea({ type: "Polygon", coordinates } as never);
    if (area > bestArea) {
      bestArea = area;
      best = coordinates;
    }
  }
  return geoCentroid({ type: "Polygon", coordinates: best } as never);
}

const r2 = (v: number) => Math.round(v * 100) / 100;

/**
 * @param stats       même tableau que celui donné à buildWorldMap()
 *                    (vue d'ensemble : getCountries(30) ; Live : countries
 *                    du snapshot, `{ code: c.label, users: c.value }`).
 * @param links       appels réels en cours entre deux pays (page Live) :
 *                    chacun devient un arc entre ses deux pays. Un code
 *                    inconnu est ignoré.
 */
export function buildGlobe(
  stats: CountryStat[],
  links: { a: string; b: string; count: number }[] = [],
): GlobeData {
  const { lands, dots, owner } = land();
  const byId = new Map<string, number>();
  lands.forEach((l, i) => {
    if (l.id) byId.set(l.id, i);
  });
  const locate = (code: string) => {
    const numeric = iso.alpha2ToNumeric(code);
    return numeric ? byId.get(numeric) : undefined;
  };

  const markers: GlobeMarker[] = [];
  const activeLands = new Set<number>();
  for (const s of stats) {
    const k = locate(s.code);
    if (k === undefined) continue; // code inconnu : on ignore, on ne devine pas
    const [lon, lat] = mainlandCentroid(lands[k].f);
    markers.push({ code: s.code, lon: r2(lon), lat: r2(lat), count: s.users });
    activeLands.add(k);
  }
  markers.sort((a, b) => b.count - a.count);

  const active: number[] = [];
  owner.forEach((k, i) => {
    if (activeLands.has(k)) active.push(i);
  });

  const end = (code: string): GlobeEnd | null => {
    const k = locate(code);
    if (k === undefined) return null;
    const [lon, lat] = mainlandCentroid(lands[k].f);
    return { code, lon: r2(lon), lat: r2(lat) };
  };
  const routes: GlobeRoute[] = [];
  for (const l of links) {
    const from = end(l.a);
    const to = end(l.b);
    if (from && to) routes.push({ from, to, count: l.count });
  }

  return { dots, active, markers, routes };
}
