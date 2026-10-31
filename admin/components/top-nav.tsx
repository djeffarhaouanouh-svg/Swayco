"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import {
  BadgeCheck,
  Bot,
  LayoutDashboard,
  LogOut,
  Radio,
  Repeat,
  Table2,
  Users,
} from "lucide-react";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { cn } from "@/lib/utils";

// Mêmes 7 entrées, même ordre, mêmes routes que l'ancienne Sidebar.
const NAV = [
  { href: "/", label: "Vue d'ensemble", icon: LayoutDashboard },
  { href: "/tableau", label: "Tableau global", icon: Table2 },
  { href: "/live", label: "Live", icon: Radio },
  { href: "/social", label: "Social", icon: Users },
  { href: "/retention", label: "Rétention", icon: Repeat },
  { href: "/agents", label: "Comptes IA", icon: Bot },
  { href: "/verifications", label: "Vérifications", icon: BadgeCheck },
];

export function TopNav({ adminEmail }: { adminEmail: string }) {
  const pathname = usePathname();
  const router = useRouter();

  async function signOut() {
    await createSupabaseBrowserClient().auth.signOut();
    router.replace("/login");
    router.refresh();
  }

  return (
    <header className="sticky top-0 z-30 flex h-[76px] items-center gap-7 border-b border-sc-line bg-white px-8">
      <Link
        href="/"
        className="font-logo text-[30px] font-bold tracking-[-0.01em] text-sc-text"
      >
        swayc<span className="text-sc-accent">ø</span>
      </Link>

      <nav className="flex flex-1 gap-1 overflow-x-auto">
        {NAV.map(({ href, label, icon: Icon }) => {
          const active =
            href === "/" ? pathname === "/" : pathname.startsWith(href);
          return (
            <Link
              key={href}
              href={href}
              className={cn(
                "flex items-center gap-2 rounded-full py-2.5 text-sm whitespace-nowrap transition-colors",
                active
                  ? "bg-sc-text px-4 font-bold text-white"
                  : "px-3.5 font-semibold text-sc-text-secondary hover:bg-sc-text/5",
              )}
            >
              <Icon className="h-[19px] w-[19px]" />
              {label}
            </Link>
          );
        })}
      </nav>

      <div className="flex items-center gap-3">
        <span className="hidden text-[13px] text-sc-text-muted xl:inline">
          {adminEmail}
        </span>
        <span className="flex h-[34px] w-[34px] items-center justify-center rounded-full bg-gradient-to-br from-sc-accent to-sc-cyan text-sm font-extrabold text-white">
          {(adminEmail[0] ?? "A").toUpperCase()}
        </span>
        <button
          onClick={signOut}
          aria-label="Déconnexion"
          className="cursor-pointer text-sc-text-secondary transition-colors hover:text-sc-text"
        >
          <LogOut className="h-[22px] w-[22px]" />
        </button>
      </div>
    </header>
  );
}
