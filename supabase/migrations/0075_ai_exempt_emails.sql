-- Emails « protégés » : un compte dont l'email est dans cette liste n'est JAMAIS
-- contacté par une IA : ni like, ni message, ni réponse, ni acceptation
-- automatique, ni like d'accueil. Pensé pour les proches (« ma mère télécharge
-- l'app : qu'aucune IA ne la dérange »).
--
-- L'email peut être ajouté AVANT que la personne crée son compte : le backend
-- compare à profiles.email (copie de auth.users.email, voir 0004), donc la
-- protection s'applique dès l'inscription.
--
-- Table réservée au backend et à l'admin (service role) : RLS activée, aucune
-- policy, donc invisible et inmodifiable depuis l'app.
--
-- À appliquer dans l'éditeur SQL de Supabase. Ajout / retrait : page « Comptes
-- IA » de l'admin, section « Protégés ».

create table if not exists public.ai_exempt_emails (
  email      text        primary key
             check (email = lower(btrim(email)) and position('@' in email) > 1),
  note       text,
  created_at timestamptz not null default now()
);

alter table public.ai_exempt_emails enable row level security;
