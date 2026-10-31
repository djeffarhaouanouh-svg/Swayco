"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { CircleAlert } from "lucide-react";
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
    <div className="sc-login-bg flex min-h-screen items-center justify-center px-6">
      <form
        onSubmit={onSubmit}
        className="w-full max-w-[400px] rounded-[28px] border border-sc-line bg-white p-9 shadow-[0_30px_60px_-30px_rgba(4,18,58,.35)]"
      >
        <div className="font-logo text-4xl font-bold tracking-[-0.01em]">
          swayc<span className="text-sc-accent">ø</span>
        </div>
        <p className="mt-1 mb-6 text-sm text-sc-text-muted">
          Tableau de bord admin
        </p>

        <label className="sc-label">E-mail</label>
        <input
          type="email"
          required
          autoComplete="email"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          className="sc-field"
        />

        <label className="sc-label mt-4">Mot de passe</label>
        <input
          type="password"
          required
          autoComplete="current-password"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          className="sc-field"
        />

        {error ? (
          <p
            className="mt-4 flex items-center gap-1.5 text-sm font-bold text-sc-danger"
            role="alert"
          >
            <CircleAlert className="h-[18px] w-[18px]" />
            {error}
          </p>
        ) : null}

        <button
          type="submit"
          disabled={busy}
          className="sc-btn sc-btn-primary mt-6 h-[50px] w-full justify-center text-[15px]"
        >
          {busy ? "Connexion…" : "Se connecter"}
        </button>
      </form>
    </div>
  );
}
