-- 0054_conversation_reads.sql
--
-- Où chacun en est de sa lecture, PARTAGÉ.
--
-- L'état de lecture vivait entièrement dans les SharedPreferences de chaque
-- téléphone : parfait pour éteindre ses propres badges, inutilisable pour
-- afficher un « Lu », qui demande de savoir où en est l'AUTRE. Une ligne par
-- (conversation, personne), relevée quand le fil est sous les yeux.
--
-- `conversation_id` est du texte et pas une clé étrangère : les conversations
-- n'ont pas de table, leur identifiant est dérivé des deux identifiants
-- (`dm-<a>-<b>`, voir _conversationIdFor côté client).
--
-- Idempotent : sûr à rejouer sur un environnement où une partie existe déjà.

create table if not exists public.conversation_reads (
  conversation_id text        not null,
  user_id         uuid        not null references auth.users(id) on delete cascade,
  last_read_at    timestamptz not null default now(),
  primary key (conversation_id, user_id)
);

-- La seule lecture faite est « la ligne du pair dans CE fil ».
create index if not exists conversation_reads_conv_idx
  on public.conversation_reads (conversation_id);

alter table public.conversation_reads enable row level security;

-- Lecture ouverte aux comptes connectés : le sens même de la table est que le
-- correspondant voie ma ligne. Elle ne contient qu'un horodatage — pas de
-- contenu de message, rien qu'on ne puisse déjà déduire d'un accusé affiché.
drop policy if exists "reads_select_authenticated" on public.conversation_reads;
create policy "reads_select_authenticated"
  on public.conversation_reads
  for select
  to authenticated
  using (true);

-- Écriture : sa PROPRE ligne, et elle seule. Sans ça n'importe qui pourrait
-- déclarer avoir lu à la place d'un autre, ou pire, antidater sa lecture.
drop policy if exists "reads_insert_own" on public.conversation_reads;
create policy "reads_insert_own"
  on public.conversation_reads
  for insert
  to authenticated
  with check (auth.uid() = user_id);

drop policy if exists "reads_update_own" on public.conversation_reads;
create policy "reads_update_own"
  on public.conversation_reads
  for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- Publication realtime — c'est elle qui fait apparaître le « Lu » chez
-- l'expéditeur à la seconde où l'autre ouvre le fil, sans rien interroger.
do $$
begin
  alter publication supabase_realtime add table public.conversation_reads;
exception
  when duplicate_object then null;
end$$;
