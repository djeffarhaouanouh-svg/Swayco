import { createSupabaseServiceClient } from "@/lib/supabase/service";
import { pagedRows } from "@/lib/db";
import { fmtInt } from "@/lib/format";
import { PageHero } from "@/components/page-hero";
import { Section } from "@/components/section";
import { Card } from "@/components/ui/card";
import { Chip } from "@/components/ui/chip";
import { removeVoice, saveVoice } from "./actions";
import { CreateVoiceForm, VoiceUploadForm } from "./voice-forms";

type Req = {
  id: string;
  created_at: string;
  ai_id: string;
  target_id: string;
  conversation_id: string;
  text: string;
  status: "pending" | "ready" | "sent" | "cancelled";
  source: "user_ask" | "admin";
  ready_at: string | null;
  attempts: number;
  detail: string | null;
};
type Prof = {
  id: string;
  display_name: string | null;
  handle: string | null;
  country: string | null;
  gender: string | null;
};
type Voice = { scope: string; voice_id: string; label: string };

const ERROR_BOX =
  "rounded-2xl bg-[rgba(209,43,43,.08)] px-4 py-3 text-sm font-semibold text-sc-danger";
const LABEL = "text-xs font-bold tracking-[0.08em] text-sc-text-muted uppercase";

const genderWord = (g: string | null) =>
  g === "f" ? "femmes" : g === "m" ? "hommes" : "autres";

const nameOf = (p: Prof | undefined) =>
  (p?.display_name || "").trim() || (p?.handle ? `@${p.handle}` : "—");

/** La voix d'une IA : la sienne, sinon celle de son groupe (pays + genre), sinon la voix par défaut. */
function resolveVoice(ai: Prof | undefined, voices: Map<string, Voice>): { v: Voice | null; from: string } {
  if (ai) {
    const own = voices.get(`ai:${ai.id}`);
    if (own) return { v: own, from: "cette IA" };
    const grp = voices.get(`group:${ai.country ?? ""}|${ai.gender ?? ""}`);
    if (grp) return { v: grp, from: `groupe ${ai.country || "?"} · ${genderWord(ai.gender)}` };
  }
  const def = voices.get("default");
  return def ? { v: def, from: "voix par défaut" } : { v: null, from: "" };
}

export default async function AudiosPage() {
  const svc = createSupabaseServiceClient();

  const { data: openReqs, error: reqErr } = await svc
    .from("ai_voice_requests")
    .select(
      "id, created_at, ai_id, target_id, conversation_id, text, status, source, ready_at, attempts, detail",
    )
    .in("status", ["pending", "ready"])
    .order("created_at", { ascending: true })
    .limit(50);
  const missingTable = Boolean(reqErr);
  const open = (openReqs ?? []) as Req[];
  const pending = open.filter((r) => r.status === "pending");
  const ready = open.filter((r) => r.status === "ready");

  const { count: sent7 } = await svc
    .from("ai_voice_requests")
    .select("id", { count: "exact", head: true })
    .eq("status", "sent")
    .gte("sent_at", new Date(Date.now() - 7 * 86_400_000).toISOString());

  const { data: voiceRows } = await svc.from("ai_voices").select("scope, voice_id, label");
  const voices = new Map<string, Voice>();
  for (const v of (voiceRows ?? []) as Voice[]) voices.set(v.scope, v);

  // Noms des IA et des destinataires des demandes ouvertes.
  const ids = [...new Set(open.flatMap((r) => [r.ai_id, r.target_id]))];
  const profiles = new Map<string, Prof>();
  if (ids.length) {
    const { data: ps } = await svc
      .from("profiles")
      .select("id, display_name, handle, country, gender")
      .in("id", ids);
    for (const p of (ps ?? []) as Prof[]) profiles.set(p.id, p);
  }

  // Les 4 derniers messages de chaque conversation (pour savoir de quoi on parle).
  const context = new Map<string, { sender: string; body: string }[]>();
  await Promise.all(
    pending.slice(0, 20).map(async (r) => {
      const { data } = await svc
        .from("messages")
        .select("sender, body, created_at")
        .eq("conversation_id", r.conversation_id)
        .order("created_at", { ascending: false })
        .limit(4);
      context.set(r.id, (data ?? []).reverse() as { sender: string; body: string }[]);
    }),
  );

  // Groupes d'IA (pays + genre) pour choisir une voix partagée.
  const aiRows = await pagedRows("profiles", "country, gender", (q) => q.eq("is_ai", true));
  const groups = new Map<string, { country: string; gender: string; n: number }>();
  for (const a of aiRows) {
    const country = String(a.country ?? "").trim();
    if (!country) continue;
    const gender = a.gender === "f" || a.gender === "m" ? String(a.gender) : "";
    const key = `${country}|${gender}`;
    const g = groups.get(key) ?? { country, gender, n: 0 };
    g.n++;
    groups.set(key, g);
  }
  const groupList = [...groups.values()].sort((a, b) => b.n - a.n);
  const aiOverrides = [...voices.values()].filter((v) => v.scope.startsWith("ai:"));
  const overrideNames = new Map<string, string>();
  if (aiOverrides.length) {
    const { data: ps } = await svc
      .from("profiles")
      .select("id, display_name, handle")
      .in("id", aiOverrides.map((v) => v.scope.slice(3)));
    for (const p of ps ?? []) {
      overrideNames.set(p.id as string, ((p.display_name as string) || "").trim() || `@${p.handle}`);
    }
  }

  return (
    <>
      <PageHero
        title="Audios"
        subtitle="Les vocaux des IA, faits à la main : l'IA te donne le texte, tu génères la voix (sur le site d'ElevenLabs, sans API), tu envoies le fichier, et l'IA le poste dans le chat."
        kpis={{
          chip: "VOCAUX",
          hint: "Chaque demande attend ton audio.",
          items: [
            { label: "À générer", value: fmtInt(pending.length), lemon: true },
            { label: "En cours d'envoi", value: fmtInt(ready.length), sub: "poste dans quelques secondes" },
            { label: "Envoyés (7 j)", value: fmtInt(sent7 ?? 0) },
          ],
        }}
      />

      {missingTable ? (
        <p className={ERROR_BOX}>
          Les tables n&apos;existent pas encore : applique la migration 0080 dans Supabase.
        </p>
      ) : null}

      <Section
        title="À générer"
        hint="Du plus ancien au plus récent. Génère la voix avec la voix indiquée, télécharge le fichier, envoie-le ici."
      >
        {pending.length === 0 && !missingTable ? (
          <Card className="py-10 text-center text-sc-text-muted">Aucune demande en attente.</Card>
        ) : null}
        <div className="flex flex-col gap-5">
          {pending.map((r) => {
            const ai = profiles.get(r.ai_id);
            const target = profiles.get(r.target_id);
            const { v, from } = resolveVoice(ai, voices);
            const ctx = context.get(r.id) ?? [];
            return (
              <article key={r.id} className="sc-card grid gap-7 p-[22px] lg:grid-cols-[minmax(0,1fr)_minmax(0,1.2fr)]">
                <div className="flex flex-col gap-4">
                  <div>
                    <div className="text-[19px] font-extrabold">
                      {nameOf(ai)}
                      <span className="font-semibold text-sc-text-muted"> → {nameOf(target)}</span>
                    </div>
                    <div className="mt-1 flex flex-wrap items-center gap-2 text-sm text-sc-text-muted">
                      {ai?.country ? <span>{ai.country}</span> : null}
                      <span>· {new Date(r.created_at).toLocaleString("fr-FR")}</span>
                      <Chip tone={r.source === "admin" ? "grey" : "lemon"}>
                        {r.source === "admin" ? "demande manuelle" : "la personne a demandé un vocal"}
                      </Chip>
                    </div>
                  </div>

                  <div>
                    <div className={LABEL}>Voix à utiliser</div>
                    {v ? (
                      <div className="mt-1.5 rounded-xl bg-sc-accent/[0.06] px-4 py-3">
                        <div className="font-extrabold">{v.label || "(sans nom)"}</div>
                        <div className="mt-0.5 font-mono text-[13px] break-all text-sc-text-secondary select-all">
                          {v.voice_id || "— identifiant non renseigné"}
                        </div>
                        <div className="mt-1 text-[12.5px] text-sc-text-muted">choisie via : {from}</div>
                      </div>
                    ) : (
                      <p className="mt-1.5 text-sm font-semibold text-sc-danger">
                        Aucune voix définie pour cette IA : choisis-en une plus bas (section « Voix »).
                      </p>
                    )}
                  </div>

                  {ctx.length > 0 ? (
                    <div>
                      <div className={LABEL}>Conversation</div>
                      <ul className="mt-1.5 flex flex-col gap-1.5 text-[13.5px]">
                        {ctx.map((m, i) => (
                          <li key={i} className="line-clamp-2">
                            <span className="font-bold">
                              {m.sender === r.ai_id ? nameOf(ai) : nameOf(target)} :
                            </span>{" "}
                            <span className="text-sc-text-secondary">{m.body}</span>
                          </li>
                        ))}
                      </ul>
                    </div>
                  ) : null}
                </div>

                <VoiceUploadForm id={r.id} text={r.text} />
              </article>
            );
          })}
        </div>
      </Section>

      {ready.length > 0 ? (
        <Section
          title="En cours d'envoi"
          hint="L'audio est reçu, le serveur le poste dans le chat dans les 15 secondes. Si une ligne reste ici plus d'une minute, le serveur est peut-être arrêté."
        >
          <Card className="divide-y divide-sc-line">
            {ready.map((r) => (
              <div key={r.id} className="flex flex-wrap items-center gap-3 px-6 py-3.5 text-sm">
                <span className="font-bold">{nameOf(profiles.get(r.ai_id))}</span>
                <span className="text-sc-text-muted">→ {nameOf(profiles.get(r.target_id))}</span>
                <span className="text-sc-text-muted">
                  prêt depuis {r.ready_at ? new Date(r.ready_at).toLocaleTimeString("fr-FR") : "—"}
                </span>
                {r.attempts > 0 ? (
                  <Chip tone="red">
                    essai {r.attempts}/3 · {r.detail ?? "erreur"}
                  </Chip>
                ) : null}
              </div>
            ))}
          </Card>
        </Section>
      ) : null}

      <Section
        title="Voix"
        hint="Quelle voix ElevenLabs pour quelle IA. Tu peux en donner une à chaque IA, une par groupe (même pays et même genre), ou une pour toutes. L'IA utilise d'abord la sienne, puis celle de son groupe, puis celle par défaut. Plusieurs IA peuvent partager le même identifiant."
      >
        <Card className="flex flex-col gap-0 p-6">
          <VoiceRow scope="default" title="Voix par défaut (toutes les IA)" voice={voices.get("default")} />
          {groupList.map((g) => (
            <VoiceRow
              key={`${g.country}|${g.gender}`}
              scope={`group:${g.country}|${g.gender}`}
              title={`${g.country} · ${genderWord(g.gender || null)}`}
              sub={`${g.n} IA`}
              voice={voices.get(`group:${g.country}|${g.gender}`)}
            />
          ))}
        </Card>

        <Card className="mt-4 p-6">
          <h3 className="text-[15px] font-extrabold">Une voix pour une IA précise</h3>
          <form action={saveVoice} className="mt-3 flex flex-wrap gap-2.5">
            <input type="hidden" name="scope" value="ai" />
            <input name="who" required placeholder="@pseudo de l'IA" className="sc-field w-[200px]" />
            <input name="voice_id" placeholder="Identifiant ElevenLabs" className="sc-field w-[240px] font-mono" />
            <input name="label" placeholder="Nom de la voix" className="sc-field w-[200px]" />
            <button type="submit" className="sc-btn sc-btn-outline">Enregistrer</button>
          </form>
          {aiOverrides.map((v) => (
            <div key={v.scope} className="mt-3 flex flex-wrap items-center gap-3 border-t border-sc-line pt-3 text-sm">
              <span className="font-bold">{overrideNames.get(v.scope.slice(3)) ?? v.scope}</span>
              <span>{v.label}</span>
              <span className="font-mono text-[13px] text-sc-text-muted">{v.voice_id}</span>
              <form action={removeVoice} className="ml-auto">
                <input type="hidden" name="scope" value={v.scope} />
                <button type="submit" className="text-[13px] font-bold text-sc-danger hover:underline">
                  Retirer
                </button>
              </form>
            </div>
          ))}
        </Card>
      </Section>

      <Section
        title="Demander un audio à la main"
        hint="Sans attendre qu'on t'en réclame un : choisis l'IA, la personne, et ce que l'IA dit. La demande apparaît dans « À générer »."
      >
        <Card className="p-6">
          <CreateVoiceForm />
        </Card>
      </Section>
    </>
  );
}

function VoiceRow({
  scope,
  title,
  sub,
  voice,
}: {
  scope: string;
  title: string;
  sub?: string;
  voice?: Voice;
}) {
  return (
    <form
      action={saveVoice}
      className="flex flex-wrap items-center gap-3 border-t border-sc-line py-3 first:border-t-0 first:pt-0"
    >
      <input type="hidden" name="scope" value={scope} />
      <div className="w-[240px]">
        <div className="text-[14.5px] font-bold">{title}</div>
        {sub ? <div className="text-[12.5px] text-sc-text-muted">{sub}</div> : null}
      </div>
      <input
        name="voice_id"
        defaultValue={voice?.voice_id ?? ""}
        placeholder="Identifiant ElevenLabs"
        className="sc-field w-[260px] font-mono"
      />
      <input
        name="label"
        defaultValue={voice?.label ?? ""}
        placeholder="Nom de la voix"
        className="sc-field w-[200px]"
      />
      <button type="submit" className="sc-btn sc-btn-outline">Enregistrer</button>
      {voice ? null : <Chip tone="lemon">à définir</Chip>}
    </form>
  );
}
