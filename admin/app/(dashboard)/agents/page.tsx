import { createSupabaseServiceClient } from "@/lib/supabase/service";
import { KpiCard, KpiGrid } from "@/components/kpi-card";
import { PageHeader, Section } from "@/components/section";
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
      <PageHeader
        title="Comptes IA"
        subtitle="Piloter à distance les comptes marqués « IA » : likes et messages planifiés. Le backend exécute, aux heures choisies."
      />

      {aiErr || missingTable ? (
        <p className="mb-8 rounded-xl border border-red-400/30 bg-red-400/10 p-4 text-sm text-red-300">
          {missingTable
            ? "La table ai_actions n'existe pas encore : applique les migrations 0064 et 0068."
            : aiErr?.message}
        </p>
      ) : null}

      <Section title="Parc">
        <KpiGrid cols={4}>
          <KpiCard label="Comptes IA" value={String(ais?.length ?? 0)} />
          <KpiCard label="Femmes / Hommes" value={`${women} / ${men}`} />
          <KpiCard label="En attente" value={String(pendingCount ?? 0)} />
          <KpiCard label="Faites (24 h)" value={String(doneToday ?? 0)} />
        </KpiGrid>
      </Section>

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
          <p className="mb-4 rounded-xl border border-red-400/30 bg-red-400/10 p-4 text-sm text-red-300">
            La table ai_exempt_emails n'existe pas encore : applique la migration 0075.
          </p>
        ) : null}
        <form action={addProtectedEmail} className="mb-4 flex flex-wrap gap-3">
          <input
            name="email"
            type="email"
            required
            placeholder="email@exemple.com"
            className="min-w-64 flex-1 rounded-xl border border-white/10 bg-white/5 px-3 py-2 text-sm"
          />
          <input
            name="note"
            maxLength={120}
            placeholder="Note (ex. maman)"
            className="min-w-40 rounded-xl border border-white/10 bg-white/5 px-3 py-2 text-sm"
          />
          <button
            type="submit"
            className="rounded-xl bg-white/10 px-4 py-2 text-sm font-semibold hover:bg-white/15"
          >
            Protéger
          </button>
        </form>
        <div className="overflow-x-auto rounded-2xl border border-white/10">
          <table className="w-full text-left text-sm">
            <tbody>
              {protectedEmails.map((p) => (
                <tr key={p.email} className="border-t border-white/5 first:border-t-0">
                  <td className="px-4 py-2">{p.email}</td>
                  <td className="px-4 py-2 text-sc-text-muted">{p.note ?? ""}</td>
                  <td className="px-4 py-2 text-sc-text-muted">
                    {hasAccount.has(p.email) ? "compte trouvé" : "pas encore inscrit"}
                  </td>
                  <td className="px-4 py-2 text-right">
                    <form action={removeProtectedEmail}>
                      <input type="hidden" name="email" value={p.email} />
                      <button type="submit" className="text-xs text-red-300 hover:underline">
                        Retirer
                      </button>
                    </form>
                  </td>
                </tr>
              ))}
              {protectedEmails.length === 0 ? (
                <tr>
                  <td className="px-4 py-6 text-center text-sc-text-muted">
                    Aucun email protégé.
                  </td>
                </tr>
              ) : null}
            </tbody>
          </table>
        </div>
      </Section>

      <Section
        title="Phrases d'appel (test)"
        hint="Pour les comptes ajoutés ici, le serveur garde ce que le micro a compris, la phrase réparée et la traduction, 7 jours. Ajoute les deux comptes d'un appel de test pour voir les deux sens. Les autres comptes ne sont jamais enregistrés."
      >
        {dbgErr ? (
          <p className="mb-4 rounded-xl border border-red-400/30 bg-red-400/10 p-4 text-sm text-red-300">
            Les tables n'existent pas encore : applique la migration 0076.
          </p>
        ) : null}
        <form action={addCallDebugUser} className="mb-4 flex flex-wrap gap-3">
          <input
            name="who"
            required
            placeholder="pseudo (lely-b0253e), email ou identifiant"
            className="min-w-72 flex-1 rounded-xl border border-white/10 bg-white/5 px-3 py-2 text-sm"
          />
          <button
            type="submit"
            className="rounded-xl bg-white/10 px-4 py-2 text-sm font-semibold hover:bg-white/15"
          >
            Enregistrer ses phrases
          </button>
        </form>
        <div className="mb-4 flex flex-wrap gap-2">
          {(dbgUsers ?? []).map((u) => (
            <form
              key={u.user_id}
              action={removeCallDebugUser}
              className="flex items-center gap-2 rounded-full border border-white/10 bg-white/5 px-3 py-1 text-xs"
            >
              <input type="hidden" name="user_id" value={u.user_id} />
              <span>{dbgNames.get(u.user_id) ?? u.note ?? u.user_id}</span>
              <button type="submit" className="text-red-300 hover:underline">
                retirer
              </button>
            </form>
          ))}
          {(dbgUsers ?? []).length === 0 && !dbgErr ? (
            <span className="text-sm text-sc-text-muted">Aucun compte suivi.</span>
          ) : null}
        </div>
        <div className="overflow-x-auto rounded-2xl border border-white/10">
          <table className="w-full text-left text-sm">
            <thead className="text-xs text-sc-text-muted">
              <tr>
                <th className="px-4 py-2">Quand</th>
                <th className="px-4 py-2">Qui</th>
                <th className="px-4 py-2">Sens</th>
                <th className="px-4 py-2">Compris</th>
                <th className="px-4 py-2">Réparé</th>
                <th className="px-4 py-2">Traduit</th>
              </tr>
            </thead>
            <tbody>
              {(phrases ?? []).map((p, i) => (
                <tr key={`${p.created_at}-${i}`} className="border-t border-white/5 align-top">
                  <td className="px-4 py-2 whitespace-nowrap text-sc-text-muted">
                    {new Date(p.created_at).toLocaleString("fr-FR")}
                  </td>
                  <td className="px-4 py-2">{dbgNames.get(p.user_id) ?? "—"}</td>
                  <td className="px-4 py-2 whitespace-nowrap">
                    {p.from_lang}→{p.to_lang}
                  </td>
                  <td className="px-4 py-2">{p.heard}</td>
                  <td className="px-4 py-2 text-sc-text-muted">{p.repaired}</td>
                  <td className="px-4 py-2">
                    {p.unclear ? <span className="text-sc-text-muted">illisible, rien envoyé</span> : p.translated}
                  </td>
                </tr>
              ))}
              {(phrases ?? []).length === 0 ? (
                <tr>
                  <td colSpan={6} className="px-4 py-6 text-center text-sc-text-muted">
                    Aucune phrase enregistrée.
                  </td>
                </tr>
              ) : null}
            </tbody>
          </table>
        </div>
      </Section>

      <Section title="Journal" hint="Les 40 dernières actions, toutes sources.">
        <div className="overflow-x-auto rounded-2xl border border-white/10">
          <table className="w-full text-left text-sm">
            <thead className="text-xs text-sc-text-muted">
              <tr>
                <th className="px-4 py-2">Quand</th>
                <th className="px-4 py-2">Action</th>
                <th className="px-4 py-2">Compte IA</th>
                <th className="px-4 py-2">Cible</th>
                <th className="px-4 py-2">Source</th>
                <th className="px-4 py-2">Statut</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.id} className="border-t border-white/5">
                  <td className="px-4 py-2 whitespace-nowrap text-sc-text-muted">
                    {new Date(r.created_at).toLocaleString("fr-FR")}
                  </td>
                  <td className="px-4 py-2">{KIND[r.kind] ?? r.kind}</td>
                  <td className="px-4 py-2">{names.get(r.ai_id) ?? "—"}</td>
                  <td className="px-4 py-2">{names.get(r.target_id) ?? "—"}</td>
                  <td className="px-4 py-2 text-sc-text-muted">{r.source}</td>
                  <td className="px-4 py-2">
                    {STATUS[r.status] ?? r.status}
                    {r.detail ? (
                      <span className="text-sc-text-muted"> · {r.detail}</span>
                    ) : null}
                  </td>
                </tr>
              ))}
              {rows.length === 0 ? (
                <tr>
                  <td
                    colSpan={6}
                    className="px-4 py-6 text-center text-sc-text-muted"
                  >
                    Rien pour l'instant.
                  </td>
                </tr>
              ) : null}
            </tbody>
          </table>
        </div>
      </Section>
    </>
  );
}
