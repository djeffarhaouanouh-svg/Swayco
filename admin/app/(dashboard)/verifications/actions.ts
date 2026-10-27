"use server";

import { revalidatePath } from "next/cache";
import { requireAdmin } from "@/lib/require-admin";
import { REJECT_REASONS } from "./labels";

/** Private bucket (migration 0077): the app can only drop files in it. */
const BUCKET = "verification-selfies";

const UUID = /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;

type Copy = { title: string; body: string };
const APPROVED: Record<string, Copy> = {
  fr: { title: "Ton profil est vérifié ✨", body: "Ta pastille « Vérifié » s'affiche maintenant sur ton profil." },
  en: { title: "Your profile is verified ✨", body: "Your “Verified” badge now shows on your profile." },
  es: { title: "Tu perfil está verificado ✨", body: "Tu insignia «Verificado» ya aparece en tu perfil." },
  de: { title: "Dein Profil ist verifiziert ✨", body: "Dein Abzeichen „Verifiziert“ wird jetzt in deinem Profil angezeigt." },
  it: { title: "Il tuo profilo è verificato ✨", body: "Il tuo distintivo «Verificato» ora appare sul tuo profilo." },
  pt: { title: "O teu perfil está verificado ✨", body: "O teu distintivo «Verificado» já aparece no teu perfil." },
  nl: { title: "Je profiel is geverifieerd ✨", body: "Je badge ‘Geverifieerd’ staat nu op je profiel." },
  ar: { title: "تم توثيق ملفك الشخصي ✨", body: "تظهر شارة «موثّق» الآن على ملفك الشخصي." },
  ru: { title: "Твой профиль проверен ✨", body: "Значок «Проверено» теперь отображается в твоём профиле." },
  zh: { title: "你的资料已通过验证 ✨", body: "「已认证」标识现已显示在你的资料上。" },
  ja: { title: "プロフィールが認証されました ✨", body: "「認証済み」バッジがプロフィールに表示されるようになりました。" },
  ko: { title: "프로필이 인증되었어요 ✨", body: "이제 프로필에 '인증됨' 배지가 표시돼요." },
};
const REJECTED: Record<string, Copy> = {
  fr: { title: "Vérification refusée", body: "Tu peux réessayer avec un nouveau selfie." },
  en: { title: "Verification declined", body: "You can try again with a new selfie." },
  es: { title: "Verificación rechazada", body: "Puedes volver a intentarlo con un nuevo selfie." },
  de: { title: "Verifizierung abgelehnt", body: "Du kannst es mit einem neuen Selfie erneut versuchen." },
  it: { title: "Verifica rifiutata", body: "Puoi riprovare con un nuovo selfie." },
  pt: { title: "Verificação recusada", body: "Podes tentar novamente com um novo selfie." },
  nl: { title: "Verificatie geweigerd", body: "Je kunt het opnieuw proberen met een nieuwe selfie." },
  ar: { title: "تم رفض التحقق", body: "يمكنك المحاولة مرة أخرى بصورة سيلفي جديدة." },
  ru: { title: "Проверка не пройдена", body: "Ты можешь попробовать снова с новым селфи." },
  zh: { title: "验证未通过", body: "你可以用新的自拍重新尝试。" },
  ja: { title: "認証できませんでした", body: "新しい自撮りでもう一度お試しください。" },
  ko: { title: "인증이 거절되었어요", body: "새 셀카로 다시 시도할 수 있어요." },
};

/**
 * Push « profil vérifié » / « vérification refusée » through the backend
 * (`POST /api/notify`, backend/server.js), in the person's own language.
 * Best effort: the decision is already saved, so a push that fails or a missing
 * `BACKEND_URL` never undoes it.
 */
async function pushDecision(
  svc: Awaited<ReturnType<typeof requireAdmin>>["svc"],
  userId: string,
  approved: boolean,
) {
  const base = (process.env.BACKEND_URL ?? "").replace(/\/+$/, "");
  if (!base) return;
  try {
    const { data } = await svc
      .from("profiles")
      .select("language")
      .eq("id", userId)
      .maybeSingle();
    const lang = String(data?.language ?? "")
      .split("-")[0]
      .toLowerCase();
    const table = approved ? APPROVED : REJECTED;
    const copy = table[lang] ?? table.en;
    await fetch(`${base}/api/notify`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        recipientUid: userId,
        title: copy.title,
        body: copy.body,
        type: "verification",
        data: { status: approved ? "approved" : "rejected" },
      }),
      signal: AbortSignal.timeout(8000),
    });
  } catch {
    /* best effort */
  }
}

/**
 * Settle one pending request. The selfie is deleted from the private bucket as
 * soon as the decision is made: it was only ever there to be compared, and it
 * never becomes a profile photo.
 */
async function decide(id: string, approved: boolean, reason: string | null) {
  const { svc } = await requireAdmin();
  if (!UUID.test(id)) return;

  const { data: req } = await svc
    .from("profile_verifications")
    .select("id, user_id, selfie_path, status")
    .eq("id", id)
    .maybeSingle();
  if (!req || req.status !== "pending") return; // already settled elsewhere

  // Approval first writes the flag (idempotent): if this fails the request stays
  // pending and can simply be approved again, never half-done the other way.
  if (approved) {
    const { error } = await svc
      .from("profiles")
      .update({ is_verified: true })
      .eq("id", req.user_id);
    if (error) throw new Error(error.message);
  }

  const now = new Date().toISOString();
  const { data: updated, error: updErr } = await svc
    .from("profile_verifications")
    .update({
      status: approved ? "approved" : "rejected",
      reviewed_at: now,
      reject_reason: approved ? null : reason,
    })
    .eq("id", id)
    .eq("status", "pending")
    .select("id");
  if (updErr) throw new Error(updErr.message);
  if (!updated?.length) return; // someone else settled it in between

  const { error: rmErr } = await svc.storage
    .from(BUCKET)
    .remove([req.selfie_path]);
  if (!rmErr) {
    await svc
      .from("profile_verifications")
      .update({ selfie_deleted_at: now })
      .eq("id", id);
  }

  await pushDecision(svc, req.user_id, approved);
  revalidatePath("/verifications");
}

export async function approveVerification(formData: FormData): Promise<void> {
  await decide(String(formData.get("id") ?? ""), true, null);
}

export async function rejectVerification(formData: FormData): Promise<void> {
  const reason = String(formData.get("reason") ?? "");
  // A refusal always carries one of the listed reasons.
  if (!(reason in REJECT_REASONS)) return;
  await decide(String(formData.get("id") ?? ""), false, reason);
}
