// Seed test Discover profiles from local photo folders.
//
//   node admin/scripts/seed_test_profiles.mjs          # create
//   node admin/scripts/seed_test_profiles.mjs --delete # remove every seed_* account + photos
//
// Photos: <Downloads>/homme/*.jpg -> gender 'm' , <Downloads>/femme/*.jpg -> gender 'f'
// 18 photos -> 9 France (fr) + 9 Allemagne (de), genders balanced.
// Ages 18-25 (the live `profiles_age_range` check still rejects < 18 — migration
// 0048 has not been applied; widen with a re-run once it is).
//
// The live `profiles.id` has an FK to auth.users, so each profile is backed by
// a real (email-confirmed, password-random) auth user: seed+<id>@swayco.test.
//
// Uses SUPABASE_SERVICE_ROLE_KEY (bypasses RLS, admin API) from admin/.env.local.

import { createClient } from '@supabase/supabase-js';
import { readFileSync, readdirSync } from 'node:fs';
import { resolve, extname, join } from 'node:path';
import { randomUUID } from 'node:crypto';

// ── env ─────────────────────────────────────────────────────────────────────
const envPath = resolve(import.meta.dirname, '..', '.env.local');
const env = Object.fromEntries(
  readFileSync(envPath, 'utf8')
    .split('\n')
    .map((l) => l.trim())
    .filter((l) => l && !l.startsWith('#') && l.includes('='))
    .map((l) => {
      const i = l.indexOf('=');
      return [l.slice(0, i).trim(), l.slice(i + 1).trim()];
    }),
);
const URL = env.NEXT_PUBLIC_SUPABASE_URL;
const KEY = env.SUPABASE_SERVICE_ROLE_KEY;
if (!URL || !KEY) throw new Error('Missing Supabase URL / service-role key in admin/.env.local');

const db = createClient(URL, KEY, { auth: { persistSession: false } });
const BUCKET = 'avatars';

// ── delete mode ────────────────────────────────────────────────────────────
if (process.argv.includes('--delete')) {
  const { data: rows, error } = await db
    .from('profiles')
    .select('id')
    .like('handle', 'seed\\_%');
  if (error) throw error;
  console.log(`deleting ${rows.length} seed profiles + auth users…`);
  for (const { id } of rows) {
    await db.from('profiles').delete().eq('id', id);
    await db.auth.admin.deleteUser(id).catch(() => {});
  }
  // Wipe the whole seed/ photo prefix (also clears orphans from failed runs).
  const { data: dirs } = await db.storage.from(BUCKET).list('seed');
  for (const d of dirs ?? []) {
    const { data: files } = await db.storage.from(BUCKET).list(`seed/${d.name}`);
    if (files?.length) {
      await db.storage.from(BUCKET).remove(files.map((f) => `seed/${d.name}/${f.name}`));
    }
  }
  console.log('done.');
  process.exit(0);
}

// ── photo folders ─────────────────────────────────────────────────────────
const DL = resolve(import.meta.dirname, '..', '..', '..'); // .../Downloads
const pick = (dir, gender) =>
  readdirSync(join(DL, dir))
    .filter((f) => f.toLowerCase().endsWith('.jpg'))
    .sort()
    .map((f) => ({ file: join(DL, dir, f), gender }));

const men = pick('homme', 'm');
const women = pick('femme', 'f');
if (!men.length || !women.length) throw new Error('No photos in Downloads/homme or Downloads/femme');

// Interleave m/f, then first half -> France, second half -> Allemagne.
const photos = [];
for (let i = 0; i < Math.max(men.length, women.length); i++) {
  if (men[i]) photos.push(men[i]);
  if (women[i]) photos.push(women[i]);
}
const half = Math.ceil(photos.length / 2);

// ── vocab ────────────────────────────────────────────────────────────────
const rnd = (a) => a[Math.floor(Math.random() * a.length)];
const sample = (a, n) => {
  const c = [...a];
  const out = [];
  while (out.length < n && c.length) out.push(c.splice(Math.floor(Math.random() * c.length), 1)[0]);
  return out;
};
const age = () => 18 + Math.floor(Math.random() * 8); // 18..25 (live DB floor)

const NAMES = {
  fr: {
    m: ['Lucas', 'Hugo', 'Nathan', 'Léo', 'Enzo', 'Théo', 'Noah', 'Gabriel', 'Raphaël'],
    f: ['Camille', 'Léa', 'Manon', 'Chloé', 'Inès', 'Jade', 'Louane', 'Sarah', 'Emma'],
  },
  de: {
    m: ['Ben', 'Paul', 'Jonas', 'Luca', 'Finn', 'Elias', 'Jan', 'Felix', 'Maximilian'],
    f: ['Mia', 'Hannah', 'Emilia', 'Lina', 'Lena', 'Marie', 'Sophie', 'Clara', 'Leonie'],
  },
};
const CITIES = {
  fr: ['Paris', 'Lyon', 'Marseille', 'Toulouse', 'Bordeaux', 'Lille', 'Nantes', 'Nice', 'Strasbourg'],
  de: ['Berlin', 'Munich', 'Hambourg', 'Cologne', 'Francfort', 'Stuttgart', 'Düsseldorf', 'Leipzig', 'Brême'],
};
const COUNTRY = { fr: 'France', de: 'Allemagne' };
const JOBS = ['Étudiant', 'Tech', 'Sport & Divertissement', 'Art & Création', 'Commerce', 'Restauration', 'Médical', 'Ingénierie', 'Droit & Finance', 'Éducation', 'Service public'];
const LOOKING = ['Amitié', 'Pratiquer une langue', 'Faire des activités ensemble', 'Trouver des gamers', 'Du fun', 'Networking', 'Voyager / rencontrer des locaux', 'Une relation'];
const ZODIAC = ['Bélier', 'Taureau', 'Gémeaux', 'Cancer', 'Lion', 'Vierge', 'Balance', 'Scorpion', 'Sagittaire', 'Capricorne', 'Verseau', 'Poissons'];
const PERSONA = {
  Sportif: { fr: 'Sport presque tous les jours', de: 'Fast jeden Tag Sport' },
  Gamer: { fr: 'Manette jamais très loin', de: 'Controller nie weit weg' },
  Mélomane: { fr: 'Toujours un son dans les oreilles', de: 'Immer Musik im Ohr' },
  Voyageur: { fr: 'Un pied dans l’avion', de: 'Ständig unterwegs' },
  Cinéphile: { fr: 'Cinéma et séries à gogo', de: 'Kino und Serien ohne Ende' },
  Gourmet: { fr: 'Je vis pour bien manger', de: 'Ich lebe fürs gute Essen' },
  Fitness: { fr: 'Salle et nutrition', de: 'Gym und Ernährung' },
  Créatif: { fr: 'Je crée un truc par jour', de: 'Jeden Tag etwas Neues bauen' },
  Fashion: { fr: 'Le fit avant tout', de: 'Outfit geht vor' },
  Curieux: { fr: 'Je lis sur un peu tout', de: 'Lese über alles Mögliche' },
  Tech: { fr: 'Geek assumé', de: 'Bekennender Nerd' },
  Nature: { fr: 'Rando dès que possible', de: 'Wandern, wann immer es geht' },
  Fêtard: { fr: 'Toujours partant pour sortir', de: 'Immer für eine Party zu haben' },
};
const INTERESTS = ['Football', 'Basketball', 'Tennis', 'Musculation', 'Rap', 'K-pop', 'Rock', 'Anime', 'Cinéma', 'Séries', 'Cuisine', 'Sushi', 'Café', 'Voyage', 'Randonnée', 'Gaming', 'PlayStation', 'Nintendo', 'Mode', 'Photographie', 'Musique'];
const BIO_TAIL = { fr: 'Toujours partant·e pour discuter.', de: 'Immer für einen Chat zu haben.' };

// ── run ──────────────────────────────────────────────────────────────────
let ok = 0;
for (let i = 0; i < photos.length; i++) {
  const { file, gender } = photos[i];
  const lang = i < half ? 'fr' : 'de';

  // 1. auth user (profiles.id -> auth.users FK)
  const cu = await db.auth.admin.createUser({
    email: `seed+${randomUUID().slice(0, 12)}@swayco.test`,
    password: randomUUID(),
    email_confirm: true,
    user_metadata: { seed: true },
  });
  if (cu.error) {
    console.error(`✗ auth user (${lang}/${gender}):`, cu.error.message);
    continue;
  }
  const id = cu.data.user.id;

  // 2. photo -> avatars bucket
  const ext = extname(file).toLowerCase() || '.jpg';
  const key = `seed/${id}/pdp${ext}`;
  const up = await db.storage
    .from(BUCKET)
    .upload(key, readFileSync(file), { contentType: 'image/jpeg', upsert: true });
  if (up.error) {
    console.error(`✗ upload ${file}:`, up.error.message);
    await db.auth.admin.deleteUser(id).catch(() => {});
    continue;
  }
  const url = db.storage.from(BUCKET).getPublicUrl(key).data.publicUrl;

  // 3. profile row
  const name = NAMES[lang][gender][i % NAMES[lang][gender].length];
  const persona = rnd(Object.keys(PERSONA));
  const a = age();
  const row = {
    id,
    handle: `seed_${lang}_${randomUUID().slice(0, 6)}`,
    display_name: name,
    language: lang,
    country: COUNTRY[lang],
    city: CITIES[lang][i % CITIES[lang].length],
    gender,
    age: a,
    job: rnd(JOBS),
    zodiac: rnd(ZODIAC),
    looking_for: rnd(LOOKING),
    persona_category: persona,
    bio: `${PERSONA[persona][lang]}. ${BIO_TAIL[lang]}`,
    interests: sample(INTERESTS, 2 + Math.floor(Math.random() * 3)),
    avatar_url: url,
    discover_photo_url: url,
    photos: [url],
    updated_at: new Date().toISOString(),
  };
  const ins = await db.from('profiles').insert(row);
  if (ins.error) {
    console.error(`✗ insert ${name} (${lang}/${gender}):`, ins.error.message);
    await db.storage.from(BUCKET).remove([key]).catch(() => {});
    await db.auth.admin.deleteUser(id).catch(() => {});
    continue;
  }
  ok++;
  console.log(`✓ ${name.padEnd(11)} ${lang} ${gender} ${a}  ${persona}`);
}
console.log(`\n${ok}/${photos.length} profiles created.`);
