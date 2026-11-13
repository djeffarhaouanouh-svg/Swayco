import { Check, TriangleAlert } from "lucide-react";
import { createSupabaseServiceClient } from "@/lib/supabase/service";
import { PageHero } from "@/components/page-hero";
import { Section } from "@/components/section";
import { Card } from "@/components/ui/card";
import { approveVerification, rejectVerification } from "./actions";
import { GESTURE_LABELS, REJECT_REASONS } from "./labels";

/** Private bucket (migration 0077): the selfie is read here, by signed URL. */
const BUCKET = "verification-selfies";

type Req = {
  id: string;
  user_id: string;
  gesture: string;
  selfie_path: string;
  created_at: string;
};

type Prof = {
  id: string;
  display_name: string | null;
  handle: string | null;
  age: number | null;
  country: string | null;
  city: string | null;
  photos: string[] | null;
  discover_photo_url: string | null;
  avatar_url: string | null;
  is_ai: boolean | null;
};

const LABEL = "text-xs font-bold tracking-[0.08em] text-sc-text-muted uppercase";

/** Profile pictures to compare the selfie to: gallery, Discover photo, PDP. */
function photosOf(p: Prof | undefined): string[] {
  if (!p) return [];
  const all = [...(p.photos ?? []), p.discover_photo_url ?? "", p.avatar_url ?? ""];
  const seen = new Set<string>();
  const out: string[] = [];
  for (const u of all) {
    const url = u.trim();
    const key = url.split("?")[0];
    if (!url || seen.has(key)) continue;
    seen.add(key);
    out.push(url);
  }
  return out.slice(0, 6);
}

export default async function VerificationsPage() {
  const svc = createSupabaseServiceClient();

  const { data: reqs, error } = await svc
    .from("profile_verifications")
    .select("id, user_id, gesture, selfie_path, created_at")
    .eq("status", "pending")
    .order("created_at", { ascending: true })
    .limit(50);
  const missingTable = Boolean(error);
  const rows = (reqs ?? []) as Req[];

  const ids = [...new Set(rows.map((r) => r.user_id))];
  const profiles = new Map<string, Prof>();
  if (ids.length) {
    const { data: ps } = await svc
      .from("profiles")
      .select(
        "id, display_name, handle, age, country, city, photos, discover_photo_url, avatar_url, is_ai",
      )
      .in("id", ids);
    for (const p of (ps ?? []) as Prof[]) profiles.set(p.id, p);
  }

  // The selfie is private: short-lived signed URLs, made with the service key.
  const selfieUrl = new Map<string, string>();
  if (rows.length) {
    const { data: signed } = await svc.storage
      .from(BUCKET)
      .createSignedUrls(
        rows.map((r) => r.selfie_path),
        // 1 h (c'était 10 min : une image qui ne s'affichait plus donnait
        // l'impression que la demande avait disparu). Le selfie reste privé :
        // le lien n'est montré qu'à l'admin connecté.
        3600,
      );
    for (const s of signed ?? []) {
      if (s.path && s.signedUrl) selfieUrl.set(s.path, s.signedUrl);
    }
  }

  const { count: verifiedCount } = await svc
    .from("profiles")
    .select("id", { count: "exact", head: true })
    .eq("is_verified", true);

  return (
    <>
      <PageHero
        title="Vérifications"
        subtitle="Compare le selfie aux photos du profil et vérifie que le geste demandé est fait. Le selfie est supprimé dès que tu as décidé."
        kpis={{
          chip: "FILE D'ATTENTE",
          hint: "Les plus anciennes demandes en premier.",
          cols: 2,
          items: [
            { label: "En attente", value: String(rows.length), lemon: true },
            { label: "Profils vérifiés", value: String(verifiedCount ?? 0) },
          ],
        }}
      />

      {missingTable ? (
        <p className="rounded-2xl bg-[rgba(209,43,43,.08)] px-4 py-3 text-sm font-semibold text-sc-danger">
          La table profile_verifications n&apos;existe pas encore : applique la
          migration 0077.
        </p>
      ) : null}

      <Section
        title="Demandes"
        hint="Les plus anciennes d'abord. Les liens des selfies expirent au bout d'une heure : recharge la page si une image ne s'affiche plus. La demande, elle, reste là tant que tu n'as pas décidé."
      >
        <div className="flex flex-col gap-5">
          {rows.map((r) => {
            const p = profiles.get(r.user_id);
            const photos = photosOf(p);
            const selfie = selfieUrl.get(r.selfie_path);
            const place = [p?.city, p?.country]
              .filter((s) => (s ?? "").trim())
              .join(", ");
            return (
              <article
                key={r.id}
                className="sc-card grid gap-7 p-[22px] lg:grid-cols-[320px_minmax(0,1fr)]"
              >
                <div className="flex flex-col gap-2">
                  <div className={LABEL}>Selfie</div>
                  {selfie ? (
                    // eslint-disable-next-line @next/next/no-img-element
                    <img
                      src={selfie}
                      alt="Selfie de vérification"
                      className="aspect-[3/4] w-full rounded-2xl border border-sc-line object-cover"
                    />
                  ) : (
                    <div className="sc-stripe flex aspect-[3/4] w-full items-center justify-center rounded-2xl border border-sc-line p-4 text-center text-sm text-sc-text-muted">
                      Selfie introuvable (déjà supprimé ?)
                    </div>
                  )}
                </div>

                <div className="flex flex-col gap-[18px]">
                  <div>
                    <div className="text-[22px] font-extrabold">
                      {p?.display_name || "—"}
                      {p?.age ? `, ${p.age}` : ""}
                    </div>
                    <div className="mt-1 text-sm text-sc-text-muted">
                      {[p?.handle ? `@${p.handle}` : "", place]
                        .filter(Boolean)
                        .join(" · ")}
                      {" · "}
                      {new Date(r.created_at).toLocaleString("fr-FR")}
                    </div>
                  </div>

                  {p?.is_ai ? (
                    <span className="inline-flex w-fit items-center gap-1.5 rounded-full bg-[rgba(209,43,43,.1)] px-3 py-1.5 text-[13px] font-bold text-sc-danger">
                      <TriangleAlert className="h-4 w-4" />
                      Compte IA : ne pas vérifier.
                    </span>
                  ) : null}

                  <span className="self-start rounded-full bg-sc-lemon px-[18px] py-[9px] text-[14.5px] font-extrabold">
                    Geste demandé : {GESTURE_LABELS[r.gesture] ?? r.gesture}
                  </span>

                  <div className="flex flex-col gap-2">
                    <div className={LABEL}>Photos du profil</div>
                    {photos.length ? (
                      <div className="flex flex-wrap gap-2">
                        {photos.map((u) => (
                          // eslint-disable-next-line @next/next/no-img-element
                          <img
                            key={u}
                            src={u}
                            alt="Photo du profil"
                            className="h-28 w-20 rounded-xl border border-sc-line object-cover"
                          />
                        ))}
                      </div>
                    ) : (
                      <p className="text-sm text-sc-text-muted">
                        Aucune photo sur ce profil : rien à comparer.
                      </p>
                    )}
                  </div>

                  <div className="mt-auto flex flex-wrap items-center gap-3">
                    <form action={approveVerification}>
                      <input type="hidden" name="id" value={r.id} />
                      <button type="submit" className="sc-btn sc-btn-primary">
                        <Check className="h-[17px] w-[17px]" />
                        Approuver
                      </button>
                    </form>
                    <form
                      action={rejectVerification}
                      className="flex items-center gap-2"
                    >
                      <input type="hidden" name="id" value={r.id} />
                      <select
                        name="reason"
                        required
                        defaultValue=""
                        className="sc-field w-[230px]"
                      >
                        <option value="" disabled>
                          Motif du refus…
                        </option>
                        {Object.entries(REJECT_REASONS).map(([code, label]) => (
                          <option key={code} value={code}>
                            {label}
                          </option>
                        ))}
                      </select>
                      <button type="submit" className="sc-btn sc-btn-danger">
                        Refuser
                      </button>
                    </form>
                  </div>
                </div>
              </article>
            );
          })}
          {rows.length === 0 && !missingTable ? (
            <Card className="py-10 text-center text-sc-text-muted">
              Aucune demande en attente.
            </Card>
          ) : null}
        </div>
      </Section>
    </>
  );
}
