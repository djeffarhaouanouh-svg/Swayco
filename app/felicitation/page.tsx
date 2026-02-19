"use client";

import { Suspense } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import Link from "next/link";
import { CheckCircle2, ArrowRight } from "lucide-react";

function FelicitationContent() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const name = searchParams.get("name") ?? "";

  return (
    <div className="min-h-screen bg-[#0F0F0F] text-white flex flex-col items-center justify-center px-8 pt-[env(safe-area-inset-top)] pb-[calc(60px+env(safe-area-inset-bottom))]">
      <div className="flex flex-col items-center text-center max-w-sm">
        <CheckCircle2 className="w-24 h-24 text-[#f59e0b] mb-6" />
        <h1 className="text-2xl font-bold text-white mb-2">
          Félicitations !
        </h1>
        <p className="text-[#A3A3A3] mb-8">
          Personnage créé{name ? ` : ${name}` : ""}
        </p>
        <div className="flex flex-col gap-3 w-full">
          <Link
            href="/profil"
            className="flex items-center justify-center gap-2 w-full py-3 px-6 bg-[#f59e0b] rounded-xl font-medium text-white hover:bg-[#d97706] transition-colors"
          >
            Voir mon profil
            <ArrowRight className="w-5 h-5" />
          </Link>
          <button
            type="button"
            onClick={() => router.push("/")}
            className="py-3 px-6 rounded-xl font-medium text-[#A3A3A3] border border-[#2A2A2A] hover:border-[#f59e0b] hover:text-white transition-colors"
          >
            Accueil
          </button>
        </div>
      </div>
    </div>
  );
}

export default function FelicitationPage() {
  return (
    <Suspense fallback={null}>
      <FelicitationContent />
    </Suspense>
  );
}
