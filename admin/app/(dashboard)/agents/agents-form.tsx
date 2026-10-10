"use client";

import { useActionState, useState } from "react";
import {
  cancelPendingAiActions,
  queueAiActions,
  type QueueState,
} from "./actions";

const field =
  "w-full rounded-xl border border-white/10 bg-white/5 px-3 py-2 text-sm text-sc-text outline-none focus:border-sc-accent/50";
const label = "mb-1 block text-xs font-medium text-sc-text-muted";

function Result({ state }: { state: QueueState }) {
  if (!state) return null;
  return (
    <p
      className={`mt-3 text-sm ${state.ok ? "text-sc-accent" : "text-red-400"}`}
    >
      {state.message}
    </p>
  );
}

export function AgentsForm({
  countries,
}: {
  countries: { name: string; count: number }[];
}) {
  const [state, action, pending] = useActionState<QueueState, FormData>(
    queueAiActions,
    null,
  );
  const [cancelState, cancelAction, cancelling] = useActionState<
    QueueState,
    FormData
  >(cancelPendingAiActions, null);
  const [kind, setKind] = useState("like");

  return (
    <div className="space-y-6">
      <form
        action={action}
        className="rounded-2xl border border-white/10 bg-white/[0.03] p-5"
      >
        <div className="grid gap-4 md:grid-cols-2">
          <div>
            <label className={label} htmlFor="kind">
              Action
            </label>
            <select
              id="kind"
              name="kind"
              className={field}
              value={kind}
              onChange={(e) => setKind(e.target.value)}
            >
              <option value="like">Liker (ajout / match)</option>
              <option value="message">Écrire un message</option>
            </select>
          </div>
          <div>
            <label className={label} htmlFor="target">
              Cible (id ou @handle)
            </label>
            <input
              id="target"
              name="target"
              className={field}
              placeholder="@pseudo ou 0b9c…"
              required
            />
          </div>
          <div>
            <label className={label} htmlFor="country">
              Pays des comptes IA
            </label>
            <select id="country" name="country" className={field} defaultValue="">
              <option value="">Tous les pays</option>
              {countries.map((c) => (
                <option key={c.name} value={c.name}>
                  {c.name} ({c.count})
                </option>
              ))}
            </select>
          </div>
          <div>
            <label className={label} htmlFor="gender">
              Genre des comptes IA
            </label>
            <select id="gender" name="gender" className={field} defaultValue="">
              <option value="">Tous</option>
              <option value="f">Femmes</option>
              <option value="m">Hommes</option>
            </select>
          </div>
          <div>
            <label className={label} htmlFor="count">
              Combien de comptes
            </label>
            <input
              id="count"
              name="count"
              type="number"
              min={1}
              max={200}
              defaultValue={2}
              className={field}
              required
            />
          </div>
          <div>
            <label className={label} htmlFor="spread">
              Étalé sur (minutes, 0 = tout de suite)
            </label>
            <input
              id="spread"
              name="spread"
              type="number"
              min={0}
              max={720}
              defaultValue={60}
              className={field}
            />
          </div>
        </div>

        {kind === "message" ? (
          <div className="mt-4">
            <label className={label} htmlFor="body">
              Texte du message (laisse vide : chaque compte écrit le sien)
            </label>
            <textarea
              id="body"
              name="body"
              rows={3}
              maxLength={500}
              className={field}
            />
          </div>
        ) : null}

        <div className="mt-5 flex items-center gap-3">
          <button
            type="submit"
            disabled={pending}
            className="rounded-xl bg-sc-accent/20 px-4 py-2 text-sm font-medium text-sc-accent transition-colors hover:bg-sc-accent/30 disabled:opacity-50"
          >
            {pending ? "Planification…" : "Planifier"}
          </button>
        </div>
        <Result state={state} />
      </form>

      <form action={cancelAction} className="flex items-center gap-3">
        <button
          type="submit"
          disabled={cancelling}
          className="rounded-xl border border-white/10 px-4 py-2 text-sm text-sc-text-secondary transition-colors hover:bg-white/5 disabled:opacity-50"
        >
          Annuler toutes les actions en attente
        </button>
        <Result state={cancelState} />
      </form>
    </div>
  );
}
