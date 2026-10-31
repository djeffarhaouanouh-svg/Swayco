import { Card } from "@/components/ui/card";
import { cn } from "@/lib/utils";

/**
 * Un chiffre clé en carte blanche (colonnes latérales : Fidélité, Ce qu'on perd…).
 * `tone` "accent" ou "online" → chiffre en bleu marque. "plain" → encre.
 * Les deux anciens tons collapsent : il n'y a plus de vert.
 */
export function KpiCard({
  label,
  value,
  sub,
  tone = "plain",
  className,
}: {
  label: string;
  value: string;
  sub?: string;
  tone?: "plain" | "accent" | "online";
  className?: string;
}) {
  return (
    <Card className={cn("px-6 py-5", className)}>
      <div className="text-xs font-bold tracking-[0.08em] text-sc-text-muted uppercase">
        {label}
      </div>
      <div
        className={cn(
          "mt-2.5 font-display text-[32px] font-bold tracking-[-0.03em]",
          tone !== "plain" && "text-sc-accent",
        )}
      >
        {value}
      </div>
      {sub ? <div className="mt-1 text-sm text-sc-text-muted">{sub}</div> : null}
    </Card>
  );
}

/** Grille de KpiCard (conservée pour les cas où on veut des cartes séparées). */
export function KpiGrid({
  cols = 4,
  children,
}: {
  cols?: 3 | 4;
  children: React.ReactNode;
}) {
  return (
    <div
      className={cn(
        "grid gap-4 sm:grid-cols-2",
        cols === 4 ? "lg:grid-cols-4" : "lg:grid-cols-3",
      )}
    >
      {children}
    </div>
  );
}

export type StripItem = {
  label: string;
  value: string;
  sub?: string;
  /** Chiffre en bleu marque : la métrique dont parle la page. */
  tone?: "plain" | "accent";
};

/**
 * Bandeau de chiffres collés (Croissance, Activité, Conversations).
 * Une seule carte, cellules séparées par un trait de 1 px.
 */
export function KpiStrip({
  items,
  cols,
}: {
  items: StripItem[];
  cols?: 2 | 3 | 4;
}) {
  const n = cols ?? items.length;
  return (
    <div
      className="grid gap-px overflow-hidden rounded-[22px] border border-[rgba(4,18,58,0.09)] bg-[rgba(4,18,58,0.09)] shadow-[0_10px_24px_-14px_rgba(4,18,58,0.14)]"
      style={{ gridTemplateColumns: `repeat(${n}, minmax(0, 1fr))` }}
    >
      {items.map((it) => (
        <div key={it.label} className="bg-white px-7 py-6">
          <div className="text-xs font-bold tracking-[0.08em] text-sc-text-muted uppercase">
            {it.label}
          </div>
          <div
            className={cn(
              "mt-3 font-display text-[38px] leading-none font-bold tracking-[-0.03em]",
              it.tone === "accent" && "text-sc-accent",
            )}
          >
            {it.value}
          </div>
          {it.sub ? (
            <div className="mt-2 text-sm text-sc-text-muted">{it.sub}</div>
          ) : null}
        </div>
      ))}
    </div>
  );
}
