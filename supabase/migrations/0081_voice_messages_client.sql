-- 0081_voice_messages_client.sql
--
-- Les vocaux envoyés depuis le chat par les personnes (micro du composer).
--
--   * messages.audio_url existe depuis 0080 (vocaux des comptes IA) ; on y ajoute
--     la durée, que la bulle affiche sans avoir à ouvrir le fichier
--     (0052 avait retiré audio_duration_ms avec le reste des vocaux « crédits »).
--   * Bucket public `voice-messages` : l'app lit le fichier par son adresse
--     (nom = {auth.uid()}/{horodatage}.m4a, donc non devinable). L'écriture est
--     réservée à l'authentifié, DANS SON PROPRE dossier : on ne dépose rien chez
--     quelqu'un d'autre. Pas de policy select / update / delete (lecture publique
--     par l'adresse ; un vocal se supprime avec le message, côté serveur).
--
-- À appliquer dans l'éditeur SQL de Supabase.

alter table public.messages
  add column if not exists audio_url text not null default '';

alter table public.messages
  add column if not exists audio_duration_ms integer;

-- Le front plafonne à 60 s ; la base tolère un peu plus (dépassement minime).
alter table public.messages
  drop constraint if exists messages_audio_duration_ms_chk;
alter table public.messages
  add constraint messages_audio_duration_ms_chk
    check (
      audio_duration_ms is null
      or (audio_duration_ms > 0 and audio_duration_ms <= 120000)
    );

-- 60 s en AAC 64 kbit/s font ~480 Ko : 2 Mo laissent de la marge.
insert into storage.buckets (id, name, public, file_size_limit)
values ('voice-messages', 'voice-messages', true, 2097152)
on conflict (id) do update set public = true, file_size_limit = 2097152;

drop policy if exists "voice messages own insert" on storage.objects;
create policy "voice messages own insert"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'voice-messages'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
