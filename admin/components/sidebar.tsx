"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import {
  Languages,
  LayoutDashboard,
  LogOut,
  Radio,
  Repeat,
  Table2,
  Users,
  Wallet,
} from "lucide-react";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { cn } from "@/lib/utils";

const NAV = [
  { href: "/", label: "Vue d'ensemble", icon: LayoutDashboard },
  { href: "/tableau", label: "Tableau global", icon: Table2 },
  { href: "/live", label: "Live", icon: Radio },
  { href: "/traduction", label: "Traduction", icon: Languages },
  { href: "/social", label: "Social", icon: Users },
  { href: "/retention", label: "Rétention", icon: Repeat },
  { href: "/monetisation", label: "Monétisation", icon: Wallet },
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
    <aside className="flex w-60 shrink-0 flex-col border-r border-zinc-800 bg-zinc-900/40">
      <div className="px-5 py-5">
        <div className="text-lg font-semibold text-zinc-50">Swayco</div>
        <div className="text-xs text-zinc-500">Tableau de bord admin</div>
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
                "flex items-center gap-3 rounded-lg px-3 py-2 text-sm transition-colors",
                active
                  ? "bg-zinc-800 text-zinc-50"
                  : "text-zinc-400 hover:bg-zinc-800/50 hover:text-zinc-200",
              )}
            >
              <Icon className="h-4 w-4" />
              {label}
            </Link>
          );
        })}
      </nav>

      <div className="border-t border-zinc-800 p-3">
        <div className="truncate px-2 pb-2 text-xs text-zinc-500">
          {adminEmail}
        </div>
        <button
          onClick={signOut}
          className="flex w-full items-center gap-3 rounded-lg px-3 py-2 text-sm text-zinc-400 transition-colors hover:bg-zinc-800/50 hover:text-zinc-200"
        >
          <LogOut className="h-4 w-4" />
          Déconnexion
        </button>
      </div>
    </aside>
  );
}
