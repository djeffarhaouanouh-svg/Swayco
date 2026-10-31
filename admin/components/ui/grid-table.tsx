import { cn } from "@/lib/utils";

/**
 * Tableau en CSS grid (remplace les <table> des pages Live, Tableau global,
 * Comptes IA…). `cols` = valeur de grid-template-columns, partagée entre
 * l'en-tête et chaque ligne pour que les colonnes restent alignées.
 *
 *   <GridTable cols="minmax(0,1fr) 120px" head={[{label:"Salon"},{label:"Durée",right:true}]}>
 *     <GridRow cols="minmax(0,1fr) 120px">…</GridRow>
 *   </GridTable>
 */
export function GridTable({
  cols,
  head,
  children,
  className,
}: {
  cols: string;
  head: { label: string; right?: boolean }[];
  children: React.ReactNode;
  className?: string;
}) {
  return (
    <div className={cn("sc-card overflow-hidden", className)}>
      <div
        className="grid items-center gap-4 px-6 py-3.5 text-xs font-bold tracking-[0.08em] text-sc-text-muted uppercase"
        style={{ gridTemplateColumns: cols }}
      >
        {head.map((h, i) => (
          <span key={i} className={h.right ? "text-right" : undefined}>
            {h.label}
          </span>
        ))}
      </div>
      {children}
    </div>
  );
}

export function GridRow({
  cols,
  children,
}: {
  cols: string;
  children: React.ReactNode;
}) {
  return (
    <div
      className="grid items-center gap-4 border-t border-sc-line px-6 py-3.5 text-[14.5px] transition-colors hover:bg-sc-accent/[0.04]"
      style={{ gridTemplateColumns: cols }}
    >
      {children}
    </div>
  );
}

/** Ligne « vide » d'un tableau (aucun appel, rien pour l'instant…). */
export function GridEmpty({ children }: { children: React.ReactNode }) {
  return (
    <div className="border-t border-sc-line px-6 py-8 text-center text-sm text-sc-text-muted">
      {children}
    </div>
  );
}
