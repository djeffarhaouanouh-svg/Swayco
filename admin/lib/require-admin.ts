import { createSupabaseServerClient } from "@/lib/supabase/server";
import { createSupabaseServiceClient } from "@/lib/supabase/service";

/**
 * Same boundary as the dashboard layout (must be signed in AND
 * `profiles.is_admin`) — a server action is a public POST endpoint, so the
 * layout check alone does not protect it. Returns the service-role client
 * (bypasses RLS) and the admin's user id.
 */
export async function requireAdmin() {
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
