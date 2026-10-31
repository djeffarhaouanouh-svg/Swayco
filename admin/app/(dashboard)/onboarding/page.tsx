import Link from "next/link";
import { Check, Minus } from "lucide-react";
import { getOnboardingReport, type FunnelStep } from "@/lib/onboarding";
import { fmtInt, fmtPct } from "@/lib/format";
import { PageHero } from "@/components/page-hero";
import { Section } from "@/components/section";
import { Card } from "@/components/ui/card";
import { Chip } from "@/components/ui/chip";
import { GridTable, GridRow, GridEmpty } from "@/components/ui/grid-table";
import { cn } from "@/lib/utils";

const PERIODS = [7, 30, 90] as const;

function Bars({ steps, lastStrong }: { steps: FunnelStep[]; lastStrong?: boolean }) {
  return (
    <Card className="py-2">
      {steps.map((st, i) => {
        const strong = lastStrong && i === steps.length - 1;
        return (
          <div
            key={st.label}
            className="grid grid-cols-[minmax(0,1.3fr)_minmax(0,1.6fr)_64px_64px] items-center gap-4 px-6 py-[11px]"
          >
            <span className="min-w-0">
              <span className={cn("block truncate text-[14.5px]", strong ? "font-extrabold" : "font-semibold")}>
                {st.label}
              </span>
              {st.hint ? (
                <span className="block text-[12.5px] text-sc-text-muted">{st.hint}</span>
              ) : null}
            </span>
            <span className="sc-track">
              <i style={{ width: `${Math.round(st.pct * 100)}%` }} />
            </span>
            <span className="sc-nums text-right text-sm font-extrabold">{fmtInt(st.count)}</span>
            <span className="sc-nums text-right text-sm text-sc-text-muted">{fmtPct(st.pct)}</span>
          </div>
        );
      })}
    </Card>
  );
}

function Tick({ on }: { on: boolean }) {
  return on ? (
    <Check className="mx-auto h-[18px] w-[18px] text-sc-accent" />
  ) : (
    <Minus className="mx-auto h-[18px] w-[18px] text-sc-text-muted/50" />
  );
}

const RECENT_COLS = "130px minmax(0,1.2fr) minmax(0,1fr) 70px 70px 70px 70px 70px";

export default async function OnboardingPage({
  searchParams,
}: {
  searchParams: Promise<{ days?: string }>;
}) {
  const { days: raw } = await searchParams;
  const asked = Number(raw);
  const days = (PERIODS as readonly number[]).includes(asked) ? asked : 30;
  const r = await getOnboardingReport(days);

  const get = (label: string) => r.after.find((a) => a.label === label);
  const liked = get("Ont liké quelqu'un");
  const back = get("Sont revenus un autre jour");

  return (
    <>
      <PageHero
        title="Onboarding"
        subtitle="Les nouveaux inscrits terminent-ils l'onboarding, et que font-ils ensuite ? Humains uniquement : les comptes IA et de test sont exclus."
        right={
          <div className="flex gap-1.5 self-start">
            {PERIODS.map((p) => (
              <Link
                key={p}
                href={`/onboarding?days=${p}`}
                className={cn(
                  "sc-hero-pill",
                  p === days ? "font-extrabold" : "opacity-70 hover:opacity-100",
                )}
              >
                {p} j
              </Link>
            ))}
          </div>
        }
        kpis={{
          chip: `${days} DERNIERS JOURS`,
          hint: "Comptes créés sur la période.",
          items: [
            { label: "Comptes créés", value: fmtInt(r.created) },
            {
              label: "Onboarding terminé",
              value: fmtInt(r.completed),
              sub: `${fmtPct(r.created > 0 ? r.completed / r.created : 0)} des comptes`,
              lemon: true,
            },
            {
              label: "Ont liké",
              value: fmtPct(liked?.pct ?? 0),
              sub: `${fmtInt(liked?.count ?? 0)} sur ${fmtInt(r.completed)}`,
            },
            {
              label: "Revenus un autre jour",
              value: fmtPct(back?.pct ?? 0),
              sub: `${fmtInt(back?.count ?? 0)} sur ${fmtInt(r.completed)}`,
            },
          ],
        }}
      />

      <Section
        title="Les étapes de l'onboarding"
        hint="Part des comptes créés qui ont renseigné chaque information. « Terminé » = prénom, langue, genre et catégorie (le genre et la catégorie ne sont écrits que par l'onboarding ; un prénom peut être pré-rempli par Google ou Apple)."
      >
        <Bars steps={r.funnel} lastStrong />
        <p className="mt-3 text-[13px] leading-relaxed text-sc-text-muted">
          <strong className="text-sc-text-secondary">Limite :</strong> l&apos;onboarding se fait avant la
          connexion, et le profil n&apos;est enregistré qu&apos;à la fin. Quelqu&apos;un qui quitte avant de
          se connecter n&apos;apparaît donc pas ici. Indice : <strong>{fmtInt(r.anonymousSessions)}</strong>{" "}
          sessions de l&apos;app ont été ouvertes sans compte connecté sur la période (installations
          neuves et ouvertures sans connexion). Pour voir à quel écran les gens partent, il faut
          ajouter des événements dans l&apos;app (prochain build).
        </p>
      </Section>

      <Section
        title="Que font-ils ensuite ?"
        hint={`Parmi les ${fmtInt(r.completed)} comptes qui ont terminé l'onboarding, sur la période.`}
      >
        <Bars steps={r.after} />
      </Section>

      <Section
        title="Derniers inscrits"
        hint="Les 15 plus récents. Une coche = fait au moins une fois sur la période."
      >
        <GridTable
          cols={RECENT_COLS}
          head={[
            { label: "Inscrit" },
            { label: "Prénom" },
            { label: "Pays · langue" },
            { label: "Terminé" },
            { label: "Photo" },
            { label: "Like" },
            { label: "Message" },
            { label: "Revenu" },
          ]}
        >
          {r.recent.length === 0 ? (
            <GridEmpty>Aucune inscription sur la période.</GridEmpty>
          ) : (
            r.recent.map((u) => (
              <GridRow key={u.id} cols={RECENT_COLS}>
                <span className="text-[13.5px] whitespace-nowrap text-sc-text-muted">
                  {new Date(u.createdAt).toLocaleString("fr-FR", {
                    day: "2-digit",
                    month: "2-digit",
                    hour: "2-digit",
                    minute: "2-digit",
                  })}
                </span>
                <span className="truncate font-semibold">{u.name}</span>
                <span className="flex items-center gap-2 truncate text-sc-text-secondary">
                  {u.country || "—"}
                  {u.language ? <Chip tone="grey">{u.language.toUpperCase()}</Chip> : null}
                </span>
                <Tick on={u.complete} />
                <Tick on={u.hasPhoto} />
                <Tick on={u.liked} />
                <Tick on={u.messaged} />
                <Tick on={u.returned} />
              </GridRow>
            ))
          )}
        </GridTable>
      </Section>
    </>
  );
}
