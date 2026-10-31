import { Check } from "lucide-react";
import { createSupabaseServiceClient } from "@/lib/supabase/service";
import { PageHero } from "@/components/page-hero";
import { Section } from "@/components/section";
import { Card } from "@/components/ui/card";
import { Chip, type ChipTone } from "@/components/ui/chip";
import { GridTable, GridRow, GridEmpty } from "@/components/ui/grid-table";
import { AgentsForm } from "./agents-form";
import {
  addCallDebugUser,
  addProtectedEmail,
  removeCallDebugUser,
  removeProtectedEmail,
} from "./actions";

type ActionRow = {
  id: string;
  ai_id: string;
  target_id: string;
  kind: string;
  source: string;
  status: string;
  detail: string | null;
  run_at: string;
  created_at: string;
};

const KIND: Record<string, string> = {
  like: "Like",
  message: "Message",
  reply: "Réponse",
};
const STATUS: Record<string, string> = {
  pending: "en attente",
  running: "en cours",
  done: "fait",
  failed: "échec",
  skipped: "ignoré",
};
const STATUS_TONE: Record<string, ChipTone> = {
  done: "blue",
  pending: "lemon",
  running: "cyan",
  failed: "red",
  skipped: "grey",
};

const ERROR_BOX =
  "rounded-2xl bg-[rgba(209,43,43,.08)] px-4 py-3 text-sm font-semibold text-sc-danger";

const PHRASE_COLS =
  "150px 120px 70px minmax(0,1fr) minmax(0,1fr) minmax(0,1.1fr)";
const LOG_COLS =
  "150px 100px minmax(0,1fr) minmax(0,1fr) 90px minmax(0,1.2fr)";

export default async function AgentsPage() {
  const svc = createSupabaseServiceClient();

  const [{ data: ais, error: aiErr }, { data: recent, error: actErr }] =
    await Promise.all([
      svc
        .from("profiles")
        .select("country, gender")
        .eq("is_ai", true)
        .limit(10000),
      svc
        .from("ai_actions")
        .select(
          "id, ai_id, target_id, kind, source, status, detail, run_at, created_at",
        )
        .order("created_at", { ascending: false })
        .limit(40),
    ]);

  const byCountry = new Map<string, number>();
  let women = 0;
  let men = 0;
  for (const a of ais ?? []) {
    const c = String(a.country ?? "").trim();
    if (c) byCountry.set(c, (byCountry.get(c) ?? 0) + 1);
    if (a.gender === "f") women++;
    if (a.gender === "m") men++;
  }
  const countries = [...byCountry.entries()]
    .map(([name, count]) => ({ name, count }))
    .sort((a, b) => b.count - a.count);

  const rows = (recent ?? []) as ActionRow[];
  const ids = [...new Set(rows.flatMap((r) => [r.ai_id, r.target_id]))];
  const names = new Map<string, string>();
  if (ids.length) {
    const { data: ps } = await svc
      .from("profiles")
      .select("id, display_name")
      .in("id", ids);
    for (const p of ps ?? []) names.set(p.id, p.display_name || "—");
  }

  const [{ count: pendingCount }, { count: doneToday }] = await Promise.all([
    svc
      .from("ai_actions")
      .select("id", { count: "exact", head: true })
      .eq("status", "pending"),
    svc
      .from("ai_actions")
      .select("id", { count: "exact", head: true })
      .eq("status", "done")
      .gte("done_at", new Date(Date.now() - 86_400_000).toISOString()),
  ]);

  const missingTable = Boolean(actErr);

  const { data: protectedRows, error: protErr } = await svc
    .from("ai_exempt_emails")
    .select("email, note, created_at")
    .order("created_at", { ascending: false })
    .limit(200);
  const protectedEmails = protectedRows ?? [];
  // Journal des phrases d'appel (migration 0076) : comptes suivis + dernières phrases.
  const { data: dbgUsers, error: dbgErr } = await svc
    .from("call_debug_users")
    .select("user_id, note, created_at")
    .order("created_at", { ascending: false })
    .limit(200);
  const { data: phrases } = await svc
    .from("call_phrase_log")
    .select("created_at, user_id, from_lang, to_lang, heard, repaired, translated, route, unclear")
    .order("created_at", { ascending: false })
    .limit(60);
  const dbgIds = [
    ...new Set([
      ...(dbgUsers ?? []).map((u) => u.user_id as string),
      ...(phrases ?? []).map((p) => p.user_id as string),
    ]),
  ];
  const dbgNames = new Map<string, string>();
  if (dbgIds.length) {
    const { data: ps } = await svc.from("profiles").select("id, handle, display_name").in("id", dbgIds);
    for (const p of ps ?? []) dbgNames.set(p.id, p.handle || p.display_name || "—");
  }
  // Combien de ces emails ont déjà un compte (pour rassurer : « ça marche »).
  const hasAccount = new Set<string>();
  if (protectedEmails.length) {
    for (const p of protectedEmails) {
      const { count } = await svc
        .from("profiles")
        .select("id", { count: "exact", head: true })
        .ilike("email", p.email.replace(/[\\%_]/g, (c: string) => `\\${c}`));
      if ((count ?? 0) > 0) hasAccount.add(p.email);
    }
  }

  return (
    <>
      <PageHero
        title="Comptes IA"
        subtitle="Piloter à distance les comptes marqués « IA » : likes et messages planifiés. Le backend exécute, aux heures choisies."
        kpis={{
          chip: "PARC",
          hint: "Les comptes pilotés depuis cette page.",
          items: [
            { label: "Comptes IA", value: String(ais?.length ?? 0) },
            { label: "Femmes / Hommes", value: `${women} / ${men}` },
            { label: "En attente", value: String(pendingCount ?? 0), lemon: true },
            { label: "Faites (24 h)", value: String(doneToday ?? 0) },
          ],
        }}
      />

      {aiErr || missingTable ? (
        <p className={ERROR_BOX}>
          {missingTable
            ? "La table ai_actions n'existe pas encore : applique les migrations 0064 et 0068."
            : aiErr?.message}
        </p>
      ) : null}

      <div className="grid items-start gap-6 lg:grid-cols-[minmax(0,1.35fr)_minmax(0,1fr)]">
        <Section
          title="Planifier"
          hint="Choisis la cible et combien de comptes (d'un pays, ou de tous) agissent. Rien ne part instantanément si tu étales."
        >
          <AgentsForm countries={countries} />
        </Section>

        <Section
          title="Protégés"
          hint="Une IA ne contacte jamais le compte qui a l'un de ces emails : ni like, ni message, ni réponse. Tu peux l'ajouter avant que la personne s'inscrive."
        >
          {protErr ? (
            <p className={`${ERROR_BOX} mb-4`}>
              La table ai_exempt_emails n&apos;existe pas encore : applique la migration 0075.
            </p>
          ) : null}
          <Card className="p-6">
            <form action={addProtectedEmail} className="mb-3 flex gap-2.5">
              <input
                name="email"
                type="email"
                required
                placeholder="email@exemple.com"
                className="sc-field flex-[1.4]"
              />
              <input
                name="note"
                maxLength={120}
                placeholder="Note (ex. maman)"
                className="sc-field flex-1"
              />
              <button type="submit" className="sc-btn sc-btn-outline">
                Protéger
              </button>
            </form>
            {protectedEmails.map((p) => (
              <div
                key={p.email}
                className="grid grid-cols-[minmax(0,1fr)_auto_auto] items-center gap-3.5 border-t border-sc-line py-3"
              >
                <div className="min-w-0">
                  <div className="truncate text-[14.5px] font-semibold">{p.email}</div>
                  {p.note ? (
                    <div className="text-[12.5px] text-sc-text-muted">{p.note}</div>
                  ) : null}
                </div>
                {hasAccount.has(p.email) ? (
                  <Chip tone="blue">
                    <Check className="h-3.5 w-3.5" />
                    compte trouvé
                  </Chip>
                ) : (
                  <Chip tone="grey">pas encore inscrit</Chip>
                )}
                <form action={removeProtectedEmail}>
                  <input type="hidden" name="email" value={p.email} />
                  <button
                    type="submit"
                    className="text-[13px] font-bold text-sc-danger hover:underline"
                  >
                    Retirer
                  </button>
                </form>
              </div>
            ))}
            {protectedEmails.length === 0 ? (
              <p className="border-t border-sc-line pt-5 pb-2 text-center text-sm text-sc-text-muted">
                Aucun email protégé.
              </p>
            ) : null}
          </Card>
        </Section>
      </div>

      <Section
        title="Phrases d'appel (test)"
        hint="Pour les comptes ajoutés ici, le serveur garde ce que le micro a compris, la phrase réparée et la traduction, 7 jours. Ajoute les deux comptes d'un appel de test pour voir les deux sens. Les autres comptes ne sont jamais enregistrés."
      >
        {dbgErr ? (
          <p className={`${ERROR_BOX} mb-4`}>
            Les tables n&apos;existent pas encore : applique la migration 0076.
          </p>
        ) : null}
        <form action={addCallDebugUser} className="mb-4 flex items-center gap-3">
          <input
            name="who"
            required
            placeholder="pseudo (lely-b0253e), email ou identifiant"
            className="sc-field w-[460px]"
          />
          <button type="submit" className="sc-btn sc-btn-primary">
            Enregistrer ses phrases
          </button>
        </form>
        <div className="mb-4 flex flex-wrap gap-2">
          {(dbgUsers ?? []).map((u) => (
            <form
              key={u.user_id}
              action={removeCallDebugUser}
              className="flex items-center gap-2 rounded-full border border-sc-line-strong bg-white px-3.5 py-2 text-[13px] font-semibold"
            >
              <input type="hidden" name="user_id" value={u.user_id} />
              <span>{dbgNames.get(u.user_id) ?? u.note ?? u.user_id}</span>
              <button type="submit" className="font-bold text-sc-danger hover:underline">
                retirer
              </button>
            </form>
          ))}
          {(dbgUsers ?? []).length === 0 && !dbgErr ? (
            <span className="text-sm text-sc-text-muted">Aucun compte suivi.</span>
          ) : null}
        </div>
        <GridTable
          cols={PHRASE_COLS}
          head={[
            { label: "Quand" },
            { label: "Qui" },
            { label: "Sens" },
            { label: "Compris" },
            { label: "Réparé" },
            { label: "Traduit" },
          ]}
        >
          {(phrases ?? []).map((p, i) => (
            <GridRow key={`${p.created_at}-${i}`} cols={PHRASE_COLS}>
              <span className="text-[13.5px] whitespace-nowrap text-sc-text-muted">
                {new Date(p.created_at).toLocaleString("fr-FR")}
              </span>
              <span className="font-bold">{dbgNames.get(p.user_id) ?? "—"}</span>
              <span className="font-mono text-[13px] whitespace-nowrap">
                {p.from_lang}→{p.to_lang}
              </span>
              <span>{p.heard}</span>
              <span className="text-sc-text-muted">{p.repaired}</span>
              <span className="font-semibold">
                {p.unclear ? (
                  <span className="font-normal text-sc-text-muted">
                    illisible, rien envoyé
                  </span>
                ) : (
                  p.translated
                )}
              </span>
            </GridRow>
          ))}
          {(phrases ?? []).length === 0 ? (
            <GridEmpty>Aucune phrase enregistrée.</GridEmpty>
          ) : null}
        </GridTable>
      </Section>

      <Section title="Journal" hint="Les 40 dernières actions, toutes sources.">
        <GridTable
          cols={LOG_COLS}
          head={[
            { label: "Quand" },
            { label: "Action" },
            { label: "Compte IA" },
            { label: "Cible" },
            { label: "Source" },
            { label: "Statut" },
          ]}
        >
          {rows.map((r) => (
            <GridRow key={r.id} cols={LOG_COLS}>
              <span className="text-[13.5px] whitespace-nowrap text-sc-text-muted">
                {new Date(r.created_at).toLocaleString("fr-FR")}
              </span>
              <span className="font-bold">{KIND[r.kind] ?? r.kind}</span>
              <span>{names.get(r.ai_id) ?? "—"}</span>
              <span>{names.get(r.target_id) ?? "—"}</span>
              <span className="text-sc-text-muted">{r.source}</span>
              <span className="flex flex-wrap items-center gap-2">
                <Chip tone={STATUS_TONE[r.status] ?? "grey"}>
                  {STATUS[r.status] ?? r.status}
                </Chip>
                {r.detail ? (
                  <span className="text-[12.5px] text-sc-text-muted">{r.detail}</span>
                ) : null}
              </span>
            </GridRow>
          ))}
          {rows.length === 0 ? <GridEmpty>Rien pour l&apos;instant.</GridEmpty> : null}
        </GridTable>
      </Section>
    </>
  );
}
