import { cn } from "@/lib/utils";

/**
 * Bloc titré. `hint` = la phrase qui explique la mesure.
 * Plus de marge basse (mb-10) : l'espacement est porté par le layout
 * (flex-col gap-9). PageHeader est SUPPRIMÉ — utiliser <PageHero>.
 */
export function Section({
  title,
  hint,
  right,
  className,
  children,
}: {
  title: string;
  hint?: string;
  right?: React.ReactNode;
  className?: string;
  children: React.ReactNode;
}) {
  return (
    <section className={className}>
      <div className="mb-4 flex items-end justify-between gap-4">
        <div>
          <h2 className="text-lg font-semibold text-sc-text">{title}</h2>
          {hint ? (
            <p className="mt-1 max-w-[900px] text-sm leading-relaxed text-sc-text-muted">
              {hint}
            </p>
          ) : null}
        </div>
        {right}
      </div>
      {children}
    </section>
  );
}

/** Titre de carte (h3) utilisé dans les cartes de classement et les donuts. */
export function CardTitle({
  className,
  children,
}: {
  className?: string;
  children: React.ReactNode;
}) {
  return (
    <h3 className={cn("text-[15px] font-extrabold text-sc-text", className)}>
      {children}
    </h3>
  );
}
