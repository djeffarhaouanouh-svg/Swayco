import { getNewUsersSeries, getSocial } from "@/lib/metrics";
import { SectionHeader } from "@/components/section";
import { KpiCard } from "@/components/kpi-card";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { BarSeries } from "@/components/charts/series";
import { StatList } from "@/components/stat-list";
import { fmtInt, fmtPct } from "@/lib/format";

export default async function SocialPage() {
  const [social, newUsers] = await Promise.all([
    getSocial(30),
    getNewUsersSeries(14),
  ]);

  return (
    <>
      <SectionHeader
        title="Social"
        description="Amitiés, conversations et fidélisation — fenêtre 30 j."
      />

      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        <KpiCard label="Amis (total)" value={fmtInt(social.friendsTotal)} />
        <KpiCard
          label="Nouveaux amis"
          value={fmtInt(social.friendsNew)}
          sub="30 j"
        />
        <KpiCard
          label="Demandes en attente"
          value={fmtInt(social.pendingRequests)}
        />
        <KpiCard
          label="Conversations actives"
          value={fmtInt(social.conversationsActive)}
          sub="30 j"
        />
        <KpiCard
          label="Utilisateurs récurrents"
          value={fmtInt(social.recurringUsers)}
          sub="≥ 2 jours d'activité"
        />
        <KpiCard
          label="Taux de récurrence"
          value={fmtPct(social.recurringRate, 0)}
          tone={social.recurringRate >= 0.3 ? "good" : "default"}
        />
        <KpiCard
          label="Reparle à la même personne"
          value={fmtInt(social.repeatConversations)}
          sub="conversations actives ≥ 2 jours"
        />
        <KpiCard
          label="Taux de re-contact"
          value={fmtPct(social.repeatConversationRate, 0)}
          tone={social.repeatConversationRate >= 0.3 ? "good" : "default"}
        />
      </div>

      <div className="mt-6 grid gap-4 lg:grid-cols-3">
        <Card className="lg:col-span-2">
          <CardHeader>
            <CardTitle>Nouveaux utilisateurs par jour — 14 j</CardTitle>
          </CardHeader>
          <CardContent>
            <BarSeries data={newUsers} color="#a78bfa" />
          </CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle>Détail — 30 j</CardTitle>
          </CardHeader>
          <CardContent>
            <StatList
              items={[
                { label: "Messages envoyés", value: fmtInt(social.messages) },
                {
                  label: "Conversations actives",
                  value: fmtInt(social.conversationsActive),
                },
                {
                  label: "Demandes d'ami en attente",
                  value: fmtInt(social.pendingRequests),
                },
                {
                  label: "Utilisateurs récurrents",
                  value: fmtInt(social.recurringUsers),
                  tone: "good",
                },
                {
                  label: "Reparle à la même personne",
                  value: fmtInt(social.repeatConversations),
                  tone: "good",
                },
              ]}
            />
          </CardContent>
        </Card>
      </div>

      <p className="mt-4 text-xs text-zinc-600">
        Amis et conversations sont lus directement depuis les tables{" "}
        <code className="text-zinc-500">friendships</code> et{" "}
        <code className="text-zinc-500">messages</code>.
      </p>
    </>
  );
}
