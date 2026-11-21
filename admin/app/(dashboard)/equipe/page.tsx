import { createSupabaseServiceClient } from "@/lib/supabase/service";
import { PageHero } from "@/components/page-hero";
import { Section } from "@/components/section";
import { Card } from "@/components/ui/card";

// Toujours frais : un message arrivé à l'instant doit être là au rechargement.
export const dynamic = "force-dynamic";

type Msg = {
  id: string;
  user_id: string;
  user_name: string | null;
  body: string;
  media_url: string | null;
  created_at: string;
};

type Prof = {
  id: string;
  display_name: string | null;
  handle: string | null;
  country: string | null;
  city: string | null;
  language: string | null;
  avatar_url: string | null;
  discover_photo_url: string | null;
  is_ai: boolean | null;
};

const fmt = (iso: string) =>
  new Date(iso).toLocaleString("fr-FR", {
    day: "2-digit",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
  });

export default async function EquipePage() {
  const svc = createSupabaseServiceClient();

  const { data, error } = await svc
    .from("official_messages")
    .select("id, user_id, user_name, body, media_url, created_at")
    .order("created_at", { ascending: false })
    .limit(500);
  const missingTable = Boolean(error);
  const msgs = (data ?? []) as Msg[];

  // Une conversation par personne, la plus récemment active d'abord.
  const byUser = new Map<string, Msg[]>();
  for (const m of msgs) {
    const list = byUser.get(m.user_id) ?? [];
    list.push(m);
    byUser.set(m.user_id, list);
  }
  const threads = [...byUser.entries()];

  const profiles = new Map<string, Prof>();
  if (threads.length) {
    const { data: ps } = await svc
      .from("profiles")
      .select(
        "id, display_name, handle, country, city, language, avatar_url, discover_photo_url, is_ai",
      )
      .in(
        "id",
        threads.map(([id]) => id),
      );
    for (const p of (ps ?? []) as Prof[]) profiles.set(p.id, p);
  }

  const last24h = msgs.filter(
    (m) => Date.now() - new Date(m.created_at).getTime() < 24 * 3600 * 1000,
  ).length;

  return (
    <>
      <PageHero
        title="Messages de la team"
        subtitle="Ce que les gens ont écrit à l'équipe Swayco depuis l'app (compte officiel). Les plus récents en premier, regroupés par personne."
        kpis={{
          chip: "BOÎTE DE RÉCEPTION",
          hint: "Lecture seule.",
          cols: 3,
          items: [
            { label: "Messages", value: String(msgs.length), lemon: true },
            { label: "Personnes", value: String(threads.length) },
            { label: "Dernières 24 h", value: String(last24h) },
          ],
        }}
      />

      {missingTable ? (
        <p className="rounded-2xl bg-[rgba(209,43,43,.08)] px-4 py-3 text-sm font-semibold text-sc-danger">
          La table official_messages n&apos;existe pas encore : applique la
          migration 0088 (et 0096 pour les photos / vidéos).
        </p>
      ) : null}

      <Section
        title="Conversations"
        hint="Chaque carte est une personne ; ses messages sont du plus récent au plus ancien. Pour répondre à tout le monde : node admin/scripts/post_official.mjs."
      >
        <div className="flex flex-col gap-4">
          {threads.map(([userId, list]) => {
            const p = profiles.get(userId);
            const name = p?.display_name || list[0].user_name || "—";
            const place = [p?.city, p?.country]
              .filter((s) => (s ?? "").trim())
              .join(", ");
            const photo = p?.avatar_url || p?.discover_photo_url || "";
            return (
              <article
                key={userId}
                className="sc-card flex flex-col gap-4 p-[20px] sm:flex-row"
              >
                <div className="flex shrink-0 items-start gap-3 sm:w-[260px] sm:flex-col">
                  {photo ? (
                    // eslint-disable-next-line @next/next/no-img-element
                    <img
                      src={photo}
                      alt=""
                      className="h-16 w-16 rounded-full border border-sc-line object-cover"
                    />
                  ) : (
                    <div className="flex h-16 w-16 items-center justify-center rounded-full bg-sc-lemon text-xl font-extrabold">
                      {name.slice(0, 1).toUpperCase()}
                    </div>
                  )}
                  <div className="min-w-0">
                    <div className="truncate text-[18px] font-extrabold">
                      {name}
                    </div>
                    <div className="mt-1 text-[13px] leading-relaxed text-sc-text-muted">
                      {[p?.handle ? `@${p.handle}` : "", place, p?.language ?? ""]
                        .filter(Boolean)
                        .join(" · ")}
                      {p?.is_ai ? " · compte IA" : ""}
                    </div>
                    <div className="mt-1 text-[12px] text-sc-text-muted">
                      {list.length} message{list.length > 1 ? "s" : ""}
                    </div>
                  </div>
                </div>

                <div className="flex min-w-0 flex-1 flex-col gap-2">
                  {list.map((m) => (
                    <div
                      key={m.id}
                      className="rounded-2xl border border-sc-line px-4 py-3"
                    >
                      <div className="text-[12px] text-sc-text-muted">
                        {fmt(m.created_at)}
                      </div>
                      {m.body ? (
                        <div className="mt-1 whitespace-pre-wrap break-words text-[15px] leading-relaxed">
                          {m.body}
                        </div>
                      ) : null}
                      {m.media_url ? (
                        /\.(mp4|mov)(\?|$)/i.test(m.media_url) ? (
                          <video
                            src={m.media_url}
                            controls
                            preload="metadata"
                            className="mt-2 max-h-[360px] rounded-xl"
                          />
                        ) : (
                          // eslint-disable-next-line @next/next/no-img-element
                          <img
                            src={m.media_url}
                            alt="Photo envoyée à la team"
                            className="mt-2 max-h-[360px] rounded-xl border border-sc-line"
                          />
                        )
                      ) : null}
                    </div>
                  ))}
                </div>
              </article>
            );
          })}
          {threads.length === 0 && !missingTable ? (
            <Card className="py-10 text-center text-sc-text-muted">
              Aucun message pour l&apos;instant.
            </Card>
          ) : null}
        </div>
      </Section>
    </>
  );
}
