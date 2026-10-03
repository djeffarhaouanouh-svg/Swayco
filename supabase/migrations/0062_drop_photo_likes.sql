-- Retrait des likes de photos (coeurs sur les photos du profil).
-- Le Discover "like" d'une personne passe par `friendships`, pas par `likes`.
-- Ne PAS appliquer avant d'avoir deploye une version de l'app sans LikeApi
-- (les anciennes versions appellent ces fonctions / lisent cette table).

drop function if exists public.received_likes_counts(uuid[]);
drop function if exists public.delete_my_received_likes();
drop function if exists public.delete_my_received_likes_for_photo(text);

alter publication supabase_realtime drop table public.likes;
drop table if exists public.likes;
