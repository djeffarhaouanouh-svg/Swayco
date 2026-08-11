import { getRetention } from "@/lib/metrics";
import { fmtInt, fmtPct, shortDay } from "@/lib/format";
import { KpiCard, KpiGrid } from "@/components/kpi-card";
import { PageHeader, Section } from "@/components/section";
import { SeriesChart } from "@/components/charts/series";
import { Card } from "@/components/ui/card";

export default async function RetentionPage() {
  const retention = await getRetention(30);
  const dauToday =
    retention.dau.length > 0
      ? retention.dau[retention.dau.length - 1].value
      : 0;

  return (
    <>
      <PageHeader
        title="Rétention"
        subtitle="Qui revient, et combien de temps ça dure."
      />

      <Section title="Rétention par cohorte" hint="J1 / J7 / J30, pondérées sur toutes les cohortes assez mûres pour être mesurées.">
        <KpiGrid cols={3}>
          <KpiCard
            label="Rétention J1"
            value={fmtPct(retention.overall.d1)}
            tone="accent"
          />
          <KpiCard label="Rétention J7" value={fmtPct(retention.overall.d7)} />
          <KpiCard
            label="Rétention J30"
            value={fmtPct(retention.overall.d30)}
          />
        </KpiGrid>
      </Section>

      <Section
        title="Activité"
        hint="DAU = ouvert l'app aujourd'hui. WAU/MAU = sur 7 / 30 jours. Stickiness = DAU du jour ÷ MAU."
      >
        <KpiGrid>
          <KpiCard label="DAU" value={fmtInt(dauToday)} tone="online" />
          <KpiCard label="WAU" value={fmtInt(retention.wau)} />
          <KpiCard label="MAU" value={fmtInt(retention.mau)} />
          <KpiCard
            label="Stickiness"
            value={fmtPct(retention.stickiness)}
            sub="DAU / MAU"
          />
        </KpiGrid>
      </Section>

      <Section title="Utilisateurs actifs par jour">
        <SeriesChart title="DAU" data={retention.dau} />
      </Section>

      <Section
        title="Ce qu'on perd"
        hint="Sur les utilisateurs déjà vus au moins une fois."
      >
        <KpiGrid cols={3}>
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
        </KpiGrid>
      </Section>

      <Section
        title="Cohortes"
        hint="Une ligne par jour de première ouverture. Une cellule vide = ce jalon n'est pas encore atteignable pour cette cohorte."
      >
        <Card className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="text-left text-xs font-semibold text-sc-text-muted uppercase">
                <th className="px-5 py-2.5">Cohorte</th>
                <th className="px-5 py-2.5 text-right">Taille</th>
                <th className="px-5 py-2.5 text-right">J1</th>
                <th className="px-5 py-2.5 text-right">J7</th>
                <th className="px-5 py-2.5 text-right">J30</th>
              </tr>
            </thead>
            <tbody>
              {retention.cohorts.map((c) => (
                <tr
                  key={c.cohort}
                  className="border-t border-white/5 transition-colors hover:bg-white/[0.02]"
                >
                  <td className="px-5 py-2.5 text-sc-text">
                    {shortDay(c.cohort)}
                  </td>
                  <td className="sc-nums px-5 py-2.5 text-right text-sc-text-secondary">
                    {fmtInt(c.size)}
                  </td>
                  <td className="sc-nums px-5 py-2.5 text-right text-sc-text-secondary">
                    {c.d1 === null ? "—" : fmtPct(c.d1)}
                  </td>
                  <td className="sc-nums px-5 py-2.5 text-right text-sc-text-secondary">
                    {c.d7 === null ? "—" : fmtPct(c.d7)}
                  </td>
                  <td className="sc-nums px-5 py-2.5 text-right text-sc-text-secondary">
                    {c.d30 === null ? "—" : fmtPct(c.d30)}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </Card>
      </Section>
    </>
  );
}
