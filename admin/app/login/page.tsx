"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";

/**
 * Sign-in for the dashboard. Supabase Auth against the same project as
 * the app; the `is_admin` gate itself lives server-side in
 * app/(dashboard)/layout.tsx — this page only refuses early so a
 * non-admin gets a message instead of a redirect loop.
 */
export default function LoginPage() {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    const sb = createSupabaseBrowserClient();

    const { data, error: signInError } = await sb.auth.signInWithPassword({
      email: email.trim(),
      password,
    });
    if (signInError || !data.user) {
      setError("Identifiants incorrects.");
      setBusy(false);
      return;
    }

    // The anon key can read profiles (public select policy), so the
    // non-admin case is caught here rather than after a redirect.
    const { data: profile } = await sb
      .from("profiles")
      .select("is_admin")
      .eq("id", data.user.id)
      .maybeSingle();

    if (!profile?.is_admin) {
      await sb.auth.signOut();
      setError("Ce compte n'a pas accès à l'administration.");
      setBusy(false);
      return;
    }

    router.replace("/");
    router.refresh();
  }

  return (
    <div className="flex min-h-screen items-center justify-center px-6">
      <form
        onSubmit={onSubmit}
        className="sc-glass w-full max-w-sm rounded-2xl p-7"
      >
        <div className="font-display text-2xl font-bold tracking-tight text-sc-text">
          swaycø
        </div>
        <p className="mt-1 mb-6 text-sm text-sc-text-muted">
          Tableau de bord admin
        </p>

        <label className="block text-xs font-semibold text-sc-text-secondary">
          E-mail
          <input
            type="email"
            required
            autoComplete="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            className="mt-1.5 w-full rounded-xl border border-white/10 bg-sc-menu px-3 py-2.5 text-sm font-normal text-sc-text outline-none transition-colors focus:border-sc-accent"
          />
        </label>

        <label className="mt-4 block text-xs font-semibold text-sc-text-secondary">
          Mot de passe
          <input
            type="password"
            required
            autoComplete="current-password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            className="mt-1.5 w-full rounded-xl border border-white/10 bg-sc-menu px-3 py-2.5 text-sm font-normal text-sc-text outline-none transition-colors focus:border-sc-accent"
          />
        </label>

        {error ? (
          <p className="mt-4 text-sm text-red-400" role="alert">
            {error}
          </p>
        ) : null}

        <button
          type="submit"
          disabled={busy}
          className="mt-6 w-full rounded-xl bg-sc-accent py-3 text-sm font-bold text-sc-bg-deep transition-opacity hover:opacity-90 disabled:opacity-50"
        >
          {busy ? "Connexion…" : "Se connecter"}
        </button>
      </form>
    </div>
  );
}
