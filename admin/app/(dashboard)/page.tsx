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
import { countryName, fmtInt, languageName } from "@/lib/format";
import { buildWorldMap } from "@/lib/geo";
import { PageHero } from "@/components/page-hero";
import { KpiStrip } from "@/components/kpi-card";
import { Section } from "@/components/section";
import { SeriesChart } from "@/components/charts/series";
import { RankTabs } from "@/components/rank-tabs";
import { Card } from "@/components/ui/card";
import { Flag } from "@/components/flag";
import { WorldMap } from "@/components/world-map";

// Page de référence : toutes les autres pages suivent le même patron
// (PageHero → Sections), voir INSTRUCTIONS.md. Les requêtes sont inchangées.
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
  const worldMap = buildWorldMap(countries);

  return (
    <>
      <PageHero
        title="Vue d'ensemble"
        subtitle="L'état de Swayco en un écran."
        right={
          <Link
            href="/live"
            className="flex items-center gap-1.5 self-start rounded-full bg-sc-lemon px-5 py-3 text-sm font-extrabold text-sc-text"
          >
            Page Live <ArrowRight className="h-[19px] w-[19px]" />
          </Link>
        }
        kpis={{
          chip: "MAINTENANT",
          hint: "Présence temps réel — détail sur la page Live.",
          items: [
            {
              label: "En ligne",
              value: fmtInt(live.onlineUsers),
              sub: "App ouverte à l'instant",
              lemon: true,
            },
            {
              label: "Appels en cours",
              value: fmtInt(live.liveCalls),
              sub: `${fmtInt(live.usersInCall)} personnes en appel`,
            },
            {
              label: "Sonneries",
              value: fmtInt(live.ringing),
              sub: "Appels en train de sonner",
            },
            {
              label: "Actifs aujourd'hui",
              value: fmtInt(overview.dauToday),
              sub: "Utilisateurs distincts (DAU)",
            },
          ],
        }}
      />

      <Section title="Croissance" hint="Le socle d'utilisateurs.">
        <KpiStrip
          items={[
            { label: "Utilisateurs", value: fmtInt(overview.totalUsers), sub: "Total inscrits" },
            {
              label: "Nouveaux (24 h)",
              value: fmtInt(overview.newUsers24h),
              sub: `${fmtInt(overview.newUsers7d)} sur 7 jours`,
            },
            { label: "Appels (24 h)", value: fmtInt(overview.calls24h), sub: "Appels démarrés" },
            { label: "Messages (24 h)", value: fmtInt(overview.messages24h), sub: "Messages envoyés" },
          ]}
        />
      </Section>

      <Section title="Sur 14 jours" hint="Une mesure par graphique.">
        <div className="grid gap-4 lg:grid-cols-3">
          <SeriesChart title="Appels démarrés" hint="Événement call_started, par jour." data={calls} />
          <SeriesChart title="Nouveaux utilisateurs" hint="Inscriptions, par jour." data={newUsers} />
          <SeriesChart title="Messages envoyés" hint="Toutes conversations confondues." data={messages} />
        </div>
      </Section>

      <Section
        title="Où sont-ils"
        hint="Pays sur 30 jours — un point par pays actif, taille proportionnelle au nombre de personnes."
      >
        <div className="grid items-start gap-4 lg:grid-cols-[minmax(0,1.6fr)_minmax(0,1fr)]">
          <Card className="p-4">
            <WorldMap {...worldMap} labels={3} />
          </Card>
          <RankTabs
            countries={countries.slice(0, 8).map((c) => ({
              label: countryName(c.code),
              value: c.users,
              lead: <Flag code={c.code} size={24} />,
            }))}
            languages={languages.slice(0, 8).map((l) => ({
              label: languageName(l.label),
              value: l.value,
              code: l.label.toUpperCase(),
            }))}
          />
        </div>
      </Section>
    </>
  );
}
