import { ArrowRight } from "lucide-react";
import { getLiveSnapshot } from "@/lib/metrics";
import { countryName, fmtDuration, fmtInt, languageName } from "@/lib/format";
import { buildWorldMap } from "@/lib/geo";
import { PageHero } from "@/components/page-hero";
import { Section } from "@/components/section";
import { RankBars } from "@/components/rank-bars";
import { Card } from "@/components/ui/card";
import { Flag } from "@/components/flag";
import { PingDot } from "@/components/ui/chip";
import { GridTable, GridRow, GridEmpty } from "@/components/ui/grid-table";
import { WorldMap } from "@/components/world-map";
import { AutoRefresh } from "@/components/auto-refresh";

const CALL_COLS = "minmax(0,1.1fr) minmax(0,1.2fr) minmax(0,1fr) 120px";

export default async function LivePage() {
  const live = await getLiveSnapshot();
  const worldMap = buildWorldMap(
    live.countries.map((c) => ({ code: c.label, users: c.value })),
  );

  return (
    <>
      <PageHero
        title="Live"
        subtitle="Ce qui se passe sur Swayco à l'instant."
        right={<AutoRefresh seconds={20} />}
        kpis={{
          chip: "EN DIRECT",
          hint: "Mis à jour toutes les 20 secondes.",
          items: [
            {
              label: "En ligne",
              value: fmtInt(live.onlineUsers),
              sub: "Heartbeat de moins de 5 min",
              lemon: true,
            },
            { label: "Appels en cours", value: fmtInt(live.liveCalls) },
            { label: "Personnes en appel", value: fmtInt(live.usersInCall) },
            {
              label: "Sonneries",
              value: fmtInt(live.ringing),
              sub: "incoming_calls, 2 dernières minutes",
            },
          ],
        }}
      />

      <Section
        title="Appels en cours"
        hint="Un call_started sans call_ended correspondant, sur les 6 dernières heures."
      >
        <GridTable
          cols={CALL_COLS}
          head={[
            { label: "Salon" },
            { label: "Langues" },
            { label: "Pays" },
            { label: "Durée", right: true },
          ]}
        >
          {live.calls.length === 0 ? (
            <GridEmpty>Aucun appel en cours.</GridEmpty>
          ) : (
            live.calls.map((c) => (
              <GridRow key={c.room} cols={CALL_COLS}>
                <span className="flex items-center gap-2.5 truncate">
                  <PingDot />
                  <span className="truncate font-mono text-[13px] text-sc-text-secondary">
                    {c.room}
                  </span>
                </span>
                <span className="flex items-center gap-2 font-semibold">
                  {c.langFrom || c.langTo ? (
                    <>
                      {c.langFrom ? languageName(c.langFrom) : "?"}
                      <ArrowRight className="h-[17px] w-[17px] text-sc-accent" />
                      {c.langTo ? languageName(c.langTo) : "?"}
                    </>
                  ) : (
                    "—"
                  )}
                </span>
                <span className="flex items-center gap-2">
                  {c.country ? (
                    <>
                      <Flag code={c.country} />
                      {countryName(c.country)}
                    </>
                  ) : (
                    "—"
                  )}
                </span>
                <span className="sc-nums text-right font-extrabold">
                  {fmtDuration(c.ageSec)}
                </span>
              </GridRow>
            ))
          )}
        </GridTable>
      </Section>

      <Section
        title="Pays et langues actifs"
        hint="Comptés sur les appels en cours ci-dessus."
      >
        <div className="grid items-start gap-4 lg:grid-cols-[minmax(0,1.7fr)_minmax(0,1fr)]">
          <Card className="relative p-4">
            <WorldMap {...worldMap} pulse labels={4} />
            <span className="absolute bottom-3.5 left-4 flex items-center gap-2 rounded-full bg-sc-text px-3.5 py-[7px] text-[12.5px] font-bold text-white">
              <PingDot />
              {fmtInt(live.liveCalls)} appels · {fmtInt(live.countries.length)} pays
            </span>
          </Card>
          <div className="flex flex-col gap-4">
            <RankBars
              title="Pays"
              unit="appels"
              items={live.countries.slice(0, 5).map((c) => ({
                label: countryName(c.label),
                value: c.value,
                lead: <Flag code={c.label} size={24} />,
              }))}
              empty="Aucun appel en cours."
            />
            <RankBars
              title="Langues"
              unit="appels"
              items={live.languages.slice(0, 5).map((l) => ({
                label: languageName(l.label),
                value: l.value,
                code: l.label.toUpperCase(),
              }))}
              empty="Aucun appel en cours."
            />
          </div>
        </div>
      </Section>
    </>
  );
}
