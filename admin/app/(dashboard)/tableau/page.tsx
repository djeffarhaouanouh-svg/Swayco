import React from "react";
import { getGlobalTable, type MetricGroup, type MetricRow } from "@/lib/metrics";
import { PageHeader, Section } from "@/components/section";
import { Card } from "@/components/ui/card";
import { getCountryDemand } from "@/lib/country-demand";
import { fmtInt } from "@/lib/format";

/** Render order — growth first, money-free, ending on profile quality. */
const GROUPS: MetricGroup[] = [
  "Croissance",
  "Rétention",
  "Social",
  "Appels",
  "Profil",
];

export default async function GlobalTablePage() {
  const [rows, countries] = await Promise.all([
    getGlobalTable(),
    getCountryDemand(),
  ]);
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

      <Section
        title="Pays — où investir"
        hint="Actifs : profils vus ces 30 derniers jours. Demande : personnes inscrites à « Me prévenir » sur le globe. Un pays très demandé et peu actif, c'est là qu'il faut mettre le prochain budget."
        className="mt-10"
      >
        <Card className="overflow-hidden">
          <table className="w-full text-sm">
            <thead>
              <tr className="text-left text-xs font-bold tracking-wide text-sc-text-muted uppercase">
                <th className="px-5 py-3">Pays</th>
                <th className="px-5 py-3">Statut</th>
                <th className="px-5 py-3 text-right">Profils</th>
                <th className="px-5 py-3 text-right">Actifs 30 j</th>
                <th className="px-5 py-3 text-right">Demande</th>
              </tr>
            </thead>
            <tbody>
              {countries.length === 0 ? (
                <tr className="border-t border-white/5">
                  <td colSpan={5} className="px-5 py-6 text-center text-sc-text-muted">
                    Aucune donnée pour l&apos;instant.
                  </td>
                </tr>
              ) : (
                countries.map((c) => (
                  <tr
                    key={c.key}
                    className="border-t border-white/5 transition-colors hover:bg-white/[0.02]"
                  >
                    <td className="px-5 py-3 text-sc-text">{c.label}</td>
                    <td className="px-5 py-3">
                      <span
                        className={
                          c.open
                            ? "rounded-full bg-emerald-400/15 px-2.5 py-0.5 text-xs font-semibold text-emerald-300"
                            : "rounded-full bg-white/10 px-2.5 py-0.5 text-xs font-semibold text-sc-text-muted"
                        }
                      >
                        {c.open ? "Ouvert" : "Verrouillé"}
                      </span>
                    </td>
                    <td className="sc-nums px-5 py-3 text-right text-sc-text-muted">
                      {fmtInt(c.profiles)}
                    </td>
                    <td className="sc-nums px-5 py-3 text-right font-semibold text-sc-text">
                      {fmtInt(c.active)}
                    </td>
                    <td className="sc-nums px-5 py-3 text-right font-semibold text-sc-accent">
                      {fmtInt(c.demand)}
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </Card>
      </Section>
    </>
  );
}
