-- Age picker offers 15–40. Lower the DB floor from 18 → 15 so a 15–17
-- selection isn't rejected. Keep the high ceiling for any legacy rows above 40.
alter table public.profiles
  drop constraint if exists profiles_age_range;

alter table public.profiles
  add constraint profiles_age_range
  check (age is null or (age >= 15 and age <= 120));
