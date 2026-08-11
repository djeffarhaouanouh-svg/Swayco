import { Card } from "@/components/ui/card";
import { fmtInt } from "@/lib/format";

export type RankItem = { label: string; value: number; lead?: string };

/**
 * Ranked list with a proportional bar behind each row — a horizontal bar
 * chart that stays readable at any label length (top countries, top
 * languages). Bars are scaled against the largest value, not the total.
 */
export function RankBars({
  items,
  empty = "Aucune donnée sur la période",
  unit,
}: {
  items: RankItem[];
  empty?: string;
  unit?: string;
}) {
  if (items.length === 0) {
    return (
      <Card className="p-6 text-sm text-sc-text-muted">{empty}</Card>
    );
  }
  const max = Math.max(...items.map((i) => i.value), 1);

  return (
    <Card className="divide-y divide-white/5 overflow-hidden">
      {items.map((it) => (
        <div key={it.label} className="relative px-4 py-3">
          <div
            className="absolute inset-y-0 left-0 bg-sc-accent/12"
            style={{ width: `${(it.value / max) * 100}%` }}
            aria-hidden
          />
          <div className="relative flex items-center justify-between gap-4">
            <span className="flex min-w-0 items-center gap-2 text-sm text-sc-text">
              {it.lead ? (
                <span className="shrink-0 text-base">{it.lead}</span>
              ) : null}
              <span className="truncate">{it.label}</span>
            </span>
            <span className="sc-nums shrink-0 text-sm font-semibold text-sc-text-secondary">
              {fmtInt(it.value)}
              {unit ? <span className="text-sc-text-muted"> {unit}</span> : null}
            </span>
          </div>
        </div>
      ))}
    </Card>
  );
}
