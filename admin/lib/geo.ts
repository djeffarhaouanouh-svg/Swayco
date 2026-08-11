// World map geometry — SERVER ONLY. All the heavy lifting (parsing the
// ~110 KB topojson, computing SVG path strings, projecting country
// centroids) happens here so only the resulting path/marker data
// crosses to the client component, not the topojson itself.
//
// Import this only from Server Components / metrics.ts-style server
// code — never from a "use client" module (see lib/supabase/service.ts
// for the same pattern).
//
// Typing note: topojson-client's generics assume a topology shape known
// ahead of time; world-atlas's countries-110m.json doesn't match it
// closely enough for TS to unify the two, so this file works through
// `unknown` at the topojson/d3-geo boundary and keeps everything past
// that boundary — the public `buildWorldMap` signature and the geometry
// math itself — strictly typed.

import { geoArea, geoCentroid, geoEqualEarth, geoPath } from "d3-geo";
import { feature, merge, mesh } from "topojson-client";
import worldTopologyJson from "world-atlas/countries-110m.json";
import iso from "i18n-iso-countries";
import type { CountryStat } from "./metrics";

const worldTopology = worldTopologyJson as unknown;

export const MAP_WIDTH = 960;
export const MAP_HEIGHT = 500;

const MIN_R = 5;
const MAX_R = 20;

export type MapMarker = {
  code: string;
  x: number;
  y: number;
  r: number;
  count: number;
};

export type WorldMapData = {
  /** Every landmass, merged into one fill path. */
  landPath: string;
  /** Interior country borders only (no outer coastline double-stroke). */
  bordersPath: string;
  markers: MapMarker[];
};

type CountryFeature = {
  type: "Feature";
  id?: string | number;
  geometry:
    | { type: "Polygon"; coordinates: number[][][] }
    | { type: "MultiPolygon"; coordinates: number[][][][] };
};

/**
 * The marker's anchor point, restricted to a country's largest polygon.
 *
 * `geoCentroid` on the full MultiPolygon area-weights across every
 * territory a country has, including ones nowhere near it — France's
 * geometry bundles French Guiana (South America) and Corsica alongside
 * mainland France, and the combined centroid lands in open Atlantic,
 * off every one of them. Centroiding just the biggest ring keeps the
 * marker on the country people actually mean.
 */
function mainlandCentroid(f: CountryFeature): [number, number] {
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
  return geoCentroid({
    type: "Polygon",
    coordinates: best,
  } as never);
}

/**
 * Builds everything a <WorldMap> client component needs to render:
 * the base map paths (fixed, independent of data) plus one marker per
 * country in `stats`, sized on an area-proportional (sqrt) scale so
 * visual weight tracks the actual count ratio, not the raw radius.
 */
export function buildWorldMap(stats: CountryStat[]): WorldMapData {
  const countriesObj = (
    worldTopology as { objects: { countries: unknown } }
  ).objects.countries;

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const collection = feature(worldTopology as any, countriesObj as any) as unknown as {
    type: "FeatureCollection";
    features: CountryFeature[];
  };

  const projection = geoEqualEarth().fitSize(
    [MAP_WIDTH, MAP_HEIGHT],
    collection as never,
  );
  const path = geoPath(projection);

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const land = merge(worldTopology as any, countriesObj as any);
  const borders = mesh(
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    worldTopology as any,
    countriesObj as never,
    (a: unknown, b: unknown) => a !== b,
  );

  const landPath = path(land as never) ?? "";
  const bordersPath = path(borders as never) ?? "";

  const byNumericId = new Map(
    collection.features.map((f) => [String(f.id), f]),
  );

  const maxCount = Math.max(...stats.map((s) => s.users), 1);
  const markers: MapMarker[] = [];
  for (const s of stats) {
    const numeric = iso.alpha2ToNumeric(s.code);
    const f = numeric ? byNumericId.get(numeric) : undefined;
    if (!f) continue; // unrecognised / non-standard code — skip, don't guess
    const centroid = mainlandCentroid(f);
    const projected = projection(centroid);
    if (!projected) continue;
    const [x, y] = projected;
    const r = MIN_R + (MAX_R - MIN_R) * Math.sqrt(s.users / maxCount);
    markers.push({ code: s.code, x, y, r, count: s.users });
  }
  // Largest first (drawn first / underneath), so a big dot never buries a
  // small neighbour that renders after it.
  markers.sort((a, b) => b.r - a.r);

  return { landPath, bordersPath, markers };
}
