// Display formatting helpers — French locale throughout (the audience
// is the Swayco team), all defensive against null / NaN inputs.

const NF = new Intl.NumberFormat("fr-FR");
const NF1 = new Intl.NumberFormat("fr-FR", { maximumFractionDigits: 1 });

export function fmtInt(n: number | null | undefined): string {
  return NF.format(Math.round(Number(n) || 0));
}

export function fmtNum(n: number | null | undefined): string {
  return NF1.format(Number(n) || 0);
}

/** `frac` is a 0..1 ratio. */
export function fmtPct(frac: number | null | undefined, digits = 0): string {
  return `${((Number(frac) || 0) * 100).toFixed(digits)} %`;
}

export function fmtEur(n: number | null | undefined): string {
  return new Intl.NumberFormat("fr-FR", {
    style: "currency",
    currency: "EUR",
    maximumFractionDigits: 0,
  }).format(Number(n) || 0);
}

/** Euro with 2 decimals — for subscription prices like 9,99 €. */
export function fmtEur2(n: number | null | undefined): string {
  return new Intl.NumberFormat("fr-FR", {
    style: "currency",
    currency: "EUR",
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(Number(n) || 0);
}

export function fmtUsd(n: number | null | undefined): string {
  return new Intl.NumberFormat("fr-FR", {
    style: "currency",
    currency: "USD",
    maximumFractionDigits: 2,
  }).format(Number(n) || 0);
}

export function fmtLatency(ms: number | null | undefined): string {
  const v = Number(ms) || 0;
  if (v <= 0) return "—";
  if (v < 1000) return `${Math.round(v)} ms`;
  return `${(v / 1000).toFixed(1)} s`;
}

export function fmtMinutes(min: number | null | undefined): string {
  const v = Number(min) || 0;
  if (v < 60) return `${Math.round(v)} min`;
  return `${NF1.format(v / 60)} h`;
}

/** UTC day key, e.g. "2026-05-21". Used as the bucket key for series. */
export function dayKey(d: Date): string {
  return d.toISOString().slice(0, 10);
}

/** "2026-05-21" → "21 mai". */
export function shortDay(key: string): string {
  const d = new Date(`${key}T00:00:00Z`);
  return d.toLocaleDateString("fr-FR", {
    day: "numeric",
    month: "short",
    timeZone: "UTC",
  });
}

/** ISO-3166 alpha-2 → French country name. */
export function countryName(code: string): string {
  try {
    const dn = new Intl.DisplayNames(["fr"], { type: "region" });
    return dn.of(code.toUpperCase()) ?? code;
  } catch {
    return code;
  }
}

/** ISO-3166 alpha-2 → emoji flag. */
export function flag(code: string): string {
  if (!/^[A-Za-z]{2}$/.test(code)) return "";
  const A = 0x1f1e6;
  const up = code.toUpperCase();
  return String.fromCodePoint(
    A + up.charCodeAt(0) - 65,
    A + up.charCodeAt(1) - 65,
  );
}
