"use server";

// Messages vocaux des IA, faits à la main (migration 0080). L'admin génère la voix
// sur le site d'ElevenLabs (aucune API), envoie le fichier ici ; le backend
// (backend/ai_agents.js, processVoiceReady) fait ensuite envoyer le message par l'IA.

import { revalidatePath } from "next/cache";
import { requireAdmin } from "@/lib/require-admin";

export type VoiceState = { ok: boolean; message: string } | null;

const UUID = /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
const BUCKET = "ai-voice-notes";
const MAX_BYTES = 5 * 1024 * 1024; // même plafond que le bucket
// Formats lisibles par un iPhone ET un Android (pas d'ogg ni de webm).
const TYPES: Record<string, string> = {
  mp3: "audio/mpeg",
  m4a: "audio/mp4",
  aac: "audio/aac",
  wav: "audio/wav",
};

type Svc = Awaited<ReturnType<typeof requireAdmin>>["svc"];

/** Compte retrouvé par identifiant, email ou pseudo (handle). */
async function findProfile(svc: Svc, rawInput: string) {
  const raw = rawInput.trim().replace(/^@/, "");
  if (!raw) return null;
  const q = svc.from("profiles").select("id, handle, display_name, is_ai");
  const { data } = await (UUID.test(raw)
    ? q.eq("id", raw)
    : raw.includes("@")
      ? q.ilike("email", raw.replace(/[\\%_]/g, (c) => `\\${c}`))
      : q.eq("handle", raw)
  ).limit(1);
  return data?.[0] ?? null;
}

/** Même identifiant de conversation que le backend (convIdFor) et l'app. */
function convId(a: string, b: string): string {
  const [x, y] = [String(a), String(b)].sort();
  return `dm-${x}-${y}`;
}

/**
 * L'audio est généré : on l'envoie. Le fichier part dans le bucket, la demande
 * passe à « prête », et le backend l'envoie dans le chat au tour suivant (≤ 15 s).
 */
export async function submitVoice(
  _prev: VoiceState,
  formData: FormData,
): Promise<VoiceState> {
  try {
    const { svc } = await requireAdmin();
    const id = String(formData.get("id") ?? "");
    const text = String(formData.get("text") ?? "").trim().slice(0, 600);
    const file = formData.get("file");
    if (!UUID.test(id)) return { ok: false, message: "Demande inconnue." };
    if (!text) return { ok: false, message: "Le texte ne peut pas être vide." };
    if (!(file instanceof File) || file.size === 0) {
      return { ok: false, message: "Choisis un fichier audio." };
    }
    if (file.size > MAX_BYTES) {
      return { ok: false, message: "Fichier trop lourd (5 Mo maximum)." };
    }
    const ext = (file.name.split(".").pop() ?? "").toLowerCase();
    if (!TYPES[ext]) {
      return { ok: false, message: "Format non accepté : mp3, m4a, aac ou wav." };
    }

    const { data: req } = await svc
      .from("ai_voice_requests")
      .select("id, conversation_id, status")
      .eq("id", id)
      .maybeSingle();
    if (!req) return { ok: false, message: "Demande introuvable." };
    if (req.status !== "pending") {
      return { ok: false, message: "Cette demande n'est plus en attente." };
    }

    const path = `${req.conversation_id}/${id}.${ext}`;
    const { error: upErr } = await svc.storage
      .from(BUCKET)
      .upload(path, Buffer.from(await file.arrayBuffer()), {
        contentType: TYPES[ext],
        upsert: true,
      });
    if (upErr) return { ok: false, message: `Envoi du fichier refusé : ${upErr.message}` };

    const { error } = await svc
      .from("ai_voice_requests")
      .update({
        status: "ready",
        text,
        audio_path: path,
        ready_at: new Date().toISOString(),
        attempts: 0,
        detail: null,
      })
      .eq("id", id)
      .eq("status", "pending");
    if (error) return { ok: false, message: error.message };

    revalidatePath("/audios");
    return { ok: true, message: "Audio envoyé : l'IA le poste dans le chat dans quelques secondes." };
  } catch (e) {
    return { ok: false, message: e instanceof Error ? e.message : "Erreur." };
  }
}

/** Annule une demande (en attente, ou prête mais pas encore envoyée). */
export async function cancelVoice(formData: FormData): Promise<void> {
  const { svc } = await requireAdmin();
  const id = String(formData.get("id") ?? "");
  if (!UUID.test(id)) return;
  await svc
    .from("ai_voice_requests")
    .update({ status: "cancelled", detail: "annulé par l'admin" })
    .eq("id", id)
    .in("status", ["pending", "ready"]);
  revalidatePath("/audios");
}

/** Demande faite à la main : « cette IA, dis ceci à cette personne ». */
export async function createVoiceRequest(
  _prev: VoiceState,
  formData: FormData,
): Promise<VoiceState> {
  try {
    const { svc } = await requireAdmin();
    const text = String(formData.get("text") ?? "").trim().slice(0, 600);
    if (!text) return { ok: false, message: "Écris ce que l'IA dit." };
    const ai = await findProfile(svc, String(formData.get("ai") ?? ""));
    const target = await findProfile(svc, String(formData.get("target") ?? ""));
    if (!ai) return { ok: false, message: "Compte IA introuvable." };
    if (!ai.is_ai) return { ok: false, message: "Ce premier compte n'est pas une IA." };
    if (!target) return { ok: false, message: "Destinataire introuvable." };
    if (target.is_ai) return { ok: false, message: "Le destinataire doit être un vrai compte." };

    const { error } = await svc.from("ai_voice_requests").insert({
      ai_id: ai.id,
      target_id: target.id,
      conversation_id: convId(ai.id, target.id),
      text,
      source: "admin",
    });
    if (error) return { ok: false, message: error.message };
    revalidatePath("/audios");
    return { ok: true, message: "Demande ajoutée à la liste « À générer »." };
  } catch (e) {
    return { ok: false, message: e instanceof Error ? e.message : "Erreur." };
  }
}

/**
 * Choisit la voix d'une IA, d'un groupe (pays + genre) ou par défaut. Les deux
 * champs vides = on retire la voix. Plusieurs IA peuvent partager la même.
 */
export async function saveVoice(formData: FormData): Promise<void> {
  const { svc } = await requireAdmin();
  let scope = String(formData.get("scope") ?? "").trim();
  const who = String(formData.get("who") ?? "").trim();
  if (scope === "ai") {
    const p = await findProfile(svc, who);
    if (!p || !p.is_ai) return;
    scope = `ai:${p.id}`;
  }
  const valid =
    scope === "default" ||
    /^group:[^|]{1,60}\|[a-z]{0,3}$/.test(scope) ||
    /^ai:[0-9a-f-]{36}$/i.test(scope);
  if (!valid) return;

  const voiceId = String(formData.get("voice_id") ?? "").trim().slice(0, 64);
  const label = String(formData.get("label") ?? "").trim().slice(0, 80);
  if (voiceId && !/^[A-Za-z0-9_-]+$/.test(voiceId)) return;
  if (!voiceId && !label) {
    await svc.from("ai_voices").delete().eq("scope", scope);
  } else {
    await svc
      .from("ai_voices")
      .upsert(
        { scope, voice_id: voiceId, label, updated_at: new Date().toISOString() },
        { onConflict: "scope" },
      );
  }
  revalidatePath("/audios");
}

export async function removeVoice(formData: FormData): Promise<void> {
  const { svc } = await requireAdmin();
  const scope = String(formData.get("scope") ?? "").trim();
  if (!scope) return;
  await svc.from("ai_voices").delete().eq("scope", scope);
  revalidatePath("/audios");
}
