"use client";

import Link from "next/link";
import { ArrowLeft } from "lucide-react";

export default function PersonnagesPage() {
  return (
    <div className="min-h-screen bg-[#0F0F0F] text-white flex flex-col pt-[env(safe-area-inset-top)] pb-[calc(60px+env(safe-area-inset-bottom))]">
      <header className="sticky top-0 z-50 flex items-center gap-3 px-4 py-3 border-b border-[#2A2A2A] bg-[#0F0F0F]">
        <Link href="/profil" className="p-2 rounded-lg hover:bg-[#1A1A1A] transition-colors">
          <ArrowLeft className="w-5 h-5" />
        </Link>
        <h1 className="text-lg font-semibold">Personnages</h1>
      </header>
      <main className="flex-1 flex items-center justify-center">
        <p className="text-[#A3A3A3]">Bientôt disponible</p>
      </main>
    </div>
  );
}
