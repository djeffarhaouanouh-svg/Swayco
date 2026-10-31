import { getRetention } from "@/lib/metrics";
import { fmtInt, fmtPct, shortDay } from "@/lib/format";
import { KpiCard, KpiStrip } from "@/components/kpi-card";
import { Section } from "@/components/section";
import { PageHero } from "@/components/page-hero";
import { SeriesChart } from "@/components/charts/series";
import { HeatCell } from "@/components/heat-cell";
import { Card } from "@/components/ui/card";

const COHORT_GRID =
  "grid gap-2 grid-cols-[minmax(0,1.2fr)_repeat(4,minmax(0,1fr))]";

export default async function RetentionPage() {
  const retention = await getRetention(30);
  const dauToday =
    retention.dau.length > 0
      ? retention.dau[retention.dau.length - 1].value
      : 0;

  return (
    <>
      <PageHero
        title="Rétention"
        subtitle="Qui revient, et combien de temps ça dure."
        kpis={{
          chip: "RÉTENTION PAR COHORTE",
          hint: "J1 / J7 / J30, pondérées sur toutes les cohortes assez mûres pour être mesurées.",
          cols: 3,
          items: [
            {
              label: "Rétention J1",
              value: fmtPct(retention.overall.d1),
              lemon: true,
            },
            { label: "Rétention J7", value: fmtPct(retention.overall.d7) },
            { label: "Rétention J30", value: fmtPct(retention.overall.d30) },
          ],
        }}
      />

      <Section
        title="Activité"
        hint="DAU = ouvert l'app aujourd'hui. WAU/MAU = sur 7 / 30 jours. Stickiness = DAU du jour ÷ MAU."
      >
        <KpiStrip
          cols={4}
          items={[
            { label: "DAU", value: fmtInt(dauToday), tone: "accent" },
            { label: "WAU", value: fmtInt(retention.wau) },
            { label: "MAU", value: fmtInt(retention.mau) },
            {
              label: "Stickiness",
              value: fmtPct(retention.stickiness),
              sub: "DAU / MAU",
            },
          ]}
        />
      </Section>

      <div className="grid items-start gap-6 lg:grid-cols-[minmax(0,1.7fr)_minmax(0,1fr)]">
        <Section title="Utilisateurs actifs par jour">
          <SeriesChart title="DAU" data={retention.dau} plotClassName="h-60" />
        </Section>

        <Section
          title="Ce qu'on perd"
          hint="Sur les utilisateurs déjà vus au moins une fois."
        >
          <div className="flex flex-col gap-4">
            <KpiCard
              label="Venus une seule fois"
              value={fmtInt(retention.oneAndDone)}
              sub={
                retention.trackedUsers > 0
                  ? fmtPct(retention.oneAndDone / retention.trackedUsers)
                  : undefined
              }
            />
            <KpiCard
              label="Utilisateurs perdus"
              value={fmtInt(retention.lostUsers)}
              sub="Pas revenus depuis 30 j"
            />
            <KpiCard
              label="Suivis au total"
              value={fmtInt(retention.trackedUsers)}
            />
          </div>
        </Section>
      </div>

      <Section
        title="Cohortes"
        hint="Une ligne par jour de première ouverture. Une cellule vide = ce jalon n'est pas encore atteignable pour cette cohorte."
      >
        <Card className="overflow-x-auto pb-3">
          <div
            className={`${COHORT_GRID} px-6 pt-3.5 pb-2 text-xs font-bold tracking-[0.08em] text-sc-text-muted uppercase`}
          >
            <span>Cohorte</span>
            <span className="pr-3.5 text-right">Taille</span>
            <span className="text-center">J1</span>
            <span className="text-center">J7</span>
            <span className="text-center">J30</span>
          </div>
          {retention.cohorts.map((c) => (
            <div
              key={c.cohort}
              className={`${COHORT_GRID} items-center px-6 py-[5px] text-sm`}
            >
              <span className="font-semibold">{shortDay(c.cohort)}</span>
              <span className="sc-nums pr-3.5 text-right text-sc-text-muted">
                {fmtInt(c.size)}
              </span>
              <HeatCell value={c.d1} />
              <HeatCell value={c.d7} />
              <HeatCell value={c.d30} />
            </div>
          ))}
        </Card>
      </Section>
    </>
  );
}
