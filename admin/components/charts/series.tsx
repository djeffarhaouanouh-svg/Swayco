"use client";

import {
  Area,
  AreaChart,
  CartesianGrid,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import type { DayPoint } from "@/lib/metrics";
import { fmtInt, shortDay } from "@/lib/format";
import { Card } from "@/components/ui/card";
import { cn } from "@/lib/utils";

const BLUE = "#1F5EFF";
const CYAN = "#18DDEA";
const MUTED = "#5A6382";

/**
 * Une mesure dans le temps. Toujours une seule série par graphique.
 * Direction 1c : trait 2,6 px dégradé bleu → cyan, aire bleue 22 % → 0,
 * grille bleu nuit 7 %, SEUL le dernier point porte un marqueur
 * (disque bleu cerclé de blanc). Le tableau « Voir les valeurs » est conservé.
 *
 * `plotClassName` règle la hauteur du tracé (défaut h-52 ; h-60 pour les
 * graphiques larges des pages Social et Rétention).
 */
export function SeriesChart({
  title,
  hint,
  data,
  plotClassName = "h-52",
}: {
  title: string;
  hint?: string;
  data: DayPoint[];
  plotClassName?: string;
}) {
  const total = data.reduce((s, d) => s + d.value, 0);
  const last = data.length > 0 ? data[data.length - 1] : null;
  const uid = title.replace(/\W+/g, "-").toLowerCase();
  const fillId = `fill-${uid}`;
  const strokeId = `stroke-${uid}`;

  return (
    <Card className="px-[22px] pt-5 pb-4">
      <div className="mb-0.5 flex items-baseline justify-between gap-4">
        <h3 className="text-[15px] font-extrabold text-sc-text">{title}</h3>
        <span className="sc-nums text-[12.5px] text-sc-text-muted">
          {fmtInt(total)} au total
        </span>
      </div>
      {hint ? (
        <p className="mb-3 text-[12.5px] text-sc-text-muted">{hint}</p>
      ) : null}

      <div className={cn("w-full", plotClassName)}>
        <ResponsiveContainer width="100%" height="100%">
          <AreaChart data={data} margin={{ top: 10, right: 14, bottom: 0, left: -12 }}>
            <defs>
              <linearGradient id={fillId} x1="0" y1="0" x2="0" y2="1">
                <stop offset="0%" stopColor={BLUE} stopOpacity={0.22} />
                <stop offset="100%" stopColor={BLUE} stopOpacity={0} />
              </linearGradient>
              <linearGradient id={strokeId} x1="0" y1="0" x2="1" y2="0">
                <stop offset="0%" stopColor={BLUE} />
                <stop offset="100%" stopColor={CYAN} />
              </linearGradient>
            </defs>
            <CartesianGrid stroke="rgba(4,18,58,0.07)" strokeWidth={1} vertical={false} />
            <XAxis
              dataKey="day"
              tickFormatter={shortDay}
              tick={{ fill: MUTED, fontSize: 11 }}
              tickLine={false}
              axisLine={{ stroke: "rgba(4,18,58,0.10)" }}
              minTickGap={24}
            />
            <YAxis
              allowDecimals={false}
              width={44}
              tick={{ fill: MUTED, fontSize: 11 }}
              tickLine={false}
              axisLine={false}
              tickFormatter={(v) => fmtInt(Number(v))}
            />
            <Tooltip
              cursor={{ stroke: "rgba(4,18,58,0.22)", strokeWidth: 1 }}
              contentStyle={{
                background: "#fff",
                border: "1px solid rgba(4,18,58,0.10)",
                borderRadius: 12,
                fontSize: 12,
                color: "#04123A",
                boxShadow: "0 10px 24px -10px rgba(4,18,58,0.25)",
              }}
              labelFormatter={(l) => shortDay(String(l))}
              formatter={(v) => [fmtInt(Number(v)), title]}
            />
            <Area
              type="monotone"
              dataKey="value"
              stroke={`url(#${strokeId})`}
              strokeWidth={2.6}
              strokeLinecap="round"
              strokeLinejoin="round"
              fill={`url(#${fillId})`}
              // Seul le dernier point a un marqueur.
              // eslint-disable-next-line @typescript-eslint/no-explicit-any
              dot={(p: any) =>
                p.index === data.length - 1 ? (
                  <circle
                    key="end"
                    cx={p.cx}
                    cy={p.cy}
                    r={6}
                    fill={BLUE}
                    stroke="#fff"
                    strokeWidth={3}
                  />
                ) : (
                  <g key={p.index} />
                )
              }
              activeDot={{ r: 5, fill: BLUE, stroke: "#fff", strokeWidth: 2 }}
            />
          </AreaChart>
        </ResponsiveContainer>
      </div>

      {last ? (
        <div className="mt-3 border-t border-sc-line pt-2.5 text-[12.5px] text-sc-text-muted">
          Dernier jour ({shortDay(last.day)}) :{" "}
          <span className="font-bold text-sc-text">{fmtInt(last.value)}</span>
        </div>
      ) : null}

      <SeriesTable data={data} title={title} />
    </Card>
  );
}

/** Le jumeau accessible du tracé — chaque valeur lisible sans survol. */
function SeriesTable({ data, title }: { data: DayPoint[]; title: string }) {
  return (
    <details className="group mt-2.5">
      <summary className="cursor-pointer list-none text-xs text-sc-text-muted transition-colors hover:text-sc-text">
        <span className="group-open:hidden">▸ Voir les valeurs</span>
        <span className="hidden group-open:inline">▾ Masquer les valeurs</span>
      </summary>
      <div className="mt-2 max-h-48 overflow-y-auto">
        <table className="sc-nums w-full text-xs">
          <thead className="sticky top-0 bg-white text-left text-sc-text-muted">
            <tr>
              <th className="py-1 font-medium">Jour</th>
              <th className="py-1 text-right font-medium">{title}</th>
            </tr>
          </thead>
          <tbody className="text-sc-text-secondary">
            {[...data].reverse().map((d) => (
              <tr key={d.day} className="border-t border-sc-line">
                <td className="py-1">{shortDay(d.day)}</td>
                <td className="py-1 text-right">{fmtInt(d.value)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </details>
  );
}
