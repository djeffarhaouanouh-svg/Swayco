import { cn } from "@/lib/utils";

const TONE = {
  blue: "sc-chip-blue",
  lemon: "sc-chip-lemon",
  cyan: "sc-chip-cyan",
  red: "sc-chip-red",
  grey: "sc-chip-grey",
} as const;

export type ChipTone = keyof typeof TONE;

/**
 * Pastille de statut. Correspondances :
 *  Ouvert / fait / compte trouvé → blue      Verrouillé / ignoré / pas inscrit → grey
 *  en attente / à ouvrir         → lemon     en cours                          → cyan
 *  échec                         → red
 */
export function Chip({
  tone = "grey",
  className,
  children,
}: {
  tone?: ChipTone;
  className?: string;
  children: React.ReactNode;
}) {
  return <span className={cn("sc-chip", TONE[tone], className)}>{children}</span>;
}

/** Point qui pulse (appels en cours, présence). Bleu + halo cyan, jamais vert. */
export function PingDot() {
  return (
    <span className="relative block h-2.5 w-2.5 shrink-0">
      <span className="sc-ping absolute inset-0 rounded-full bg-sc-cyan" />
      <span className="absolute inset-0 rounded-full bg-sc-accent" />
    </span>
  );
}
