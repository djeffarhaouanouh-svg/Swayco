import { getSurfaceEngagement, type SurfaceBreakdown } from "@/lib/metrics";
import { SectionHeader } from "@/components/section";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { RankBars } from "@/components/rank-bars";
import { KpiCard } from "@/components/kpi-card";
import { fmtInt, fmtPct } from "@/lib/format";

// Pretty French labels for the raw source / screen / type codes the app emits.
const LABELS: Record<string, string> = {
  // sources & screens
  discover: "Discover",
  chat: "Chat",
  live: "Live (appel)",
  profile: "Profil",
  friends_list: "Liste d'amis",
  requests: "Demandes / likes reçus",
  // message types
  text: "Texte",
  voice: "Vocal",
  image: "Image",
  reaction: "Réaction",
  // fallback
  inconnu: "Inconnu",
};

const label = (code: string): string => LABELS[code] ?? code;

/** A breakdown → RankBars items, each with a "count · %" hint. */
function toItems(b: SurfaceBreakdown) {
  return b.bySource.map((p) => ({
    label: label(p.label),
    value: p.value,
    hint: `${fmtInt(p.value)} · ${fmtPct(b.total > 0 ? p.value / b.total : 0)}`,
  }));
}

export default async function SurfacesPage() {
  const e = await getSurfaceEngagement(30);

  const nothing =
    e.messages.total +
      e.friendRequests.total +
      e.likes.total +
      e.screenViews.total ===
    0;

  return (
    <>
      <SectionHeader
        title="Engagement par surface"
        description="D'où partent vraiment les actions — Discover, Chat ou Live. Fenêtre 30 j."
      />

      {nothing ? (
        <div className="mb-6 rounded-lg border border-amber-900/60 bg-amber-950/30 px-4 py-3 text-sm text-amber-300">
          Aucun événement de surface pour l&apos;instant. Ces chiffres
          n&apos;apparaissent qu&apos;à partir du moment où une version de
          l&apos;app contenant le nouveau tracking (<code>message_sent</code>,{" "}
          <code>like_sent</code>, <code>friend_request_sent</code>,{" "}
          <code>screen_view</code>) est en production et utilisée.
        </div>
      ) : null}

      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <KpiCard label="Messages (30 j)" value={fmtInt(e.messages.total)} />
        <KpiCard
          label="Demandes d'ami (30 j)"
          value={fmtInt(e.friendRequests.total)}
        />
        <KpiCard label="Likes (30 j)" value={fmtInt(e.likes.total)} />
        <KpiCard
          label="Ouvertures (30 j)"
          value={fmtInt(e.screenViews.total)}
        />
      </div>

      <div className="mt-6 grid gap-4 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>Messages par surface</CardTitle>
          </CardHeader>
          <CardContent>
            <RankBars
              items={toItems(e.messages)}
              color="bg-cyan-500"
              empty="Aucun message tracké"
            />
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Messages par type</CardTitle>
          </CardHeader>
          <CardContent>
            <RankBars
              items={toItems(e.messagesByType)}
              color="bg-indigo-500"
              empty="Aucun message tracké"
            />
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Demandes d&apos;ami / abonnements par surface</CardTitle>
          </CardHeader>
          <CardContent>
            <RankBars
              items={toItems(e.friendRequests)}
              color="bg-emerald-500"
              empty="Aucune demande trackée"
            />
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Ouvertures d&apos;écran (où le temps se passe)</CardTitle>
          </CardHeader>
          <CardContent>
            <RankBars
              items={toItems(e.screenViews)}
              color="bg-violet-500"
              empty="Aucune ouverture trackée"
            />
          </CardContent>
        </Card>
      </div>

      <p className="mt-4 text-xs text-zinc-600">
        Basé sur les événements{" "}
        <code className="text-zinc-500">message_sent</code>,{" "}
        <code className="text-zinc-500">like_sent</code>,{" "}
        <code className="text-zinc-500">friend_request_sent</code> et{" "}
        <code className="text-zinc-500">screen_view</code> émis par l&apos;app à
        chaque action. Le « Live » couvre désormais le chat en appel — jusque-là
        invisible (jamais enregistré en base). Les pourcentages = part de chaque
        surface dans le total.
      </p>
    </>
  );
}
