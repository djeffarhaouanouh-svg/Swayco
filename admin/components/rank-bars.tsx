import { Card } from "@/components/ui/card";
import { CardTitle } from "@/components/section";
import { fmtInt } from "@/lib/format";

export type RankItem = {
  label: string;
  value: number;
  /** Drapeau : <Flag code="fr" size={24} />. */
  lead?: React.ReactNode;
  /** Code court de langue (« FR », « JA ») affiché en petit à la place d'un drapeau. */
  code?: string;
};

/**
 * Classement avec barre dégradé bleu → cyan (une ligne = un pays / une langue).
 * Barres proportionnelles au plus grand, pas au total.
 * `title` : titre de la carte (h3). `bare` : sans Card (à l'intérieur d'une autre carte).
 */
export function RankBars({
  items,
  empty = "Aucune donnée sur la période",
  unit,
  title,
  bare = false,
}: {
  items: RankItem[];
  empty?: string;
  unit?: string;
  title?: string;
  bare?: boolean;
}) {
  if (items.length === 0) {
    return bare ? (
      <div className="p-6 text-sm text-sc-text-muted">{empty}</div>
    ) : (
      <Card className="p-6 text-sm text-sc-text-muted">{empty}</Card>
    );
  }
  const max = Math.max(...items.map((i) => i.value), 1);
  const hasLead = items.some((i) => i.lead || i.code);
  const cols = hasLead
    ? "30px 104px minmax(0,1fr) 84px"
    : "minmax(0,128px) minmax(0,1fr) 84px";

  const rows = (
    <>
      {title ? <CardTitle className="px-4 pb-1.5">{title}</CardTitle> : null}
      {items.map((it) => (
        <div
          key={it.label}
          className="grid items-center gap-2.5 px-4 py-[11px]"
          style={{ gridTemplateColumns: cols }}
        >
          {hasLead ? (
            <span className="flex justify-center">
              {it.lead ??
                (it.code ? (
                  <span className="text-[11px] font-extrabold tracking-[0.06em] opacity-60">
                    {it.code}
                  </span>
                ) : null)}
            </span>
          ) : null}
          <span className="truncate text-[14.5px] font-semibold" title={it.label}>
            {it.label}
          </span>
          <span className="sc-track">
            <i style={{ width: `${(it.value / max) * 100}%` }} />
          </span>
          <span className="sc-nums text-right text-sm font-extrabold whitespace-nowrap">
            {fmtInt(it.value)}
            {unit ? (
              <span className="font-medium text-sc-text-muted"> {unit}</span>
            ) : null}
          </span>
        </div>
      ))}
    </>
  );

  return bare ? rows : <Card className="pt-4 pr-2 pb-2 pl-2">{rows}</Card>;
}
