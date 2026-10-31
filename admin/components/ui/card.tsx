import { cn } from "@/lib/utils";

/** Carte blanche de la direction 1c (rayon 22, ombre douce). */
export function Card({
  className,
  children,
}: {
  className?: string;
  children: React.ReactNode;
}) {
  return <div className={cn("sc-card", className)}>{children}</div>;
}
