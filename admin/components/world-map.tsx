"use client";

import { useEffect, useRef, useState } from "react";
import { select } from "d3-selection";
import { zoom, zoomIdentity, type D3ZoomEvent, type ZoomBehavior } from "d3-zoom";
// Side-effect import: registers `.transition()` on d3-selection's Selection.
import "d3-transition";
import type { MapMarker, WorldMapData } from "@/lib/geo";
import { MAP_HEIGHT, MAP_WIDTH } from "@/lib/geo";
import { countryName, fmtInt } from "@/lib/format";
import { Flag } from "@/components/flag";
import { cn } from "@/lib/utils";

const MIN_ZOOM = 1;
const MAX_ZOOM = 8;

/**
 * Carte « à points » de la direction 1c.
 *
 * CE QUI CHANGE par rapport à l'ancienne carte (la géométrie, la projection
 * Equal Earth, buildWorldMap() et le zoom d3 ne changent PAS) :
 *  - les terres ne sont plus un aplat blanc translucide mais un motif de
 *    petits points bleu-gris (<pattern>), sans tracé des frontières ;
 *  - les marqueurs sont bleus (#1F5EFF, 58 %) cerclés de blanc, halo bleu 10 % ;
 *  - le SVG devient RESPONSIVE (viewBox, w-full, h-auto) au lieu d'être fixé
 *    à 960×500 : d3-zoom lit la position du pointeur via la matrice de
 *    l'élément SVG, donc le glisser / zoomer reste juste. À tester ; si la
 *    vitesse de glissement paraît fausse, revenir à width/height fixes dans
 *    un conteneur overflow-x-auto comme avant ;
 *  - `pulse` : un anneau qui pulse sur chaque marqueur (page Live) ;
 *  - `labels` : affiche N étiquettes (drapeau + pays + nombre) sur les plus
 *    gros marqueurs (vue d'ensemble : 3, Live : 4).
 */
export function WorldMap({
  landPath,
  markers,
  pulse = false,
  labels = 0,
}: WorldMapData & { pulse?: boolean; labels?: number }) {
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
      // La molette ne zoome qu'avec Ctrl/⌘ (pincer sur trackpad envoie le
      // même signal) — sinon la page défile normalement.
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
    select(svgRef.current).transition().duration(200).call(zoomRef.current.scaleBy, factor);
  }

  function zoomReset() {
    if (!svgRef.current || !zoomRef.current) return;
    select(svgRef.current)
      .transition()
      .duration(300)
      .call(zoomRef.current.transform, zoomIdentity);
  }

  const hoveredScreen = hovered ? transform.apply([hovered.x, hovered.y]) : null;
  const ctl =
    "flex h-7 w-7 cursor-pointer items-center justify-center rounded-lg text-sm font-extrabold text-sc-text-secondary transition-colors hover:bg-sc-accent/10 hover:text-sc-text";

  return (
    <div className="relative">
      <svg
        ref={svgRef}
        viewBox={`0 0 ${MAP_WIDTH} ${MAP_HEIGHT}`}
        className={cn("block h-auto w-full", dragging ? "cursor-grabbing" : "cursor-grab")}
        role="img"
        aria-label="Carte des pays actifs"
      >
        <defs>
          <pattern id="sc-dots" width="8" height="8" patternUnits="userSpaceOnUse">
            <circle cx="4" cy="4" r="1.9" fill="#B9C9EC" />
          </pattern>
        </defs>
        <g transform={transform.toString()}>
          <path d={landPath} fill="url(#sc-dots)" />
          {markers.map((m) => (
            <g
              key={m.code}
              onMouseEnter={() => setHovered(m)}
              onMouseLeave={() => setHovered((h) => (h?.code === m.code ? null : h))}
              className="cursor-pointer"
            >
              <circle cx={m.x} cy={m.y} r={m.r + 7} fill="rgba(31,94,255,0.10)" />
              {pulse ? (
                <circle
                  cx={m.x}
                  cy={m.y}
                  r={m.r}
                  fill="none"
                  stroke="#1F5EFF"
                  strokeWidth={2}
                  vectorEffect="non-scaling-stroke"
                  className="sc-ping"
                  style={{ transformBox: "fill-box", transformOrigin: "center" }}
                />
              ) : null}
              {/* Zone de survol ≥ 24 px, sans grossir le point dessiné. */}
              <circle cx={m.x} cy={m.y} r={Math.max(m.r, 12)} fill="transparent" />
              <circle
                cx={m.x}
                cy={m.y}
                r={m.r}
                fill="#1F5EFF"
                fillOpacity={hovered?.code === m.code ? 0.8 : 0.58}
                stroke="#fff"
                strokeWidth={2}
                vectorEffect="non-scaling-stroke"
              />
            </g>
          ))}
        </g>
      </svg>

      {/* Étiquettes permanentes sur les plus gros marqueurs (markers est trié par rayon décroissant). */}
      {markers.slice(0, labels).map((m) => {
        const [sx, sy] = transform.apply([m.x, m.y]);
        const toLeft = sx / MAP_WIDTH > 0.78;
        const off = m.r + 8;
        return (
          <div
            key={`label-${m.code}`}
            className="pointer-events-none absolute flex items-center gap-[7px] rounded-full border border-sc-line bg-white py-[3px] pr-[11px] pl-1 text-xs font-bold whitespace-nowrap shadow-[0_6px_14px_-6px_rgba(4,18,58,0.3)]"
            style={{
              left: `${(sx / MAP_WIDTH) * 100}%`,
              top: `${(sy / MAP_HEIGHT) * 100}%`,
              transform: toLeft
                ? `translate(calc(-100% - ${off}px), -50%)`
                : `translate(${off}px, -50%)`,
            }}
          >
            <Flag code={m.code} size={20} />
            {countryName(m.code)} · {fmtInt(m.count)}
          </div>
        );
      })}

      {hoveredScreen ? (
        <div
          className="pointer-events-none absolute z-10 -translate-x-1/2 -translate-y-full rounded-xl border border-sc-line bg-white px-3 py-2 text-xs whitespace-nowrap text-sc-text shadow-lg"
          style={{
            left: `${(hoveredScreen[0] / MAP_WIDTH) * 100}%`,
            top: `${(hoveredScreen[1] / MAP_HEIGHT) * 100}%`,
            marginTop: -10,
          }}
        >
          <div className="font-bold">{countryName(hovered!.code)}</div>
          <div className="text-sc-text-secondary">
            {fmtInt(hovered!.count)} personne{hovered!.count > 1 ? "s" : ""}
          </div>
        </div>
      ) : null}

      <div className="absolute top-3 right-3 flex flex-col gap-0.5 rounded-xl border border-sc-line-strong bg-white p-1">
        <button type="button" onClick={() => zoomBy(1.6)} aria-label="Zoomer" className={ctl}>
          +
        </button>
        <button type="button" onClick={() => zoomBy(1 / 1.6)} aria-label="Dézoomer" className={ctl}>
          −
        </button>
        <button type="button" onClick={zoomReset} aria-label="Réinitialiser le zoom" className={ctl}>
          ⟲
        </button>
      </div>

      <div className="pointer-events-none absolute bottom-3 left-3 rounded-lg bg-white/80 px-2.5 py-1 text-[11px] text-sc-text-muted backdrop-blur">
        Ctrl/⌘ + molette ou pincer pour zoomer · glisser pour déplacer
      </div>
    </div>
  );
}
