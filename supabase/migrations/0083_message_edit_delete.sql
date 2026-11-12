-- Modifier un message, et laisser une trace quand on en supprime un.
--  * edited_at  : quand l'auteur a modifié le texte (« ✎ modifié »).
--  * deleted_at : suppression DOUCE. Le contenu est effacé par l'app (body,
--    image_url, audio_url, discover_photo vidés), la ligne reste pour que les
--    deux côtés voient « message supprimé ». Le flux temps réel émet les UPDATE,
--    ce qui est plus fiable qu'un DELETE pour que l'autre côté voie la trace.
alter table public.messages
  add column if not exists edited_at  timestamptz,
  add column if not exists deleted_at timestamptz;

-- Un utilisateur ne peut modifier que ses propres messages.
-- Comme la policy DELETE de 0020 : on N'ACTIVE PAS « row level security » ici
-- (si elle est coupée aujourd'hui, l'activer bloquerait la lecture et l'envoi).
drop policy if exists "messages_update_own" on public.messages;
create policy "messages_update_own"
  on public.messages
  for update
  using ( sender = auth.uid() )
  with check ( sender = auth.uid() );
