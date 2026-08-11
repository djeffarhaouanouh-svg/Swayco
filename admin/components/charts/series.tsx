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

/**
 * One measure over time. Deliberately single-series: two measures of
 * different scale get two charts, never a second y-axis. With one series
 * there is no legend — the card title already says what is plotted.
 *
 * Mark specs: 2px line, ~10 % area wash, hairline solid grid, an ≥8px
 * end marker ringed in the surface colour, and the endpoint value as the
 * only direct label. Every value is also reachable in the table twin
 * below the plot, so the tooltip never gates a number.
 */
export function SeriesChart({
  title,
  hint,
  data,
  color = "var(--color-sc-accent)",
}: {
  title: string;
  hint?: string;
  data: DayPoint[];
  color?: string;
}) {
  const total = data.reduce((s, d) => s + d.value, 0);
  const last = data.length > 0 ? data[data.length - 1] : null;
  const id = `fill-${title.replace(/\W+/g, "-").toLowerCase()}`;

  return (
    <Card className="p-5">
      <div className="mb-1 flex items-baseline justify-between gap-4">
        <h3 className="text-sm font-bold text-sc-text">{title}</h3>
        <span className="sc-nums text-xs text-sc-text-muted">
          {fmtInt(total)} au total
        </span>
      </div>
      {hint ? (
        <p className="mb-3 text-xs text-sc-text-muted">{hint}</p>
      ) : null}

      {/* Height covers plot + x-axis band, so the axis labels are never
          cut off into a nested scrollbar. */}
      <div className="h-56 w-full">
        <ResponsiveContainer width="100%" height="100%">
          <AreaChart
            data={data}
            margin={{ top: 8, right: 16, bottom: 0, left: -12 }}
          >
            <defs>
              <linearGradient id={id} x1="0" y1="0" x2="0" y2="1">
                <stop offset="0%" stopColor={color} stopOpacity={0.18} />
                <stop offset="100%" stopColor={color} stopOpacity={0.02} />
              </linearGradient>
            </defs>
            <CartesianGrid
              stroke="rgba(255,255,255,0.07)"
              strokeWidth={1}
              vertical={false}
            />
            <XAxis
              dataKey="day"
              tickFormatter={shortDay}
              tick={{ fill: "rgba(245,247,255,0.5)", fontSize: 11 }}
              tickLine={false}
              axisLine={{ stroke: "rgba(255,255,255,0.10)" }}
              minTickGap={24}
            />
            <YAxis
              allowDecimals={false}
              width={44}
              tick={{ fill: "rgba(245,247,255,0.5)", fontSize: 11 }}
              tickLine={false}
              axisLine={false}
              tickFormatter={(v) => fmtInt(Number(v))}
            />
            <Tooltip
              cursor={{ stroke: "rgba(255,255,255,0.22)", strokeWidth: 1 }}
              contentStyle={{
                background: "#141821",
                border: "1px solid rgba(255,255,255,0.14)",
                borderRadius: 12,
                fontSize: 12,
                color: "#f5f7ff",
              }}
              labelFormatter={(l) => shortDay(String(l))}
              formatter={(v) => [fmtInt(Number(v)), title]}
            />
            <Area
              type="monotone"
              dataKey="value"
              stroke={color}
              strokeWidth={2}
              strokeLinecap="round"
              strokeLinejoin="round"
              fill={`url(#${id})`}
              /* Only the endpoint carries a marker + its value — a number
                 on every point is noise. The 2px ring is the surface. */
              dot={false}
              activeDot={{
                r: 4,
                fill: color,
                stroke: "#0e0e0e",
                strokeWidth: 2,
              }}
            />
          </AreaChart>
        </ResponsiveContainer>
      </div>

      {last ? (
        <div className="mt-1 text-xs text-sc-text-secondary">
          Dernier jour ({shortDay(last.day)}) :{" "}
          <span className="font-semibold text-sc-text">
            {fmtInt(last.value)}
          </span>
        </div>
      ) : null}

      <SeriesTable data={data} title={title} />
    </Card>
  );
}

/** The WCAG-clean twin of the plot — every value readable without hover. */
function SeriesTable({ data, title }: { data: DayPoint[]; title: string }) {
  return (
    <details className="mt-3 group">
      <summary className="cursor-pointer list-none text-xs text-sc-text-muted transition-colors hover:text-sc-text-secondary">
        <span className="group-open:hidden">▸ Voir les valeurs</span>
        <span className="hidden group-open:inline">▾ Masquer les valeurs</span>
      </summary>
      <div className="mt-2 max-h-48 overflow-y-auto">
        <table className="sc-nums w-full text-xs">
          <thead className="sticky top-0 bg-sc-bg/80 text-left text-sc-text-muted backdrop-blur">
            <tr>
              <th className="py-1 font-medium">Jour</th>
              <th className="py-1 text-right font-medium">{title}</th>
            </tr>
          </thead>
          <tbody className="text-sc-text-secondary">
            {[...data].reverse().map((d) => (
              <tr key={d.day} className="border-t border-white/5">
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
