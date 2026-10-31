import { fmtInt } from "@/lib/format";

export type DonutSegment = { label: string; value: number; color: string };

/**
 * Anneau de répartition en CSS pur (conic-gradient) — page Social, « Par genre ».
 * Couleurs conseillées dans l'ordre : #1F5EFF, #18DDEA, #F4FF1F.
 */
export function Donut({
  segments,
  centerValue,
  centerLabel,
}: {
  segments: DonutSegment[];
  centerValue: string;
  centerLabel: string;
}) {
  const total = segments.reduce((s, x) => s + x.value, 0) || 1;
  let acc = 0;
  const stops = segments
    .map((s) => {
      const a = (acc / total) * 100;
      acc += s.value;
      const b = (acc / total) * 100;
      return `${s.color} ${a}% ${b}%`;
    })
    .join(", ");

  return (
    <div className="flex items-center gap-[22px]">
      <div
        className="relative h-[132px] w-[132px] shrink-0 rounded-full"
        style={{ background: `conic-gradient(${stops})` }}
      >
        <div className="absolute inset-5 flex flex-col items-center justify-center rounded-full bg-white">
          <span className="font-display text-xl font-bold tracking-[-0.03em]">
            {centerValue}
          </span>
          <span className="text-[11px] text-sc-text-muted">{centerLabel}</span>
        </div>
      </div>
      <ul className="flex flex-1 flex-col gap-3">
        {segments.map((s) => (
          <li key={s.label} className="flex items-center gap-2.5 text-sm">
            <span
              className="h-3 w-3 rounded"
              style={{ background: s.color, boxShadow: "0 0 0 1px rgba(4,18,58,0.2)" }}
            />
            <span className="font-semibold">{s.label}</span>
            <span className="sc-nums ml-auto font-extrabold">{fmtInt(s.value)}</span>
            <span className="w-10 text-right text-sc-text-muted">
              {Math.round((s.value / total) * 100)} %
            </span>
          </li>
        ))}
      </ul>
    </div>
  );
}
