-- 0087_official_posts_media.sql
--
-- Un message du compte officiel peut porter un EXEMPLE sous son texte : un GIF,
-- une image ou une courte vidéo (URL). Vide = message sans exemple.
alter table public.official_posts
  add column if not exists media_url text not null default '';
