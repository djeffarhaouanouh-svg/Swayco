"use client";

import { useActionState } from "react";
import { CheckCircle2, Send, Upload } from "lucide-react";
import {
  cancelVoice,
  createVoiceRequest,
  submitVoice,
  type VoiceState,
} from "./actions";

function Result({ state }: { state: VoiceState }) {
  if (!state) return null;
  return state.ok ? (
    <p className="flex items-center gap-1.5 text-sm font-bold text-sc-accent">
      <CheckCircle2 className="h-[18px] w-[18px]" />
      {state.message}
    </p>
  ) : (
    <p className="text-sm font-bold text-sc-danger">{state.message}</p>
  );
}

/** Une demande « à générer » : le texte (modifiable), le fichier audio, Envoyer / Annuler. */
export function VoiceUploadForm({ id, text }: { id: string; text: string }) {
  const [state, action, pending] = useActionState<VoiceState, FormData>(
    submitVoice,
    null,
  );
  return (
    <div className="flex flex-col gap-3">
      <form action={action} className="flex flex-col gap-3">
        <input type="hidden" name="id" value={id} />
        <div>
          <label className="sc-label" htmlFor={`text-${id}`}>
            Ce que l&apos;IA dit (modifie si tu changes les mots)
          </label>
          <textarea
            id={`text-${id}`}
            name="text"
            rows={3}
            maxLength={600}
            required
            defaultValue={text}
            className="sc-field"
          />
        </div>
        <div>
          <label className="sc-label" htmlFor={`file-${id}`}>
            Fichier audio (mp3, m4a, aac ou wav, 5 Mo maximum)
          </label>
          <input
            id={`file-${id}`}
            name="file"
            type="file"
            accept=".mp3,.m4a,.aac,.wav,audio/mpeg,audio/mp4,audio/aac,audio/wav"
            required
            className="sc-field"
          />
        </div>
        <div className="flex flex-wrap items-center gap-3">
          <button type="submit" disabled={pending} className="sc-btn sc-btn-primary">
            <Upload className="h-[17px] w-[17px]" />
            {pending ? "Envoi…" : "Envoyer l'audio"}
          </button>
          <Result state={state} />
        </div>
      </form>
      <form action={cancelVoice}>
        <input type="hidden" name="id" value={id} />
        <button type="submit" className="text-[13px] font-bold text-sc-danger hover:underline">
          Annuler cette demande
        </button>
      </form>
    </div>
  );
}

/** Demande faite à la main : une IA, une personne, ce que l'IA dit. */
export function CreateVoiceForm() {
  const [state, action, pending] = useActionState<VoiceState, FormData>(
    createVoiceRequest,
    null,
  );
  return (
    <form action={action} className="flex flex-col gap-4">
      <div className="grid gap-x-[18px] gap-y-4 md:grid-cols-2">
        <div>
          <label className="sc-label" htmlFor="v-ai">
            Compte IA (pseudo, email ou identifiant)
          </label>
          <input id="v-ai" name="ai" required className="sc-field" placeholder="@pseudo" />
        </div>
        <div>
          <label className="sc-label" htmlFor="v-target">
            Pour qui (pseudo, email ou identifiant)
          </label>
          <input id="v-target" name="target" required className="sc-field" placeholder="@pseudo" />
        </div>
      </div>
      <div>
        <label className="sc-label" htmlFor="v-text">
          Ce que l&apos;IA dit
        </label>
        <textarea id="v-text" name="text" rows={3} maxLength={600} required className="sc-field" />
      </div>
      <div className="flex flex-wrap items-center gap-3">
        <button type="submit" disabled={pending} className="sc-btn sc-btn-outline">
          <Send className="h-[17px] w-[17px]" />
          {pending ? "Ajout…" : "Ajouter à la liste"}
        </button>
        <Result state={state} />
      </div>
    </form>
  );
}
