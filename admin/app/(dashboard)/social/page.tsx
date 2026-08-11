import { getActiveSendersSeries, getSocial } from "@/lib/metrics";
import { fmtInt, fmtPct } from "@/lib/format";
import { KpiCard, KpiGrid } from "@/components/kpi-card";
import { PageHeader, Section } from "@/components/section";
import { SeriesChart } from "@/components/charts/series";

export default async function SocialPage() {
  const [social, senders] = await Promise.all([
    getSocial(30),
    getActiveSendersSeries(14),
  ]);

  return (
    <>
      <PageHeader
        title="Social"
        subtitle="Amitiés, conversations et messages — fenêtre de 30 jours sauf mention contraire."
      />

      <Section title="Amitiés">
        <KpiGrid>
          <KpiCard
            label="Amis (acceptés)"
            value={fmtInt(social.friendsTotal)}
            sub={`+${fmtInt(social.friendsNew)} sur 30 j`}
          />
          <KpiCard
            label="Demandes envoyées"
            value={fmtInt(social.requestsSent)}
            sub={`${fmtPct(social.acceptRate)} acceptées`}
          />
          <KpiCard
            label="Demandes en attente"
            value={fmtInt(social.pendingRequests)}
          />
          <KpiCard label="Likes" value={fmtInt(social.likes)} />
        </KpiGrid>
      </Section>

      <Section
        title="Conversations"
        hint="Le signal fort : une conversation avec des messages sur au moins 2 jours différents veut dire que quelqu'un est revenu parler à cette personne."
      >
        <KpiGrid cols={3}>
          <KpiCard
            label="Conversations actives"
            value={fmtInt(social.conversationsActive)}
            tone="accent"
          />
          <KpiCard
            label="Conversations qui durent"
            value={fmtInt(social.repeatConversations)}
            sub={fmtPct(social.repeatConversationRate)}
          />
          <KpiCard
            label="Messages envoyés"
            value={fmtInt(social.messages)}
          />
        </KpiGrid>
      </Section>

      <Section
        title="Expéditeurs actifs"
        hint="Utilisateurs distincts ayant envoyé au moins un message, par jour."
      >
        <SeriesChart title="Expéditeurs actifs par jour" data={senders} />
      </Section>

      <Section
        title="Fidélité"
        hint="Un utilisateur récurrent a ouvert l'app sur au moins 2 jours différents dans la fenêtre."
      >
        <KpiGrid cols={3}>
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
        </KpiGrid>
      </Section>
    </>
  );
}
