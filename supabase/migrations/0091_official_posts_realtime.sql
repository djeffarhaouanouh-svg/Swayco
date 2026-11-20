-- 0091_official_posts_realtime.sql
--
-- Les annonces de l'équipe Swayco arrivent en direct dans l'app (pastille +
-- liste Messages), sans attendre le prochain lancement.
do $$
begin
  alter publication supabase_realtime add table public.official_posts;
exception when duplicate_object then null;
end$$;
