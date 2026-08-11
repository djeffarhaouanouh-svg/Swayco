"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";

/**
 * Re-runs the server components of the current route on an interval —
 * used by the Live page, which is only useful if it is actually live.
 *
 * `router.refresh()` swaps in fresh server-rendered content without a
 * full reload and without unmounting, so there is no skeleton flash and
 * no layout jump; the previous render simply stays until the new one
 * lands.
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
    <span className="flex items-center gap-2 text-xs text-sc-text-muted">
      <span className="relative flex h-2 w-2">
        <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-sc-online opacity-60" />
        <span className="relative inline-flex h-2 w-2 rounded-full bg-sc-online" />
      </span>
      Actualisation dans {countdown} s
    </span>
  );
}
