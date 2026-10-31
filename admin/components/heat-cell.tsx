import { fmtPct } from "@/lib/format";

/**
 * Cellule de la carte de chaleur des cohortes (page Rétention).
 * `value` = fraction 0..1, ou null si le jalon n'est pas encore atteignable
 * (cellule rayée, tiret).
 * Intensité du bleu : alpha = 0,07 + (pourcentage / 45) × 0,5.
 */
export function HeatCell({ value }: { value: number | null }) {
  if (value === null) {
    return (
      <span className="sc-stripe flex h-10 items-center justify-center rounded-[10px] text-[#8b93ae]">
        —
      </span>
    );
  }
  const alpha = (0.07 + ((value * 100) / 45) * 0.5).toFixed(2);
  return (
    <span
      className="sc-nums flex h-10 items-center justify-center rounded-[10px] font-extrabold"
      style={{ background: `rgba(31,94,255,${alpha})` }}
    >
      {fmtPct(value)}
    </span>
  );
}
