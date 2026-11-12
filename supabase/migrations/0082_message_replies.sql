-- Répondre à un message : un message peut citer un autre message du fil.
-- `on delete set null` : si l'auteur supprime le message cité (« unsend »), la
-- réponse reste et la citation affiche « Message supprimé ».
-- Aucune policy RLS à changer : la colonne suit celles de la table.
alter table public.messages
  add column if not exists reply_to_id uuid
  references public.messages(id) on delete set null;
create index if not exists messages_reply_to_idx on public.messages(reply_to_id);
