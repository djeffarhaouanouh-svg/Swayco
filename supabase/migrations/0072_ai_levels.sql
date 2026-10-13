-- 0072_ai_levels.sql
--
-- Niveau d'attention des comptes IA (backend/ai_agents.js) : 3 = chaleureuse,
-- 2 = sélective, 1 = distante. Calculé sur les likes reçus (7 et 30 jours), il
-- évolue dans les deux sens : on mémorise ici le niveau COURANT pour que le
-- changement soit durable (hystérésis) et ne oscille pas d'un jour à l'autre.
--
-- Sans cette table le backend fonctionne quand même : le niveau est alors
-- recalculé à chaque fois, sans mémoire (donc sans hystérésis).

create table if not exists public.ai_levels (
  ai_id      uuid primary key references public.profiles (id) on delete cascade,
  level      smallint not null check (level between 1 and 3),
  updated_at timestamptz not null default now()
);

alter table public.ai_levels enable row level security;
-- Aucune policy : table réservée au backend (service role).
