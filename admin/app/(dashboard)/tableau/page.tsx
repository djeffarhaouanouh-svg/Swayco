import React from "react";
import { getGlobalTable, type MetricGroup, type MetricRow } from "@/lib/metrics";
import { PageHeader } from "@/components/section";
import { Card } from "@/components/ui/card";

/** Render order — growth first, money-free, ending on profile quality. */
const GROUPS: MetricGroup[] = [
  "Croissance",
  "Rétention",
  "Social",
  "Appels",
  "Profil",
];

export default async function GlobalTablePage() {
  const rows = await getGlobalTable();
  const byGroup = new Map<MetricGroup, MetricRow[]>();
  for (const r of rows) {
    if (!byGroup.has(r.group)) byGroup.set(r.group, []);
    byGroup.get(r.group)!.push(r);
  }

  return (
    <>
      <PageHeader
        title="Tableau global"
        subtitle="Tous les chiffres au même endroit. Sauf mention contraire, la colonne de droite cadre les 30 derniers jours."
      />

      <Card className="overflow-hidden">
        <table className="w-full text-sm">
          <tbody>
            {GROUPS.map((group) => {
              const groupRows = byGroup.get(group) ?? [];
              if (groupRows.length === 0) return null;
              return (
                <React.Fragment key={group}>
                  <tr>
                    <th
                      colSpan={3}
                      className="border-t border-white/10 bg-white/[0.04] px-5 py-2.5 text-left text-xs font-bold tracking-wide text-sc-accent uppercase"
                    >
                      {group}
                    </th>
                  </tr>
                  {groupRows.map((r) => (
                    <tr
                      key={`${group}-${r.label}`}
                      className="border-t border-white/5 transition-colors hover:bg-white/[0.02]"
                    >
                      <td className="px-5 py-3">
                        <div className="text-sc-text">{r.label}</div>
                        {r.hint ? (
                          <div className="mt-0.5 text-xs text-sc-text-muted">
                            {r.hint}
                          </div>
                        ) : null}
                      </td>
                      <td className="sc-nums px-5 py-3 text-right font-semibold whitespace-nowrap text-sc-text">
                        {r.value}
                      </td>
                      <td className="sc-nums w-36 px-5 py-3 text-right whitespace-nowrap text-sc-text-muted">
                        {r.window ?? ""}
                      </td>
                    </tr>
                  ))}
                </React.Fragment>
              );
            })}
          </tbody>
        </table>
      </Card>
    </>
  );
}
