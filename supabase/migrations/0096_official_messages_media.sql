-- 0096_official_messages_media.sql
--
-- Photos et vidéos vers la team Swayco (pas de GIF) : une colonne `media_url`.
-- Un message peut maintenant n'avoir QUE un média (corps vide). Ils comptent dans
-- la limite de 3 par jour (0095) : même table, même déclencheur.

alter table public.official_messages
  add column if not exists media_url text not null default '';

alter table public.official_messages
  drop constraint if exists official_messages_body_check;

alter table public.official_messages
  add constraint official_messages_body_check
  check (
    char_length(body) <= 4000
    and (char_length(body) >= 1 or char_length(media_url) > 0)
  );