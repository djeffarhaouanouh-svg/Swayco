"use client";

import { useEffect, useRef } from "react";
import type { GlobeData } from "@/lib/globe";
import { countryName, fmtInt } from "@/lib/format";

/**
 * Globe 3D en points de la direction 1c (remplace <WorldMap> si retenu).
 *
 * - Rendu <canvas> 2D, projection orthographique calculée à chaque image :
 *   aucune dépendance (pas de three.js). Les points viennent de buildGlobe().
 * - Tourne seul (6°/s). Glisser = faire tourner / incliner ; il reprend
 *   1,2 s après le lâcher. Boutons + − ⟲ et Ctrl/⌘ + molette = zoom.
 * - `pulse` : anneau qui pulse sur chaque marqueur (page Live).
 * - `arcs`  : un arc de grand cercle par appel réel en cours entre deux pays
 *   (`routes`), avec un point jaune qui voyage (page Live).
 * - `labels`: nombre d'étiquettes permanentes (drapeau + pays + nombre) sur
 *   les plus gros marqueurs ; le survol en affiche une pour les autres.
 * - prefers-reduced-motion : plus de rotation auto ni d'animation.
 * - La boucle s'arrête quand le globe est hors écran.
 *
 * Le conteneur prend la taille de son parent : le mettre dans une <Card
 * className="relative overflow-hidden p-0"> (hauteur fixée ici : `height`).
 */
type Props = GlobeData & {
  pulse?: boolean;
  arcs?: boolean;
  labels?: number;
  height?: number;
};

const RAD = Math.PI / 180;
const TAU = Math.PI * 2;
const BLUE = "#1F5EFF";
const INK = "#04123A";
const clamp = (v: number, a: number, b: number) => Math.max(a, Math.min(b, v));

export function Globe(props: Props) {
  const { height = 540 } = props;
  const boxRef = useRef<HTMLDivElement>(null);
  const cvRef = useRef<HTMLCanvasElement>(null);
  // Les props changent à chaque rafraîchissement serveur (Live) : on les lit
  // via une ref pour ne pas relancer l'effet (et donc la rotation).
  const live = useRef(props);
  live.current = props;
  const api = useRef({ zoomBy: (_f: number) => {}, reset: () => {} });

  useEffect(() => {
    const box = boxRef.current!;
    const cv = cvRef.current!;
    const ctx = cv.getContext("2d")!;
    // next/font renomme la famille : on lit celle réellement appliquée au conteneur.
    const family = getComputedStyle(box).fontFamily || "sans-serif";
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    const st = {
      lon: 14,
      lat: 22,
      zoom: 1,
      zoomT: 1,
      R: 240,
      resumeAt: 0,
      visible: true,
      hover: null as string | null,
      drag: null as null | { x: number; y: number; lon: number; lat: number },
      hit: [] as { code: string; x: number; y: number; r: number }[],
    };

    // Points : sinus / cosinus précalculés (recalculés si les données changent).
    const pre = {
      src: null as number[] | null,
      act: null as number[] | null,
      lon: new Float32Array(0),
      sl: new Float32Array(0),
      cl: new Float32Array(0),
      on: new Uint8Array(0),
    };
    const prepare = (d: Props) => {
      const n = d.dots.length / 2;
      pre.lon = new Float32Array(n);
      pre.sl = new Float32Array(n);
      pre.cl = new Float32Array(n);
      pre.on = new Uint8Array(n);
      for (let i = 0; i < n; i++) {
        const la = d.dots[2 * i + 1] * RAD;
        pre.lon[i] = d.dots[2 * i] * RAD;
        pre.sl[i] = Math.sin(la);
        pre.cl[i] = Math.cos(la);
      }
      d.active.forEach((i) => (pre.on[i] = 1));
      pre.src = d.dots;
      pre.act = d.active;
    };

    const flags = new Map<string, HTMLImageElement>();
    const flag = (code: string) => {
      let im = flags.get(code);
      if (!im) {
        im = new Image();
        im.src = `https://flagcdn.com/w40/${code.toLowerCase()}.png`;
        flags.set(code, im);
      }
      return im;
    };

    api.current = {
      zoomBy: (f) => (st.zoomT = clamp(st.zoomT * f, 0.7, 1.8)),
      reset: () => {
        st.zoomT = 1;
        st.lon = 14;
        st.lat = 22;
      },
    };

    // ── interactions ──────────────────────────────────────────────
    const down = (e: PointerEvent) => {
      cv.setPointerCapture(e.pointerId);
      cv.style.cursor = "grabbing";
      st.drag = { x: e.clientX, y: e.clientY, lon: st.lon, lat: st.lat };
    };
    const move = (e: PointerEvent) => {
      if (st.drag) {
        st.lon = st.drag.lon - ((e.clientX - st.drag.x) / st.R) * (180 / Math.PI);
        st.lat = clamp(st.drag.lat + ((e.clientY - st.drag.y) / st.R) * (180 / Math.PI), -55, 60);
        return;
      }
      const r = cv.getBoundingClientRect();
      const x = e.clientX - r.left;
      const y = e.clientY - r.top;
      let best: string | null = null;
      let bd = 1e9;
      for (const h of st.hit) {
        const dd = Math.hypot(h.x - x, h.y - y);
        if (dd < h.r + 8 && dd < bd) {
          bd = dd;
          best = h.code;
        }
      }
      st.hover = best;
    };
    const up = () => {
      st.drag = null;
      st.resumeAt = performance.now() + 1200;
      cv.style.cursor = "grab";
    };
    const leave = () => (st.hover = null);
    const wheel = (e: WheelEvent) => {
      if (!e.ctrlKey && !e.metaKey) return; // sinon la page défile normalement
      e.preventDefault();
      st.zoomT = clamp(st.zoomT * (e.deltaY < 0 ? 1.08 : 1 / 1.08), 0.7, 1.8);
    };
    cv.addEventListener("pointerdown", down);
    cv.addEventListener("pointermove", move);
    cv.addEventListener("pointerup", up);
    cv.addEventListener("pointercancel", up);
    cv.addEventListener("pointerleave", leave);
    box.addEventListener("wheel", wheel, { passive: false });
    const io = new IntersectionObserver(([en]) => (st.visible = en.isIntersecting));
    io.observe(box);

    // ── dessin ────────────────────────────────────────────────────
    let raf = 0;
    let last = performance.now();
    const t0 = last;

    const frame = (now: number) => {
      raf = requestAnimationFrame(frame);
      const dt = Math.min(0.05, (now - last) / 1000);
      last = now;
      if (!st.visible) return;
      const d = live.current;
      if (pre.src !== d.dots || pre.act !== d.active) prepare(d);

      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      const w = box.clientWidth;
      const h = box.clientHeight;
      if (!w || !h) return;
      if (cv.width !== Math.round(w * dpr) || cv.height !== Math.round(h * dpr)) {
        cv.width = Math.round(w * dpr);
        cv.height = Math.round(h * dpr);
      }

      if (!st.drag && !reduce && now >= st.resumeAt) {
        st.lon -= 6 * dt;
        st.lat += (22 - st.lat) * Math.min(1, dt * 0.8);
      }
      st.zoom += (st.zoomT - st.zoom) * Math.min(1, dt * 10);

      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.clearRect(0, 0, w, h);
      const R = (Math.min(w, h) / 2) * 0.8 * st.zoom;
      const cx = w / 2;
      const cy = h / 2 + 4;
      st.R = R;
      const lon0 = st.lon * RAD;
      const lat0 = st.lat * RAD;
      const sp0 = Math.sin(lat0);
      const cp0 = Math.cos(lat0);
      const T = (now - t0) / 1000;

      // projection orthographique : [x, y, profondeur] (profondeur > 0 = face visible)
      const proj = (lon: number, sl: number, cl: number): [number, number, number] => {
        const cd = Math.cos(lon - lon0);
        return [cl * Math.sin(lon - lon0), cp0 * sl - sp0 * cl * cd, sp0 * sl + cp0 * cl * cd];
      };
      const ll = (lo: number, la: number) => proj(lo * RAD, Math.sin(la * RAD), Math.cos(la * RAD));

      // lueur bleue autour du globe
      let g = ctx.createRadialGradient(cx, cy, R * 0.9, cx, cy, R * 1.4);
      g.addColorStop(0, "rgba(31,94,255,.2)");
      g.addColorStop(1, "rgba(31,94,255,0)");
      ctx.fillStyle = g;
      ctx.fillRect(0, 0, w, h);

      // sphère
      g = ctx.createRadialGradient(cx - R * 0.3, cy - R * 0.35, R * 0.1, cx, cy, R);
      g.addColorStop(0, "#FFFFFF");
      g.addColorStop(1, "#E4ECFC");
      ctx.beginPath();
      ctx.arc(cx, cy, R, 0, TAU);
      ctx.fillStyle = g;
      ctx.fill();
      const limb = ctx.createRadialGradient(cx, cy, R * 0.72, cx, cy, R);
      limb.addColorStop(0, "rgba(31,94,255,0)");
      limb.addColorStop(1, "rgba(31,94,255,.12)");
      ctx.fillStyle = limb;
      ctx.fill();

      // points : 3 niveaux d'opacité selon la profondeur, pays actifs en bleu
      const base = R * 0.0088;
      const plain = [new Path2D(), new Path2D(), new Path2D()];
      const act = [new Path2D(), new Path2D(), new Path2D()];
      const back = new Path2D();
      for (let i = 0; i < pre.lon.length; i++) {
        const q = proj(pre.lon[i], pre.sl[i], pre.cl[i]);
        const X = cx + R * q[0];
        const Y = cy - R * q[1];
        if (q[2] > 0) {
          const r = base * (0.5 + 0.5 * q[2]);
          const P = (pre.on[i] ? act : plain)[q[2] < 0.35 ? 0 : q[2] < 0.7 ? 1 : 2];
          P.moveTo(X + r, Y);
          P.arc(X, Y, r, 0, TAU);
        } else {
          back.moveTo(X + base * 0.5, Y);
          back.arc(X, Y, base * 0.5, 0, TAU);
        }
      }
      ctx.fillStyle = "rgba(110,140,215,.09)";
      ctx.fill(back);
      ["rgba(160,182,228,.35)", "rgba(160,182,228,.62)", "rgba(146,170,224,.95)"].forEach((c, i) => {
        ctx.fillStyle = c;
        ctx.fill(plain[i]);
      });
      [ "rgba(31,94,255,.45)", "rgba(31,94,255,.75)", BLUE ].forEach((c, i) => {
        ctx.fillStyle = c;
        ctx.fill(act[i]);
      });
      ctx.beginPath();
      ctx.arc(cx, cy, R, 0, TAU);
      ctx.lineWidth = 1.5;
      ctx.strokeStyle = "rgba(31,94,255,.22)";
      ctx.stroke();

      const markers = d.markers;
      const max = Math.max(1, ...markers.map((m) => m.count));

      // arcs de grand cercle : un par appel réel entre deux pays (Live)
      if (d.arcs) {
        d.routes.forEach((route, k) => {
          const a = ll(route.from.lon, route.from.lat);
          const b = ll(route.to.lon, route.to.lat);
          const dot = clamp(a[0] * b[0] + a[1] * b[1] + a[2] * b[2], -1, 1);
          const om = Math.acos(dot);
          const so = Math.sin(om) || 1;
          const N = 44;
          const pts: [number, number, number][] = [];
          for (let i = 0; i <= N; i++) {
            const t = i / N;
            const s1 = Math.sin((1 - t) * om) / so;
            const s2 = Math.sin(t * om) / so;
            // l'arc « décolle » de la surface : 32 % au sommet, moins sur les courts trajets
            const al = 1 + 0.32 * Math.sin(Math.PI * t) * Math.min(1, om / 1.1);
            pts.push([
              (s1 * a[0] + s2 * b[0]) * al,
              (s1 * a[1] + s2 * b[1]) * al,
              (s1 * a[2] + s2 * b[2]) * al,
            ]);
          }
          ctx.lineWidth = 2;
          ctx.lineCap = "round";
          ctx.strokeStyle = "rgba(31,94,255,.5)";
          for (let i = 0; i < N; i++) {
            if (pts[i][2] > 0.02 && pts[i + 1][2] > 0.02) {
              ctx.beginPath();
              ctx.moveTo(cx + R * pts[i][0], cy - R * pts[i][1]);
              ctx.lineTo(cx + R * pts[i + 1][0], cy - R * pts[i + 1][1]);
              ctx.stroke();
            }
          }
          if (reduce) return;
          const p = pts[Math.min(N, Math.floor(((T / 3.2 + k * 0.21) % 1) * N))];
          if (p[2] > 0.02) {
            const px = cx + R * p[0];
            const py = cy - R * p[1];
            ctx.beginPath();
            ctx.arc(px, py, 8, 0, TAU);
            ctx.fillStyle = "rgba(244,255,31,.35)";
            ctx.fill();
            ctx.beginPath();
            ctx.arc(px, py, 4.2, 0, TAU);
            ctx.fillStyle = "#F4FF1F";
            ctx.fill();
            ctx.lineWidth = 1.5;
            ctx.strokeStyle = BLUE;
            ctx.stroke();
          }
        });
      }

      // marqueurs
      st.hit = [];
      const labelled: { x: number; y: number; r: number; code: string; count: number }[] = [];
      markers.forEach((m, i) => {
        const q = ll(m.lon, m.lat);
        if (q[2] < 0.04) return;
        const X = cx + R * q[0];
        const Y = cy - R * q[1];
        const r = (5 + Math.sqrt(m.count / max) * 13) * (R / 240) * (0.55 + 0.45 * q[2]);
        if (d.pulse && !reduce) {
          const t = (T / 2.2 + i * 0.37) % 1;
          ctx.beginPath();
          ctx.arc(X, Y, r * (1 + t * 1.8), 0, TAU);
          ctx.lineWidth = 2;
          ctx.strokeStyle = `rgba(31,94,255,${(0.6 * (1 - t)).toFixed(2)})`;
          ctx.stroke();
        }
        ctx.beginPath();
        ctx.arc(X, Y, r + 7, 0, TAU);
        ctx.fillStyle = "rgba(31,94,255,.12)";
        ctx.fill();
        ctx.beginPath();
        ctx.arc(X, Y, r, 0, TAU);
        ctx.fillStyle = st.hover === m.code ? "rgba(31,94,255,.82)" : "rgba(31,94,255,.62)";
        ctx.fill();
        ctx.lineWidth = 2;
        ctx.strokeStyle = "#fff";
        ctx.stroke();
        st.hit.push({ code: m.code, x: X, y: Y, r });
        const wantLabel = i < (d.labels ?? 0) || st.hover === m.code;
        if (wantLabel && q[2] > 0.3) labelled.push({ x: X, y: Y, r, code: m.code, count: m.count });
      });

      // étiquettes : drapeau + pays + nombre
      ctx.font = `800 12.5px ${family}`;
      ctx.textBaseline = "middle";
      labelled.forEach((l) => {
        const txt = `${countryName(l.code)} · ${fmtInt(l.count)}`;
        const tw = ctx.measureText(txt).width;
        const pw = tw + 4 + 22 + 8 + 12;
        const off = l.r + 8;
        const toLeft = l.x > cx + R * 0.5;
        const x0 = toLeft ? l.x - off - pw : l.x + off;
        const y0 = l.y - 13;
        ctx.save();
        ctx.shadowColor = "rgba(4,18,58,.28)";
        ctx.shadowBlur = 12;
        ctx.shadowOffsetY = 4;
        ctx.beginPath();
        ctx.roundRect(x0, y0, pw, 26, 13);
        ctx.fillStyle = "#fff";
        ctx.fill();
        ctx.restore();
        ctx.lineWidth = 1;
        ctx.strokeStyle = "rgba(4,18,58,.1)";
        ctx.beginPath();
        ctx.roundRect(x0, y0, pw, 26, 13);
        ctx.stroke();
        const im = flag(l.code);
        if (im.complete && im.naturalWidth) {
          ctx.save();
          ctx.beginPath();
          ctx.roundRect(x0 + 4, l.y - 7.5, 22, 15, 3);
          ctx.clip();
          ctx.drawImage(im, x0 + 4, l.y - 7.5, 22, 15);
          ctx.restore();
        }
        ctx.fillStyle = INK;
        ctx.fillText(txt, x0 + 4 + 22 + 8, l.y + 0.5);
      });
    };
    raf = requestAnimationFrame(frame);

    return () => {
      cancelAnimationFrame(raf);
      io.disconnect();
      box.removeEventListener("wheel", wheel);
      cv.removeEventListener("pointerdown", down);
      cv.removeEventListener("pointermove", move);
      cv.removeEventListener("pointerup", up);
      cv.removeEventListener("pointercancel", up);
      cv.removeEventListener("pointerleave", leave);
    };
  }, []);

  const ctl =
    "flex h-[30px] w-[30px] cursor-pointer items-center justify-center rounded-lg text-sm font-extrabold text-sc-text-secondary transition-colors hover:bg-sc-accent/10 hover:text-sc-text";

  return (
    <div
      ref={boxRef}
      className="relative w-full overflow-hidden bg-[radial-gradient(60%_70%_at_50%_52%,rgba(31,94,255,.07),transparent_72%)]"
      style={{ height }}
    >
      <canvas
        ref={cvRef}
        role="img"
        aria-label="Globe des pays actifs"
        className="absolute inset-0 h-full w-full cursor-grab"
        // pan-y : sur mobile, un geste vertical fait défiler la page ;
        // un geste horizontal fait tourner le globe.
        style={{ touchAction: "pan-y" }}
      />
      <div className="absolute top-3.5 right-3.5 flex flex-col gap-0.5 rounded-xl border border-sc-line-strong bg-white p-1">
        <button type="button" onClick={() => api.current.zoomBy(1.2)} aria-label="Zoomer" className={ctl}>
          +
        </button>
        <button type="button" onClick={() => api.current.zoomBy(1 / 1.2)} aria-label="Dézoomer" className={ctl}>
          −
        </button>
        <button type="button" onClick={() => api.current.reset()} aria-label="Recentrer le globe" className={ctl}>
          ⟲
        </button>
      </div>
      <span className="pointer-events-none absolute bottom-3.5 left-4 text-xs text-sc-text-muted">
        Glisser pour faire tourner · Ctrl/⌘ + molette pour zoomer
      </span>
    </div>
  );
}
