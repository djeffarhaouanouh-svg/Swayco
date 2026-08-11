"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import {
  LayoutDashboard,
  LogOut,
  Radio,
  Repeat,
  Table2,
  Users,
} from "lucide-react";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { cn } from "@/lib/utils";

const NAV = [
  { href: "/", label: "Vue d'ensemble", icon: LayoutDashboard },
  { href: "/tableau", label: "Tableau global", icon: Table2 },
  { href: "/live", label: "Live", icon: Radio },
  { href: "/social", label: "Social", icon: Users },
  { href: "/retention", label: "Rétention", icon: Repeat },
];

export function Sidebar({ adminEmail }: { adminEmail: string }) {
  const pathname = usePathname();
  const router = useRouter();

  async function signOut() {
    await createSupabaseBrowserClient().auth.signOut();
    router.replace("/login");
    router.refresh();
  }

  return (
    <aside className="flex w-60 shrink-0 flex-col border-r border-white/10 bg-white/[0.03] backdrop-blur-xl">
      <div className="px-5 py-6">
        <div className="font-display text-xl font-bold tracking-tight text-sc-text">
          swaycø
        </div>
        <div className="mt-0.5 text-xs text-sc-text-muted">
          Tableau de bord admin
        </div>
      </div>

      <nav className="flex-1 space-y-1 px-3">
        {NAV.map(({ href, label, icon: Icon }) => {
          const active =
            href === "/" ? pathname === "/" : pathname.startsWith(href);
          return (
            <Link
              key={href}
              href={href}
              className={cn(
                "flex items-center gap-3 rounded-xl px-3 py-2 text-sm transition-colors",
                active
                  ? "bg-sc-accent/12 text-sc-accent"
                  : "text-sc-text-secondary hover:bg-white/5 hover:text-sc-text",
              )}
            >
              <Icon className="h-4 w-4" />
              {label}
            </Link>
          );
        })}
      </nav>

      <div className="border-t border-white/10 p-3">
        <div className="truncate px-2 pb-2 text-xs text-sc-text-muted">
          {adminEmail}
        </div>
        <button
          onClick={signOut}
          className="flex w-full items-center gap-3 rounded-xl px-3 py-2 text-sm text-sc-text-secondary transition-colors hover:bg-white/5 hover:text-sc-text"
        >
          <LogOut className="h-4 w-4" />
          Déconnexion
        </button>
      </div>
    </aside>
  );
}
