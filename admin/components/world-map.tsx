"use client";

import { useEffect, useRef, useState } from "react";
import { select } from "d3-selection";
import { zoom, zoomIdentity, type D3ZoomEvent, type ZoomBehavior } from "d3-zoom";
// Side-effect import: registers `.transition()` on d3-selection's
// Selection type (used below to animate the zoom-control buttons).
import "d3-transition";
import type { MapMarker, WorldMapData } from "@/lib/geo";
import { MAP_HEIGHT, MAP_WIDTH } from "@/lib/geo";
import { countryName, fmtInt } from "@/lib/format";

const MIN_ZOOM = 1;
const MAX_ZOOM = 8;

/**
 * A Shopify/Snapchat-style dot map: countries in a muted glass tone,
 * one accent-hue marker per active country, area-proportional to its
 * user count (sqrt scale — computed server-side in lib/geo.ts, this
 * component only renders + hovers). The RankBars list next to it on
 * the page is the accessible table twin — every value here is also
 * readable there without hovering anything.
 *
 * Zoom/pan via d3-zoom. The SVG is rendered at its native 960×500 box
 * (no responsive CSS scaling) so pointer coordinates and the viewBox's
 * internal units are the same number — d3-zoom's translate/scale extents
 * can then be expressed directly in map units with no conversion, which
 * is what keeps drag speed and zoom bounds correct at every zoom level.
 * The map card scrolls horizontally instead of shrinking the map on
 * narrow viewports.
 */
export function WorldMap({ landPath, bordersPath, markers }: WorldMapData) {
  const [hovered, setHovered] = useState<MapMarker | null>(null);
  const [transform, setTransform] = useState(zoomIdentity);
  const [dragging, setDragging] = useState(false);
  const svgRef = useRef<SVGSVGElement>(null);
  const zoomRef = useRef<ZoomBehavior<SVGSVGElement, unknown> | null>(null);

  useEffect(() => {
    if (!svgRef.current) return;
    const behavior = zoom<SVGSVGElement, unknown>()
      .scaleExtent([MIN_ZOOM, MAX_ZOOM])
      .translateExtent([
        [0, 0],
        [MAP_WIDTH, MAP_HEIGHT],
      ])
      // Wheel only zooms with Ctrl/Cmd held (trackpad pinch sends the same
      // signal) — otherwise the wheel event is left alone so it scrolls the
      // dashboard page normally instead of getting hijacked by the map.
      // Drag, touch-pinch and double-click keep d3-zoom's own defaults.
      .filter((event: Event) => {
        if (event.type === "wheel") {
          return (event as WheelEvent).ctrlKey || (event as WheelEvent).metaKey;
        }
        return !(event as MouseEvent).ctrlKey && !(event as MouseEvent).button;
      })
      .on("start", () => setDragging(true))
      .on("end", () => setDragging(false))
      .on("zoom", (event: D3ZoomEvent<SVGSVGElement, unknown>) => {
        setTransform(event.transform);
      });

    zoomRef.current = behavior;
    const sel = select(svgRef.current);
    sel.call(behavior);
    return () => {
      sel.on(".zoom", null);
    };
  }, []);

  function zoomBy(factor: number) {
    if (!svgRef.current || !zoomRef.current) return;
    select(svgRef.current)
      .transition()
      .duration(200)
      .call(zoomRef.current.scaleBy, factor);
  }

  function zoomReset() {
    if (!svgRef.current || !zoomRef.current) return;
    select(svgRef.current)
      .transition()
      .duration(300)
      .call(zoomRef.current.transform, zoomIdentity);
  }

  const hoveredScreen = hovered
    ? transform.apply([hovered.x, hovered.y])
    : null;

  return (
    <div className="relative">
      <div className="overflow-x-auto">
        <svg
          ref={svgRef}
          width={MAP_WIDTH}
          height={MAP_HEIGHT}
          viewBox={`0 0 ${MAP_WIDTH} ${MAP_HEIGHT}`}
          className={dragging ? "cursor-grabbing" : "cursor-grab"}
          role="img"
          aria-label="Carte des pays actifs"
        >
          <g transform={transform.toString()}>
            <path d={landPath} fill="rgba(255,255,255,0.07)" />
            <path
              d={bordersPath}
              fill="none"
              stroke="rgba(255,255,255,0.10)"
              strokeWidth={0.6}
              strokeLinejoin="round"
              vectorEffect="non-scaling-stroke"
            />
            {markers.map((m) => (
              <g
                key={m.code}
                onMouseEnter={() => setHovered(m)}
                onMouseLeave={() =>
                  setHovered((h) => (h?.code === m.code ? null : h))
                }
                className="cursor-pointer"
              >
                {/* Soft halo — the "live location" glow, well under the
                    anti-pattern threshold since it's a single low-opacity wash. */}
                <circle
                  cx={m.x}
                  cy={m.y}
                  r={m.r + 6}
                  fill="var(--color-sc-accent)"
                  fillOpacity={0.1}
                />
                {/* Hit area extends past the visible dot per the interaction
                    spec (≥24px target) without inflating what's drawn. */}
                <circle cx={m.x} cy={m.y} r={Math.max(m.r, 12)} fill="transparent" />
                <circle
                  cx={m.x}
                  cy={m.y}
                  r={m.r}
                  fill="var(--color-sc-accent)"
                  fillOpacity={hovered?.code === m.code ? 0.75 : 0.55}
                  stroke="#0e0e0e"
                  strokeWidth={2}
                  vectorEffect="non-scaling-stroke"
                />
              </g>
            ))}
          </g>
        </svg>
      </div>

      {hoveredScreen ? (
        <div
          className="pointer-events-none absolute z-10 -translate-x-1/2 -translate-y-full rounded-xl border border-white/10 bg-[#141821] px-3 py-2 text-xs whitespace-nowrap text-sc-text shadow-lg"
          style={{
            left: `${(hoveredScreen[0] / MAP_WIDTH) * 100}%`,
            top: `${(hoveredScreen[1] / MAP_HEIGHT) * 100}%`,
            marginTop: -10,
          }}
        >
          <div className="font-semibold">{countryName(hovered!.code)}</div>
          <div className="text-sc-text-secondary">
            {fmtInt(hovered!.count)} personne{hovered!.count > 1 ? "s" : ""}
          </div>
        </div>
      ) : null}

      <div className="absolute top-3 right-3 flex flex-col gap-1 rounded-xl border border-white/10 bg-[#141821]/90 p-1 backdrop-blur">
        <button
          type="button"
          onClick={() => zoomBy(1.6)}
          aria-label="Zoomer"
          className="flex h-7 w-7 items-center justify-center rounded-lg text-sm font-bold text-sc-text-secondary transition-colors hover:bg-white/10 hover:text-sc-text"
        >
          +
        </button>
        <button
          type="button"
          onClick={() => zoomBy(1 / 1.6)}
          aria-label="Dézoomer"
          className="flex h-7 w-7 items-center justify-center rounded-lg text-sm font-bold text-sc-text-secondary transition-colors hover:bg-white/10 hover:text-sc-text"
        >
          −
        </button>
        <button
          type="button"
          onClick={zoomReset}
          aria-label="Réinitialiser le zoom"
          className="flex h-7 w-7 items-center justify-center rounded-lg text-[10px] font-bold text-sc-text-secondary transition-colors hover:bg-white/10 hover:text-sc-text"
        >
          ⟲
        </button>
      </div>

      <div className="pointer-events-none absolute bottom-3 left-3 rounded-lg bg-[#141821]/80 px-2.5 py-1 text-[11px] text-sc-text-muted backdrop-blur">
        Ctrl/⌘ + molette ou pincer pour zoomer · glisser pour déplacer
      </div>
    </div>
  );
}
