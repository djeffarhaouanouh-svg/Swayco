"use server";

import { revalidatePath } from "next/cache";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { createSupabaseServiceClient } from "@/lib/supabase/service";

export type QueueState = { ok: boolean; message: string } | null;

const UUID = /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;

/**
 * Same boundary as the dashboard layout (must be signed in AND
 * `profiles.is_admin`) — a server action is a public POST endpoint, so the
 * layout check alone does not protect it.
 */
async function requireAdmin() {
  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) throw new Error("Non connecté.");
  const svc = createSupabaseServiceClient();
  const { data } = await svc
    .from("profiles")
    .select("is_admin")
    .eq("id", user.id)
    .maybeSingle();
  if (!data?.is_admin) throw new Error("Accès refusé.");
  return { svc, userId: user.id };
}

function shuffle<T>(arr: T[]): T[] {
  const a = [...arr];
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

/**
 * Queue "N AI accounts (optionally of one country / gender) like or write to
 * this user". Nothing is executed here: the backend (backend/ai_agents.js)
 * picks the rows up at their `run_at`, spread over the chosen window so it
 * never looks like a burst.
 */
export async function queueAiActions(
  _prev: QueueState,
  formData: FormData,
): Promise<QueueState> {
  try {
    const { svc, userId } = await requireAdmin();

    const kind = String(formData.get("kind") ?? "");
    if (kind !== "like" && kind !== "message") {
      return { ok: false, message: "Action inconnue." };
    }
    const country = String(formData.get("country") ?? "").trim();
    const gender = String(formData.get("gender") ?? "").trim();
    if (gender && gender !== "m" && gender !== "f") {
      return { ok: false, message: "Genre invalide." };
    }
    const count = Math.floor(Number(formData.get("count")));
    if (!Number.isFinite(count) || count < 1 || count > 200) {
      return { ok: false, message: "Nombre de comptes : entre 1 et 200." };
    }
    const spread = Math.floor(Number(formData.get("spread") ?? 0));
    if (!Number.isFinite(spread) || spread < 0 || spread > 720) {
      return { ok: false, message: "Étalement : entre 0 et 720 minutes." };
    }
    const body = String(formData.get("body") ?? "").trim().slice(0, 500);

    // Target: a user id, or a handle (with or without the @).
    const rawTarget = String(formData.get("target") ?? "").trim();
    if (!rawTarget) return { ok: false, message: "Indique la cible." };
    const targetQ = svc.from("profiles").select("id, display_name, is_ai");
    const { data: target } = await (UUID.test(rawTarget)
      ? targetQ.eq("id", rawTarget)
      : targetQ.eq("handle", rawTarget.replace(/^@/, ""))
    ).maybeSingle();
    if (!target) return { ok: false, message: "Cible introuvable." };
    if (target.is_ai) {
      return { ok: false, message: "La cible est un compte IA : refusé." };
    }

    // Candidate AI accounts.
    let q = svc.from("profiles").select("id").eq("is_ai", true).limit(5000);
    if (country) q = q.eq("country", country);
    if (gender) q = q.eq("gender", gender);
    const { data: pool, error } = await q;
    if (error) return { ok: false, message: error.message };
    if (!pool || pool.length === 0) {
      return { ok: false, message: "Aucun compte IA ne correspond au filtre." };
    }

    // Skip the ones that already liked / were liked by the target, and the
    // ones with the same action already waiting for this target.
    const exclude = new Set<string>();
    if (kind === "like") {
      const { data: frs } = await svc
        .from("friendships")
        .select("requester, addressee")
        .or(`requester.eq.${target.id},addressee.eq.${target.id}`)
        .limit(5000);
      for (const f of frs ?? []) {
        exclude.add(f.requester === target.id ? f.addressee : f.requester);
      }
    }
    const { data: waiting } = await svc
      .from("ai_actions")
      .select("ai_id")
      .eq("target_id", target.id)
      .eq("kind", kind)
      .in("status", ["pending", "running"])
      .limit(5000);
    for (const w of waiting ?? []) exclude.add(w.ai_id);

    const chosen = shuffle(pool.map((p) => p.id as string))
      .filter((id) => !exclude.has(id))
      .slice(0, count);
    if (chosen.length === 0) {
      return {
        ok: false,
        message: "Tous les comptes correspondants ont déjà fait cette action.",
      };
    }

    const now = Date.now();
    const rows = chosen.map((aiId) => ({
      ai_id: aiId,
      target_id: target.id,
      kind,
      body: kind === "message" && body ? body : null,
      source: "admin",
      status: "pending",
      run_at: new Date(now + Math.random() * spread * 60_000).toISOString(),
      created_by: userId,
    }));
    const { error: insErr } = await svc.from("ai_actions").insert(rows);
    if (insErr) return { ok: false, message: insErr.message };

    revalidatePath("/agents");
    const short =
      chosen.length < count
        ? ` (${chosen.length} sur ${count} demandés : pas assez de comptes disponibles)`
        : "";
    return {
      ok: true,
      message: `${chosen.length} action(s) planifiée(s) pour ${target.display_name || "cet utilisateur"}${short}.`,
    };
  } catch (e) {
    return { ok: false, message: e instanceof Error ? e.message : "Erreur." };
  }
}

/** Cancel everything still waiting (the kill switch for the manual queue). */
export async function cancelPendingAiActions(
  _prev: QueueState,
  _formData: FormData,
): Promise<QueueState> {
  try {
    const { svc } = await requireAdmin();
    const { data, error } = await svc
      .from("ai_actions")
      .update({
        status: "skipped",
        detail: "cancelled",
        done_at: new Date().toISOString(),
      })
      .eq("status", "pending")
      .select("id");
    if (error) return { ok: false, message: error.message };
    revalidatePath("/agents");
    return { ok: true, message: `${data?.length ?? 0} action(s) annulée(s).` };
  } catch (e) {
    return { ok: false, message: e instanceof Error ? e.message : "Erreur." };
  }
}
