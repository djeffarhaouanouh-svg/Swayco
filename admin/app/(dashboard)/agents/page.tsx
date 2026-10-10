import { createSupabaseServiceClient } from "@/lib/supabase/service";
import { KpiCard, KpiGrid } from "@/components/kpi-card";
import { PageHeader, Section } from "@/components/section";
import { AgentsForm } from "./agents-form";

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
