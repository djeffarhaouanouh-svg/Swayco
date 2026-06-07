import { getCosts, getReferralStats } from "@/lib/metrics";
import { SectionHeader } from "@/components/section";
import { KpiCard } from "@/components/kpi-card";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { StatList } from "@/components/stat-list";
import { fmtEur, fmtEur2, fmtInt, fmtMinutes, fmtUsd } from "@/lib/format";

export default async function MonetisationPage() {
  const [c, r] = await Promise.all([getCosts(30), getReferralStats()]);

  return (
    <>
      <SectionHeader
        title="Monétisation"
        description="Revenu récurrent, coûts d'infrastructure et marge — fenêtre 30 j."
      />

      {!c.ratesConfigured ? (
        <div className="mb-6 rounded-lg border border-amber-900/60 bg-amber-950/30 px-4 py-3 text-sm text-amber-300">
          Taux de coût non configurés. Renseignez{" "}
          <code>COST_REALTIME_USD_PER_MIN</code>,{" "}
          <code>COST_LIVEKIT_USD_PER_MIN</code> et{" "}
          <code>COST_TEXT_USD_PER_1K_TOKENS</code> dans{" "}
          <code>admin/.env.local</code> (depuis les tarifs officiels OpenAI /
          LiveKit) pour activer le calcul des coûts et de la marge.
        </div>
      ) : null}

      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <KpiCard
          label="MRR"
          value={fmtEur(c.mrrEur)}
          sub="revenu mensuel récurrent"
          tone="good"
        />
        <KpiCard
          label="Coût infra"
          value={fmtEur(c.costTotalEur)}
          sub={`${c.windowDays} j`}
        />
        <KpiCard
          label="Marge"
          value={fmtEur(c.marginEur)}
          sub="MRR − coût"
          tone={c.marginEur >= 0 ? "good" : "bad"}
        />
        <KpiCard
          label="Abonnés payants"
          value={fmtInt(c.plusCount + c.ultraPlusCount)}
          sub={`${fmtInt(c.plusCount)} Plus · ${fmtInt(c.ultraPlusCount)} Ultra+`}
        />
      </div>

      <div className="mt-6 grid gap-4 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>Répartition des coûts — {c.windowDays} j</CardTitle>
          </CardHeader>
          <CardContent>
            <StatList
              items={[
                {
                  label: "OpenAI Realtime (traduction voix)",
                  value: fmtUsd(c.costRealtimeUsd),
                },
                {
                  label: "LiveKit (transport WebRTC)",
                  value: fmtUsd(c.costLivekitUsd),
                },
                {
                  label: "OpenAI texte (gpt-4.1-mini)",
                  value: fmtUsd(c.costTextUsd),
                },
                {
                  label: "Total converti en euros",
                  value: fmtEur(c.costTotalEur),
                  tone: "bad",
                },
              ]}
            />
          </CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle>Abonnements</CardTitle>
          </CardHeader>
          <CardContent>
            <StatList
              items={[
                { label: "Free", value: fmtInt(c.freeCount), tone: "muted" },
                {
                  label: `Plus (${fmtEur2(c.pricePlus)})`,
                  value: fmtInt(c.plusCount),
                },
                {
                  label: `Ultra Plus (${fmtEur2(c.priceUltraPlus)})`,
                  value: fmtInt(c.ultraPlusCount),
                },
                {
                  label: "MRR estimé",
                  value: fmtEur(c.mrrEur),
                  tone: "good",
                },
              ]}
            />
          </CardContent>
        </Card>
      </div>

      <div className="mt-6 grid gap-4 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>Usage facturable — {c.windowDays} j</CardTitle>
          </CardHeader>
          <CardContent>
            <StatList
              items={[
                {
                  label: "Minutes d'appel cumulées",
                  value: fmtMinutes(c.callMinutes),
                },
                {
                  label: "Minutes de traduction (OpenAI Realtime)",
                  value: fmtMinutes(c.translationMinutes),
                },
                {
                  label: "Tokens de traduction texte",
                  value: fmtInt(c.textTokens),
                },
              ]}
            />
          </CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle>Parrainage (Invite 3 amis = +30 min)</CardTitle>
          </CardHeader>
          <CardContent>
            <StatList
              items={[
                {
                  label: "Filleuls attribués",
                  value: fmtInt(r.totalAttributed),
                },
                {
                  label: "Parrains actifs",
                  value: fmtInt(r.activeReferrers),
                },
                {
                  label: "Paliers payés (× 3 filleuls)",
                  value: fmtInt(r.bonusTranchesPaid),
                },
                {
                  label: "Minutes offertes",
                  value: fmtMinutes(r.bonusMinutesGranted),
                  tone: "muted",
                },
              ]}
            />
          </CardContent>
        </Card>
      </div>

      <p className="mt-4 text-xs text-zinc-600">
        Coûts = usage mesuré × taux configurés (voir{" "}
        <code className="text-zinc-500">admin/env.example</code> pour les
        sources). Le revenu (MRR) vient des paliers d&apos;abonnement de
        la table <code className="text-zinc-500">profiles</code> ; pour le
        revenu encaissé réel, brancher l&apos;API Stripe.
      </p>
    </>
  );
}
