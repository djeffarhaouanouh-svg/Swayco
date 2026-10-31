/* eslint-disable @next/next/no-img-element */
/**
 * Drapeau en image (flagcdn). Les emojis de drapeaux (flag() de lib/format.ts)
 * s'affichent en lettres « FR » sous Windows ; une image marche partout.
 * `code` = ISO 3166-1 alpha-2, majuscules ou minuscules.
 */
export function Flag({ code, size = 22 }: { code: string; size?: number }) {
  if (!/^[A-Za-z]{2}$/.test(code)) return null;
  const h = Math.round(size * 0.72);
  return (
    <img
      src={`https://flagcdn.com/w40/${code.toLowerCase()}.png`}
      alt=""
      width={size}
      height={h}
      style={{ width: size, height: h }}
      className="shrink-0 rounded object-cover shadow-[0_0_0_1px_rgba(4,18,58,0.14)]"
    />
  );
}
