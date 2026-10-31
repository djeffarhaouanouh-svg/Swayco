"use client";

import { useState } from "react";
import { RankBars, type RankItem } from "@/components/rank-bars";
import { Card } from "@/components/ui/card";
import { cn } from "@/lib/utils";

/**
 * Carte à deux onglets (« Pays les plus actifs » / « Langues parlées »),
 * à droite de la carte du monde sur la vue d'ensemble. Remplace les deux
 * RankBars côte à côte de l'ancienne page.
 */
export function RankTabs({
  countries,
  languages,
}: {
  countries: RankItem[];
  languages: RankItem[];
}) {
  const [tab, setTab] = useState<"pays" | "langues">("pays");
  const tabs = [
    { id: "pays", label: "Pays les plus actifs" },
    { id: "langues", label: "Langues parlées" },
  ] as const;

  return (
    <Card className="px-2 pt-4 pb-2">
      <div className="mx-3.5 mb-2 flex gap-1 rounded-full bg-sc-bg p-1">
        {tabs.map((t) => (
          <button
            key={t.id}
            type="button"
            onClick={() => setTab(t.id)}
            className={cn(
              "flex-1 cursor-pointer rounded-full px-3 py-[9px] text-[13.5px] font-bold transition-colors",
              tab === t.id
                ? "bg-white text-sc-text shadow-[0_1px_3px_rgba(4,18,58,0.14)]"
                : "text-sc-text-muted",
            )}
          >
            {t.label}
          </button>
        ))}
      </div>
      {tab === "pays" ? (
        <RankBars bare unit="pers." items={countries} />
      ) : (
        <RankBars bare unit="profils" items={languages} />
      )}
    </Card>
  );
}
