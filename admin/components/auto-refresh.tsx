"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";

/**
 * Re-runs the server components of the current route on an interval —
 * used by the Live page. Logique INCHANGÉE ; seul le rendu passe en
 * pastille de verre pour le coin haut-droit du bandeau bleu (<PageHero right=…>).
 */
export function AutoRefresh({ seconds = 20 }: { seconds?: number }) {
  const router = useRouter();
  const [countdown, setCountdown] = useState(seconds);

  useEffect(() => {
    const tick = setInterval(() => {
      setCountdown((c) => {
        if (c <= 1) {
          router.refresh();
          return seconds;
        }
        return c - 1;
      });
    }, 1000);
    return () => clearInterval(tick);
  }, [router, seconds]);

  return (
    <span className="sc-hero-pill">
      <span className="h-[9px] w-[9px] rounded-full bg-sc-lemon shadow-[0_0_0_4px_rgba(244,255,31,0.3)]" />
      Actualisation auto · {countdown} s
    </span>
  );
}
