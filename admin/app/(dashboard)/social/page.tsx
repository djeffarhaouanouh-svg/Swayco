import { getActiveSendersSeries, getAdStats, getSocial } from "@/lib/metrics";
import { fmtInt, fmtPct } from "@/lib/format";
import { KpiCard, KpiStrip } from "@/components/kpi-card";
import { CardTitle, Section } from "@/components/section";
import { PageHero } from "@/components/page-hero";
import { SeriesChart } from "@/components/charts/series";
import { RankBars } from "@/components/rank-bars";
import { Donut } from "@/components/donut";
import { Card } from "@/components/ui/card";

const DONUT_COLORS = ["#1F5EFF", "#18DDEA", "#F4FF1F", "#4A5478"];

export default async function SocialPage() {
  const [social, senders, ads] = await Promise.all([
    getSocial(30),
    getActiveSendersSeries(14),
    getAdStats(30),
  ]);

  return (
    <>
      <PageHero
        title="Social"
        subtitle="Amitiés, conversations et messages — fenêtre de 30 jours sauf mention contraire."
        kpis={{
          chip: "AMITIÉS",
          hint: "Les liens entre les personnes.",
          items: [
            {
              label: "Amis (acceptés)",
              value: fmtInt(social.friendsTotal),
              sub: `+${fmtInt(social.friendsNew)} sur 30 j`,
              lemon: true,
            },
            {
              label: "Demandes envoyées",
              value: fmtInt(social.requestsSent),
              sub: `${fmtPct(social.acceptRate)} acceptées`,
            },
            {
              label: "Demandes en attente",
              value: fmtInt(social.pendingRequests),
            },
            { label: "Likes", value: fmtInt(social.likes) },
          ],
        }}
      />

      <Section
        title="Conversations"
        hint="Le signal fort : une conversation avec des messages sur au moins 2 jours différents veut dire que quelqu'un est revenu parler à cette personne."
      >
        <KpiStrip
          cols={3}
          items={[
            {
              label: "Conversations actives",
              value: fmtInt(social.conversationsActive),
              tone: "accent",
            },
            {
              label: "Conversations qui durent",
              value: fmtInt(social.repeatConversations),
              sub: fmtPct(social.repeatConversationRate),
            },
            { label: "Messages envoyés", value: fmtInt(social.messages) },
          ]}
        />
      </Section>

      <div className="grid items-start gap-6 lg:grid-cols-[minmax(0,1.7fr)_minmax(0,1fr)]">
        <Section
          title="Expéditeurs actifs"
          hint="Utilisateurs distincts ayant envoyé au moins un message, par jour."
        >
          <SeriesChart
            title="Expéditeurs actifs par jour"
            data={senders}
            plotClassName="h-60"
          />
        </Section>

        <Section
          title="Fidélité"
          hint="Un utilisateur récurrent a ouvert l'app sur au moins 2 jours différents dans la fenêtre."
        >
          <div className="flex flex-col gap-4">
            <KpiCard
              label="Utilisateurs récurrents"
              value={fmtInt(social.recurringUsers)}
              sub={fmtPct(social.recurringRate)}
              tone="accent"
            />
            <KpiCard label="Blocages" value={fmtInt(social.blocks)} sub="Total" />
            <KpiCard
              label="Signalements"
              value={fmtInt(social.reports)}
              sub="Sur 30 j"
            />
          </div>
        </Section>
      </div>

      <Section
        title="Publicités récompensées"
        hint="Vidéo regardée pour débloquer un like — qui regarde, par genre et âge (profil au moment de la lecture de cette page, pas au moment du visionnage)."
      >
        <div className="grid items-start gap-4 lg:grid-cols-[minmax(0,.8fr)_minmax(0,1.1fr)_minmax(0,1.2fr)]">
          <KpiCard
            label="Vidéos regardées"
            value={fmtInt(ads.totalWatched)}
            sub="Sur 30 j"
            tone="accent"
          />
          <Card className="p-6">
            <CardTitle className="mb-4">Par genre</CardTitle>
            {ads.byGender.length === 0 ? (
              <p className="text-sm text-sc-text-muted">Aucune donnée sur la période</p>
            ) : (
              <Donut
                segments={ads.byGender.map((g, i) => ({
                  label: g.label,
                  value: g.value,
                  color: DONUT_COLORS[i % DONUT_COLORS.length],
                }))}
                centerValue={fmtInt(ads.totalWatched)}
                centerLabel="vues"
              />
            )}
          </Card>
          <RankBars
            title="Par genre et âge"
            unit="vues"
            items={ads.byGenderAge.map((g) => ({
              label: g.label,
              value: g.value,
            }))}
          />
        </div>
      </Section>
    </>
  );
}
