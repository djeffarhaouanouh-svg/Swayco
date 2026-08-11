import { cn } from "@/lib/utils";

/** A titled block. `hint` is the one line explaining what the block means. */
export function Section({
  title,
  hint,
  right,
  className,
  children,
}: {
  title: string;
  hint?: string;
  right?: React.ReactNode;
  className?: string;
  children: React.ReactNode;
}) {
  return (
    <section className={cn("mb-10", className)}>
      <div className="mb-4 flex items-end justify-between gap-4">
        <div>
          <h2 className="text-lg font-bold text-sc-text">{title}</h2>
          {hint ? (
            <p className="mt-0.5 text-sm text-sc-text-muted">{hint}</p>
          ) : null}
        </div>
        {right}
      </div>
      {children}
    </section>
  );
}

/** Page header — the h1 + subtitle every page opens with. */
export function PageHeader({
  title,
  subtitle,
  right,
}: {
  title: string;
  subtitle?: string;
  right?: React.ReactNode;
}) {
  return (
    <header className="mb-8 flex items-end justify-between gap-4">
      <div>
        <h1 className="text-3xl font-extrabold text-sc-text">{title}</h1>
        {subtitle ? (
          <p className="mt-1 text-sm text-sc-text-muted">{subtitle}</p>
        ) : null}
      </div>
      {right}
    </header>
  );
}
