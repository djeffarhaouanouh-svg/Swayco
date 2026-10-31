"use client";

import { useActionState, useState } from "react";
import { CheckCircle2, SendHorizontal } from "lucide-react";
import { Card } from "@/components/ui/card";
import {
  cancelPendingAiActions,
  queueAiActions,
  type QueueState,
} from "./actions";

function Result({ state }: { state: QueueState }) {
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
    <Card className="p-6">
      <form action={action}>
        <div className="grid gap-x-[18px] gap-y-4 md:grid-cols-2">
          <div>
            <label className="sc-label" htmlFor="kind">
              Action
            </label>
            <select
              id="kind"
              name="kind"
              className="sc-field"
              value={kind}
              onChange={(e) => setKind(e.target.value)}
            >
              <option value="like">Liker (ajout / match)</option>
              <option value="message">Écrire un message</option>
            </select>
          </div>
          <div>
            <label className="sc-label" htmlFor="target">
              Cible (id ou @handle)
            </label>
            <input
              id="target"
              name="target"
              className="sc-field"
              placeholder="@pseudo ou 0b9c…"
              required
            />
          </div>
          <div>
            <label className="sc-label" htmlFor="country">
              Pays des comptes IA
            </label>
            <select id="country" name="country" className="sc-field" defaultValue="">
              <option value="">Tous les pays</option>
              {countries.map((c) => (
                <option key={c.name} value={c.name}>
                  {c.name} ({c.count})
                </option>
              ))}
            </select>
          </div>
          <div>
            <label className="sc-label" htmlFor="gender">
              Genre des comptes IA
            </label>
            <select id="gender" name="gender" className="sc-field" defaultValue="">
              <option value="">Tous</option>
              <option value="f">Femmes</option>
              <option value="m">Hommes</option>
            </select>
          </div>
          <div>
            <label className="sc-label" htmlFor="count">
              Combien de comptes
            </label>
            <input
              id="count"
              name="count"
              type="number"
              min={1}
              max={200}
              defaultValue={2}
              className="sc-field"
              required
            />
          </div>
          <div>
            <label className="sc-label" htmlFor="spread">
              Étalé sur (minutes, 0 = tout de suite)
            </label>
            <input
              id="spread"
              name="spread"
              type="number"
              min={0}
              max={720}
              defaultValue={60}
              className="sc-field"
            />
          </div>
        </div>

        {kind === "message" ? (
          <div className="mt-4">
            <label className="sc-label" htmlFor="body">
              Texte du message (obligatoire : l&apos;IA n&apos;écrit jamais seule le premier message)
            </label>
            <textarea
              id="body"
              name="body"
              rows={3}
              maxLength={500}
              required
              className="sc-field"
            />
          </div>
        ) : null}

        <div className="mt-5 flex flex-wrap items-center gap-3">
          <button type="submit" disabled={pending} className="sc-btn sc-btn-primary">
            <SendHorizontal className="h-[17px] w-[17px]" />
            {pending ? "Planification…" : "Planifier"}
          </button>
          <Result state={state} />
        </div>
      </form>

      <form action={cancelAction} className="mt-4 flex flex-wrap items-center gap-3">
        <button type="submit" disabled={cancelling} className="sc-btn sc-btn-outline">
          Annuler toutes les actions en attente
        </button>
        <Result state={cancelState} />
      </form>
    </Card>
  );
}
