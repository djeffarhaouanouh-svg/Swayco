-- Nationalite et origines (mere / pere) du profil. ISO-3166 alpha-2 en
-- minuscules ('fr', 'dz'), '' = non renseigne. Affichees sur la carte
-- "Mes infos" ; a terme, une personne apparait aussi dans le pays de ses
-- origines sur la carte du monde.
alter table public.profiles
  add column if not exists nationality text not null default '',
  add column if not exists origin_mother text not null default '',
  add column if not exists origin_father text not null default '';