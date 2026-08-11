import Link from "next/link";
import { ArrowRight } from "lucide-react";
import {
  getCallsSeries,
  getCountries,
  getLanguages,
  getMessagesSeries,
  getNewUsersSeries,
  getOverview,
} from "@/lib/metrics";
import { countryName, flag, fmtInt, languageName } from "@/lib/format";
import { KpiCard, KpiGrid } from "@/components/kpi-card";
import { PageHeader, Section } from "@/components/section";
import { SeriesChart } from "@/components/charts/series";
import { RankBars } from "@/components/rank-bars";

export default async function OverviewPage() {
  const [overview, calls, newUsers, messages, countries, languages] =
    await Promise.all([
      getOverview(),
      getCallsSeries(14),
      getNewUsersSeries(14),
      getMessagesSeries(14),
      getCountries(30),
      getLanguages(),
    ]);

  const { live } = overview;

  return (
    <>
      <PageHeader
        title="Vue d'ensemble"
        subtitle="L'état de Swayco en un écran."
      />

      <Section
        title="Maintenant"
        hint="Présence temps réel — détail sur la page Live."
        right={
          <Link
            href="/live"
            className="flex items-center gap-1 text-sm text-sc-accent hover:underline"
          >
            Page Live <ArrowRight className="h-3.5 w-3.5" />
          </Link>
        }
      >
        <KpiGrid>
          <KpiCard
            label="En ligne"
            value={fmtInt(live.onlineUsers)}
            sub="App ouverte à l'instant"
            tone="online"
          />
          <KpiCard
            label="Appels en cours"
            value={fmtInt(live.liveCalls)}
            sub={`${fmtInt(live.usersInCall)} personnes en appel`}
            tone="accent"
          />
          <KpiCard
            label="Sonneries"
            value={fmtInt(live.ringing)}
            sub="Appels en train de sonner"
          />
          <KpiCard
            label="Actifs aujourd'hui"
            value={fmtInt(overview.dauToday)}
            sub="Utilisateurs distincts (DAU)"
          />
        </KpiGrid>
      </Section>

      <Section title="Croissance" hint="Le socle d'utilisateurs.">
        <KpiGrid>
          <KpiCard
            label="Utilisateurs"
            value={fmtInt(overview.totalUsers)}
            sub="Total inscrits"
          />
          <KpiCard
            label="Nouveaux (24 h)"
            value={fmtInt(overview.newUsers24h)}
            sub={`${fmtInt(overview.newUsers7d)} sur 7 jours`}
          />
          <KpiCard
            label="Appels (24 h)"
            value={fmtInt(overview.calls24h)}
            sub="Appels démarrés"
          />
          <KpiCard
            label="Messages (24 h)"
            value={fmtInt(overview.messages24h)}
            sub="Messages envoyés"
          />
        </KpiGrid>
      </Section>

      <Section title="Sur 14 jours" hint="Une mesure par graphique.">
        <div className="grid gap-4 lg:grid-cols-2">
          <SeriesChart
            title="Appels démarrés"
            hint="Événement call_started, par jour."
            data={calls}
          />
          <SeriesChart
            title="Nouveaux utilisateurs"
            hint="Inscriptions, par jour."
            data={newUsers}
          />
          <SeriesChart
            title="Messages envoyés"
            hint="Toutes conversations confondues."
            data={messages}
          />
        </div>
      </Section>

      <Section
        title="Où sont-ils"
        hint="Pays sur 30 jours ; langues déclarées sur les profils."
      >
        <div className="grid gap-4 lg:grid-cols-2">
          <div>
            <h3 className="mb-2 text-sm font-bold text-sc-text">
              Pays les plus actifs
            </h3>
            <RankBars
              unit="pers."
              items={countries.slice(0, 8).map((c) => ({
                label: countryName(c.code),
                value: c.users,
                lead: flag(c.code),
              }))}
            />
          </div>
          <div>
            <h3 className="mb-2 text-sm font-bold text-sc-text">
              Langues parlées
            </h3>
            <RankBars
              unit="profils"
              items={languages.slice(0, 8).map((l) => ({
                label: languageName(l.label),
                value: l.value,
              }))}
            />
          </div>
        </div>
      </Section>
    </>
  );
}
