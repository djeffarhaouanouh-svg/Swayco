import { Card } from "@/components/ui/card";
import { cn } from "@/lib/utils";

/**
 * One headline number. `tone` colours the value: "accent" for the metric
 * the page is about, "online" for presence, "plain" for the rest — so a
 * KPI row has one obvious focal point instead of eight shouting cyans.
 */
export function KpiCard({
  label,
  value,
  sub,
  tone = "plain",
  className,
}: {
  label: string;
  value: string;
  sub?: string;
  tone?: "plain" | "accent" | "online";
  className?: string;
}) {
  return (
    <Card className={cn("p-5", className)}>
      <div className="text-xs font-semibold tracking-wide text-sc-text-muted uppercase">
        {label}
      </div>
      {/* Proportional figures, body sans: a large standalone number reads
          loose in tabular digits and off-brand in the display face. */}
      <div
        className={cn(
          "mt-2 text-3xl font-bold",
          tone === "accent" && "text-sc-accent",
          tone === "online" && "text-sc-online",
          tone === "plain" && "text-sc-text",
        )}
      >
        {value}
      </div>
      {sub ? (
        <div className="mt-1 text-sm text-sc-text-secondary">{sub}</div>
      ) : null}
    </Card>
  );
}

/** Responsive KPI grid — `cols` is the count at the widest breakpoint. */
export function KpiGrid({
  cols = 4,
  children,
}: {
  cols?: 3 | 4;
  children: React.ReactNode;
}) {
  return (
    <div
      className={cn(
        "grid gap-4 sm:grid-cols-2",
        cols === 4 ? "lg:grid-cols-4" : "lg:grid-cols-3",
      )}
    >
      {children}
    </div>
  );
}
