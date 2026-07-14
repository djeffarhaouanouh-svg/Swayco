-- The Discover card now pulls up an info panel: bio first, then the facts a
-- person chooses to share. Everything is optional and free-form — an empty
-- column simply doesn't render a row.
--
--   age         : years, entered by the user (no birth date stored → nothing
--                 to recompute, and no exact-birthday PII).
--   height_cm   : centimetres.
--   job         : what they do ("Architecte", "Étudiante en droit"…).
--   zodiac      : star sign, stored as the user typed / picked it.
--   looking_for : what they're here for ("Une relation", "Des amis"…).
alter table public.profiles
  add column if not exists age int,
  add column if not exists height_cm int,
  add column if not exists job text,
  add column if not exists zodiac text,
  add column if not exists looking_for text;

-- Guard rails so a tampered client can't store nonsense.
do $$
begin
  alter table public.profiles
    add constraint profiles_age_range check (age is null or (age >= 18 and age <= 120));
exception when duplicate_object then null;
end $$;

do $$
begin
  alter table public.profiles
    add constraint profiles_height_range
    check (height_cm is null or (height_cm >= 100 and height_cm <= 250));
exception when duplicate_object then null;
end $$;
