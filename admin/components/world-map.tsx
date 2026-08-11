"use client";

import { useState } from "react";
import type { MapMarker, WorldMapData } from "@/lib/geo";
import { MAP_HEIGHT, MAP_WIDTH } from "@/lib/geo";
import { countryName, fmtInt } from "@/lib/format";

/**
 * A Shopify/Snapchat-style dot map: countries in a muted glass tone,
 * one accent-hue marker per active country, area-proportional to its
 * user count (sqrt scale — computed server-side in lib/geo.ts, this
 * component only renders + hovers). The RankBars list next to it on
 * the page is the accessible table twin — every value here is also
 * readable there without hovering anything.
 */
export function WorldMap({ landPath, bordersPath, markers }: WorldMapData) {
  const [hovered, setHovered] = useState<MapMarker | null>(null);

  return (
    <div className="relative">
      <svg
        viewBox={`0 0 ${MAP_WIDTH} ${MAP_HEIGHT}`}
        className="w-full"
        role="img"
        aria-label="Carte des pays actifs"
      >
        <path d={landPath} fill="rgba(255,255,255,0.07)" />
        <path
          d={bordersPath}
          fill="none"
          stroke="rgba(255,255,255,0.10)"
          strokeWidth={0.6}
          strokeLinejoin="round"
        />
        {markers.map((m) => (
          <g
            key={m.code}
            onMouseEnter={() => setHovered(m)}
            onMouseLeave={() => setHovered((h) => (h?.code === m.code ? null : h))}
            className="cursor-pointer"
          >
            {/* Soft halo — the "live location" glow, well under the
                anti-pattern threshold since it's a single low-opacity wash. */}
            <circle cx={m.x} cy={m.y} r={m.r + 6} fill="var(--color-sc-accent)" fillOpacity={0.10} />
            {/* Hit area extends past the visible dot per the interaction spec
                (≥24px target) without inflating what's actually drawn. */}
            <circle cx={m.x} cy={m.y} r={Math.max(m.r, 12)} fill="transparent" />
            <circle
              cx={m.x}
              cy={m.y}
              r={m.r}
              fill="var(--color-sc-accent)"
              fillOpacity={hovered?.code === m.code ? 0.75 : 0.55}
              stroke="#0e0e0e"
              strokeWidth={2}
            />
          </g>
        ))}
      </svg>

      {hovered ? (
        <div
          className="pointer-events-none absolute z-10 -translate-x-1/2 -translate-y-full rounded-xl border border-white/10 bg-[#141821] px-3 py-2 text-xs whitespace-nowrap text-sc-text shadow-lg"
          style={{
            left: `${(hovered.x / MAP_WIDTH) * 100}%`,
            top: `${(hovered.y / MAP_HEIGHT) * 100}%`,
            marginTop: -10,
          }}
        >
          <div className="font-semibold">{countryName(hovered.code)}</div>
          <div className="text-sc-text-secondary">
            {fmtInt(hovered.count)} personne{hovered.count > 1 ? "s" : ""}
          </div>
        </div>
      ) : null}
    </div>
  );
}
