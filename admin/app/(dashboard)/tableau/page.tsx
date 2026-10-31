import {
  CalendarDays,
  Lock,
  Phone,
  Repeat,
  TrendingUp,
  User,
  Users,
} from "lucide-react";
import { getGlobalTable, type MetricGroup, type MetricRow } from "@/lib/metrics";
import { PageHero, HeroPill } from "@/components/page-hero";
import { Section } from "@/components/section";
import { Flag } from "@/components/flag";
import { Chip } from "@/components/ui/chip";
import { GridTable, GridRow, GridEmpty } from "@/components/ui/grid-table";
import { getCountryDemand } from "@/lib/country-demand";
import { fmtInt } from "@/lib/format";

const GROUP_ICON: Record<MetricGroup, React.ComponentType<{ className?: string }>> = {
  Croissance: TrendingUp,
  Rétention: Repeat,
  Social: Users,
  Appels: Phone,
  Profil: User,
};

/** Colonne gauche : Croissance, Rétention, Profil. Colonne droite : Social, Appels. */
const LEFT: MetricGroup[] = ["Croissance", "Rétention", "Profil"];
const RIGHT: MetricGroup[] = ["Social", "Appels"];

const COUNTRY_COLS = "minmax(0,1.3fr) 150px 120px 230px 150px";

function GroupCard({ group, rows }: { group: MetricGroup; rows: MetricRow[] }) {
  const Icon = GROUP_ICON[group];
  return (
    <div className="sc-card overflow-hidden">
      <div className="flex items-center gap-3 bg-sc-accent/[0.04] px-6 py-[18px]">
        <span className="flex h-9 w-9 items-center justify-center rounded-xl bg-gradient-to-br from-sc-accent to-sc-cyan text-white">
          <Icon className="h-[19px] w-[19px]" />
        </span>
        <h2 className="font-display text-base font-semibold">{group}</h2>
        <span className="ml-auto text-[12.5px] text-sc-text-muted">
          {rows.length} mesures
        </span>
      </div>
      {rows.map((r) => (
        <div
          key={`${group}-${r.label}`}
          className="grid grid-cols-[minmax(0,1fr)_auto_78px] items-center gap-4 border-t border-sc-line px-6 py-3.5"
        >
          <div>
            <div className="text-[15px] font-semibold">{r.label}</div>
            {r.hint ? (
              <div className="mt-0.5 text-[12.5px] text-sc-text-muted">{r.hint}</div>
            ) : null}
          </div>
          <div className="sc-nums font-display text-[19px] font-bold whitespace-nowrap">
            {r.value}
          </div>
          <div className="sc-nums text-right text-[13px] whitespace-nowrap text-sc-text-muted">
            {r.window ?? ""}
          </div>
        </div>
      ))}
    </div>
  );
}

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
  const column = (groups: MetricGroup[]) =>
    groups
      .filter((g) => (byGroup.get(g) ?? []).length > 0)
      .map((g) => <GroupCard key={g} group={g} rows={byGroup.get(g)!} />);

  const sorted = [...countries].sort((a, b) => b.demand - a.demand);
  const maxActive = Math.max(...sorted.map((c) => c.active), 1);

  return (
    <>
      <PageHero
        title="Tableau global"
        subtitle="Tous les chiffres au même endroit. Sauf mention contraire, la colonne de droite cadre les 30 derniers jours."
        right={
          <HeroPill>
            <CalendarDays className="h-[19px] w-[19px]" />
            30 derniers jours
          </HeroPill>
        }
      />

      <div className="grid items-start gap-4 lg:grid-cols-2">
        <div className="flex flex-col gap-4">{column(LEFT)}</div>
        <div className="flex flex-col gap-4">{column(RIGHT)}</div>
      </div>

      <Section
        title="Pays — où investir"
        hint="Actifs : profils vus ces 30 derniers jours. Demande : personnes inscrites à « Me prévenir » sur le globe. Un pays très demandé et peu actif, c'est là qu'il faut mettre le prochain budget."
      >
        <GridTable
          cols={COUNTRY_COLS}
          head={[
            { label: "Pays" },
            { label: "Statut" },
            { label: "Profils", right: true },
            { label: "Actifs 30 j", right: true },
            { label: "Demande", right: true },
          ]}
        >
          {sorted.length === 0 ? (
            <GridEmpty>Aucune donnée pour l&apos;instant.</GridEmpty>
          ) : (
            sorted.map((c) => (
              <GridRow key={c.key} cols={COUNTRY_COLS}>
                <span className="flex items-center gap-2.5 font-semibold">
                  <Flag code={c.key} />
                  {c.label}
                </span>
                <span>
                  {c.open ? (
                    <Chip tone="blue">Ouvert</Chip>
                  ) : (
                    <Chip tone="grey">
                      <Lock className="h-3.5 w-3.5" />
                      Verrouillé
                    </Chip>
                  )}
                </span>
                <span className="sc-nums text-right text-sc-text-muted">
                  {fmtInt(c.profiles)}
                </span>
                <span className="flex items-center justify-end gap-3">
                  <span className="sc-track w-[120px]">
                    <i style={{ width: `${(c.active / maxActive) * 100}%` }} />
                  </span>
                  <span className="sc-nums w-[52px] text-right font-bold">
                    {fmtInt(c.active)}
                  </span>
                </span>
                <span className="sc-nums flex justify-end">
                  {c.open ? (
                    <span className="font-bold text-sc-accent">{fmtInt(c.demand)}</span>
                  ) : (
                    <span className="rounded-full bg-sc-lemon px-3 py-1 font-bold">
                      {fmtInt(c.demand)}
                    </span>
                  )}
                </span>
              </GridRow>
            ))
          )}
        </GridTable>
      </Section>
    </>
  );
}
