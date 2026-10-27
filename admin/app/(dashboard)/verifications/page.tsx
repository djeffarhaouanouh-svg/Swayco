import { createSupabaseServiceClient } from "@/lib/supabase/service";
import { KpiCard, KpiGrid } from "@/components/kpi-card";
import { PageHeader, Section } from "@/components/section";
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
        600,
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
      <PageHeader
        title="Vérifications"
        subtitle="Compare le selfie aux photos du profil et vérifie que le geste demandé est fait. Le selfie est supprimé dès que tu as décidé."
      />

      {missingTable ? (
        <p className="mb-8 rounded-xl border border-red-400/30 bg-red-400/10 p-4 text-sm text-red-300">
          La table profile_verifications n&apos;existe pas encore : applique la
          migration 0077.
        </p>
      ) : null}

      <Section title="File d'attente">
        <KpiGrid cols={3}>
          <KpiCard label="En attente" value={String(rows.length)} tone="accent" />
          <KpiCard label="Profils vérifiés" value={String(verifiedCount ?? 0)} />
        </KpiGrid>
      </Section>

      <Section
        title="Demandes"
        hint="Les plus anciennes d'abord. Les liens des selfies expirent au bout de 10 minutes : recharge la page si une image ne s'affiche plus."
      >
        <div className="space-y-6">
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
                className="grid gap-6 rounded-2xl border border-white/10 bg-white/[0.03] p-5 lg:grid-cols-[minmax(0,320px)_1fr]"
              >
                <div>
                  <div className="mb-2 text-xs font-semibold tracking-wide text-sc-text-muted uppercase">
                    Selfie
                  </div>
                  {selfie ? (
                    // eslint-disable-next-line @next/next/no-img-element
                    <img
                      src={selfie}
                      alt="Selfie de vérification"
                      className="max-h-[420px] w-full rounded-xl border border-white/10 object-contain"
                    />
                  ) : (
                    <div className="flex h-40 items-center justify-center rounded-xl border border-white/10 text-sm text-sc-text-muted">
                      Selfie introuvable (déjà supprimé ?)
                    </div>
                  )}
                </div>

                <div className="flex flex-col gap-4">
                  <div>
                    <div className="text-lg font-bold text-sc-text">
                      {p?.display_name || "—"}
                      {p?.age ? `, ${p.age}` : ""}
                    </div>
                    <div className="text-sm text-sc-text-muted">
                      {[p?.handle ? `@${p.handle}` : "", place]
                        .filter(Boolean)
                        .join(" · ")}
                      {" · "}
                      {new Date(r.created_at).toLocaleString("fr-FR")}
                    </div>
                    {p?.is_ai ? (
                      <div className="mt-1 text-sm text-red-300">
                        Compte IA : ne pas vérifier.
                      </div>
                    ) : null}
                  </div>

                  <div className="inline-flex w-fit items-center rounded-full bg-sc-accent/15 px-4 py-2 text-sm font-bold text-sc-accent">
                    Geste demandé : {GESTURE_LABELS[r.gesture] ?? r.gesture}
                  </div>

                  <div>
                    <div className="mb-2 text-xs font-semibold tracking-wide text-sc-text-muted uppercase">
                      Photos du profil
                    </div>
                    {photos.length ? (
                      <div className="flex flex-wrap gap-2">
                        {photos.map((u) => (
                          // eslint-disable-next-line @next/next/no-img-element
                          <img
                            key={u}
                            src={u}
                            alt="Photo du profil"
                            className="h-28 w-20 rounded-lg border border-white/10 object-cover"
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
                      <button
                        type="submit"
                        className="rounded-xl bg-sc-accent px-5 py-2 text-sm font-bold text-black hover:opacity-90"
                      >
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
                        className="rounded-xl border border-white/10 bg-white/5 px-3 py-2 text-sm"
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
                      <button
                        type="submit"
                        className="rounded-xl bg-white/10 px-4 py-2 text-sm font-semibold text-red-300 hover:bg-white/15"
                      >
                        Refuser
                      </button>
                    </form>
                  </div>
                </div>
              </article>
            );
          })}
          {rows.length === 0 && !missingTable ? (
            <p className="rounded-2xl border border-white/10 px-4 py-10 text-center text-sc-text-muted">
              Aucune demande en attente.
            </p>
          ) : null}
        </div>
      </Section>
    </>
  );
}
