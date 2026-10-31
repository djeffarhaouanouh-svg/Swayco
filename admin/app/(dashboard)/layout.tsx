import { redirect } from "next/navigation";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { createSupabaseServiceClient } from "@/lib/supabase/service";
import { TopNav } from "@/components/top-nav";

// Every dashboard page reads live data — never statically cache them.
export const dynamic = "force-dynamic";

/**
 * Access gate for the whole dashboard: must be signed in AND flagged
 * `profiles.is_admin`. Logique d'accès INCHANGÉE — seule la coque change :
 * la barre latérale (Sidebar) devient une barre haute (TopNav).
 */
export default async function DashboardLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  let isAdmin = false;
  try {
    const svc = createSupabaseServiceClient();
    const { data } = await svc
      .from("profiles")
      .select("is_admin")
      .eq("id", user.id)
      .maybeSingle();
    isAdmin = Boolean(data?.is_admin);
  } catch {
    isAdmin = false;
  }
  if (!isAdmin) redirect("/login");

  return (
    <div className="min-h-screen">
      <TopNav adminEmail={user.email ?? ""} />
      {/* flex-col + gap : l'espacement entre le bandeau et les sections
          vient d'ici, les <Section> n'ont plus de marge basse. */}
      <main className="mx-auto flex max-w-[1440px] flex-col gap-9 px-8 pt-7 pb-14">
        {children}
      </main>
    </div>
  );
}
