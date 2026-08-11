import { getLiveSnapshot } from "@/lib/metrics";
import { countryName, flag, fmtDuration, fmtInt, languageName } from "@/lib/format";
import { KpiCard, KpiGrid } from "@/components/kpi-card";
import { PageHeader, Section } from "@/components/section";
import { RankBars } from "@/components/rank-bars";
import { Card } from "@/components/ui/card";
import { AutoRefresh } from "@/components/auto-refresh";

export default async function LivePage() {
  const live = await getLiveSnapshot();

  return (
    <>
      <PageHeader
        title="Live"
        subtitle="Ce qui se passe sur Swayco à l'instant."
        right={<AutoRefresh seconds={20} />}
      />

      <KpiGrid>
        <KpiCard
          label="En ligne"
          value={fmtInt(live.onlineUsers)}
          sub="Heartbeat de moins de 5 min"
          tone="online"
        />
        <KpiCard
          label="Appels en cours"
          value={fmtInt(live.liveCalls)}
          tone="accent"
        />
        <KpiCard
          label="Personnes en appel"
          value={fmtInt(live.usersInCall)}
        />
        <KpiCard
          label="Sonneries"
          value={fmtInt(live.ringing)}
          sub="incoming_calls, 2 dernières minutes"
        />
      </KpiGrid>

      <Section
        title="Appels en cours"
        hint="Un call_started sans call_ended correspondant, sur les 6 dernières heures."
        className="mt-10"
      >
        {live.calls.length === 0 ? (
          <Card className="p-6 text-sm text-sc-text-muted">
            Aucun appel en cours.
          </Card>
        ) : (
          <Card className="divide-y divide-white/5 overflow-hidden">
            <div className="grid grid-cols-[1fr_auto_auto_auto] gap-4 px-4 py-2.5 text-xs font-semibold text-sc-text-muted uppercase">
              <span>Salon</span>
              <span>Langues</span>
              <span>Pays</span>
              <span className="text-right">Durée</span>
            </div>
            {live.calls.map((c) => (
              <div
                key={c.room}
                className="grid grid-cols-[1fr_auto_auto_auto] items-center gap-4 px-4 py-3"
              >
                <span className="flex items-center gap-2 truncate text-sm text-sc-text">
                  <span className="relative flex h-2 w-2 shrink-0">
                    <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-sc-online opacity-60" />
                    <span className="relative inline-flex h-2 w-2 rounded-full bg-sc-online" />
                  </span>
                  <span className="truncate font-mono text-xs text-sc-text-secondary">
                    {c.room}
                  </span>
                </span>
                <span className="text-sm text-sc-text-secondary">
                  {c.langFrom || c.langTo
                    ? `${c.langFrom ? languageName(c.langFrom) : "?"} → ${
                        c.langTo ? languageName(c.langTo) : "?"
                      }`
                    : "—"}
                </span>
                <span className="text-sm text-sc-text-secondary">
                  {c.country ? `${flag(c.country)} ${countryName(c.country)}` : "—"}
                </span>
                <span className="sc-nums text-right text-sm font-semibold text-sc-text">
                  {fmtDuration(c.ageSec)}
                </span>
              </div>
            ))}
          </Card>
        )}
      </Section>

      <Section
        title="Pays et langues actifs"
        hint="Comptés sur les appels en cours ci-dessus."
      >
        <div className="grid gap-4 lg:grid-cols-2">
          <RankBars
            items={live.countries.map((c) => ({
              label: countryName(c.label),
              value: c.value,
              lead: flag(c.label),
            }))}
            empty="Aucun appel en cours."
          />
          <RankBars
            items={live.languages.map((l) => ({
              label: languageName(l.label),
              value: l.value,
            }))}
            empty="Aucun appel en cours."
          />
        </div>
      </Section>
    </>
  );
}
