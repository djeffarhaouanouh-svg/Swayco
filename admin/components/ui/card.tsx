import { cn } from "@/lib/utils";

/** The app's glass panel: translucent white over the mesh, hairline border. */
export function Card({
  className,
  children,
}: {
  className?: string;
  children: React.ReactNode;
}) {
  return (
    <div className={cn("sc-glass rounded-2xl", className)}>{children}</div>
  );
}
