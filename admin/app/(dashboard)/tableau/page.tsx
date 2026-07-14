import { Fragment } from "react";
import { getGlobalTable, type MetricRow } from "@/lib/metrics";
import { SectionHeader } from "@/components/section";

export default async function TableauPage() {
  const rows = await getGlobalTable();

  // Group rows, preserving first-seen order.
  const groups: { name: string; rows: MetricRow[] }[] = [];
  for (const r of rows) {
    let g = groups.find((x) => x.name === r.group);
    if (!g) {
      g = { name: r.group, rows: [] };
      groups.push(g);
    }
    g.rows.push(r);
  }

  return (
    <>
      <SectionHeader
        title="Tableau global"
        description="Toutes les métriques de l'app, une par ligne. Les moyennes « par utilisateur » sont calculées sur l'ensemble du cycle de vie."
      />

      <div className="overflow-x-auto rounded-xl border border-zinc-800">
        <table className="w-full min-w-[680px] text-sm">
          <thead>
            <tr className="border-b border-zinc-800 bg-zinc-900/60 text-left text-xs uppercase tracking-wide text-zinc-500">
              <th className="px-4 py-3 font-medium">Métrique</th>
              <th className="px-4 py-3 text-right font-medium">Total</th>
              <th className="px-4 py-3 text-right font-medium">
                Par utilisateur
              </th>
              <th className="px-4 py-3 font-medium">Détail</th>
            </tr>
          </thead>
          <tbody>
            {groups.map((g) => (
              <Fragment key={g.name}>
                <tr className="bg-zinc-900/40">
                  <td
                    colSpan={4}
                    className="px-4 py-2 text-xs font-semibold uppercase tracking-wider text-zinc-400"
                  >
                    {g.name}
                  </td>
                </tr>
                {g.rows.map((r) => (
                  <tr
                    key={r.label}
                    className="border-t border-zinc-800/60 transition-colors hover:bg-zinc-800/30"
                  >
                    <td className="px-4 py-3 text-zinc-200">{r.label}</td>
                    <td className="px-4 py-3 text-right font-medium tabular-nums text-zinc-50">
                      {r.total}
                    </td>
                    <td className="px-4 py-3 text-right tabular-nums text-cyan-300">
                      {r.perUser}
                    </td>
                    <td className="px-4 py-3 text-zinc-500">{r.detail}</td>
                  </tr>
                ))}
              </Fragment>
            ))}
          </tbody>
        </table>
      </div>

      <p className="mt-4 text-xs text-zinc-600">
        Les moyennes « par utilisateur » = total cumulé ÷ nombre total
        d&apos;utilisateurs. Les métriques d&apos;activité (DAU, rétention,
        nouveaux) gardent leur fenêtre temporelle, indiquée dans la colonne
        Détail.
      </p>
    </>
  );
}
