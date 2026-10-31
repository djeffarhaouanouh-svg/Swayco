import { cn } from "@/lib/utils";

export type HeroKpi = {
  label: string;
  value: string;
  sub?: string;
  /** Le chiffre à mettre en avant : fond jaune plein. Un seul par bandeau. */
  lemon?: boolean;
};

/** Pastille en verre pour le coin haut-droit du bandeau (ex. « 30 derniers jours »). */
export function HeroPill({ children }: { children: React.ReactNode }) {
  return <span className="sc-hero-pill">{children}</span>;
}

/**
 * Bandeau bleu en tête de CHAQUE page du dashboard. Remplace PageHeader.
 * - `kpis` est optionnel (la page Tableau global n'en a pas).
 * - `kpis.chip` = petite étiquette en capitales (MAINTENANT, AMITIÉS, PARC…).
 */
export function PageHero({
  title,
  subtitle,
  right,
  kpis,
}: {
  title: string;
  subtitle?: string;
  right?: React.ReactNode;
  kpis?: {
    chip: string;
    hint?: string;
    cols?: 2 | 3 | 4;
    items: HeroKpi[];
  };
}) {
  const cols = kpis?.cols ?? kpis?.items.length ?? 4;
  return (
    <section className="sc-hero">
      <div className="flex items-start justify-between gap-6">
        <div className="flex flex-col gap-2.5">
          <h1 className="text-[34px] leading-tight font-bold tracking-[-0.03em]">
            {title}
          </h1>
          {subtitle ? (
            <p className="max-w-[760px] text-[15px] leading-normal">{subtitle}</p>
          ) : null}
        </div>
        {right}
      </div>

      {kpis ? (
        <>
          <div className="mt-7 mb-4 flex items-center gap-3">
            <span className="rounded-full bg-white/[0.18] px-3 py-1.5 text-xs font-extrabold tracking-[0.1em] whitespace-nowrap">
              {kpis.chip}
            </span>
            {kpis.hint ? <span className="text-sm">{kpis.hint}</span> : null}
          </div>
          <div
            className="grid gap-3.5"
            style={{ gridTemplateColumns: `repeat(${cols}, minmax(0, 1fr))` }}
          >
            {kpis.items.map((k) => (
              <div
                key={k.label}
                className={cn("sc-hero-kpi")}
                data-lemon={k.lemon ? "" : undefined}
              >
                <div className="text-xs font-extrabold tracking-[0.08em] uppercase">
                  {k.label}
                </div>
                <div className="mt-3 font-display text-[44px] leading-none font-bold tracking-[-0.03em]">
                  {k.value}
                </div>
                {k.sub ? (
                  <div
                    className={cn("mt-2 text-sm", k.lemon && "font-semibold")}
                  >
                    {k.sub}
                  </div>
                ) : null}
              </div>
            ))}
          </div>
        </>
      ) : null}
    </section>
  );
}
