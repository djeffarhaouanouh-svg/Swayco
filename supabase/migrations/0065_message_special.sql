-- Message special (Discover, bouton dore) : marque la ligne cote serveur pour
-- que le destinataire sache que c'en est un (carte speciale + Accepter/Refuser).
alter table public.messages
  add column if not exists special boolean not null default false;
