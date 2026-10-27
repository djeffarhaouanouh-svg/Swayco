/**
 * Labels shown to the reviewer. Kept out of `actions.ts`: a "use server" file
 * may only export async functions.
 */

/** The gesture the user was asked to make (the key saved with the selfie). */
export const GESTURE_LABELS: Record<string, string> = {
  gesture_thumb_left: "👍 Pouce levé à gauche",
  gesture_peace_right: "✌️ Signe V à droite",
  gesture_hand_chin: "🤔 Main sous le menton",
  gesture_wave: "👋 Salue de la main",
  gesture_point_up: "☝️ Index vers le haut",
  gesture_ok: "👌 Signe OK",
};

/** Refusal reasons: the code is stored in `reject_reason`. */
export const REJECT_REASONS: Record<string, string> = {
  face_hidden: "Visage non visible",
  wrong_gesture: "Geste incorrect",
  no_match: "Ne correspond pas aux photos",
  other: "Autre",
};
