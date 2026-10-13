// Re-assign existing AI accounts from one country to another, without
// re-uploading photos. Built to fix the "Femme Europe" lot, created with Italy
// instead of Sweden.
//
//   node admin/scripts/convert_ai_country.mjs                 # DRY RUN: counts only, writes nothing
//   node admin/scripts/convert_ai_country.mjs --go            # do it
//   node admin/scripts/convert_ai_country.mjs --from Italie --to Suède --go
//
// Only touches rows that are is_ai = true AND country = <from> AND gender = 'f'.
// Updates: country, city, language, display_name, bio, handle prefix, and the
// chat persona (ai_personas). Photos, age, job, interests are kept.
// Uses SUPABASE_SERVICE_ROLE_KEY from admin/.env.local.

import { createClient } from '@supabase/supabase-js';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const arg = (n, d) => { const i = process.argv.indexOf(n); return i > -1 ? process.argv[i + 1] : d; };
const GO = process.argv.includes('--go');
const FROM = arg('--from', 'Italie');
const TO = arg('--to', 'Suède');

const env = Object.fromEntries(
  readFileSync(resolve(import.meta.dirname, '..', '.env.local'), 'utf8')
    .split('\n').map((l) => l.trim())
    .filter((l) => l && !l.startsWith('#') && l.includes('='))
    .map((l) => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim()]; }),
);
if (!env.NEXT_PUBLIC_SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY) throw new Error('Missing Supabase URL / service-role key in admin/.env.local');
const db = createClient(env.NEXT_PUBLIC_SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });

// ── target country data (add more here if needed) ──────────────────────────
const TARGETS = {
  'Suède': {
    iso: 'sue',
    language: 'en',
    cities: ['Stockholm', 'Göteborg', 'Malmö', 'Uppsala'],
    names: ['Emma', 'Alice', 'Maja', 'Ella', 'Wilma', 'Elsa', 'Saga', 'Astrid', 'Freja', 'Ebba', 'Selma', 'Alma', 'Klara', 'Linnea', 'Stella', 'Agnes', 'Signe', 'Tilda', 'Vera', 'Moa', 'Julia', 'Lovisa', 'Elin', 'Sofia', 'Hanna', 'Emelie', 'Matilda', 'Ida', 'Amanda', 'Filippa', 'Ingrid', 'Nora', 'Josefin', 'Frida', 'Cecilia', 'Johanna'],
  },
};
const T = TARGETS[TO];
if (!T) throw new Error(`No data for target country "${TO}". Known: ${Object.keys(TARGETS).join(', ')}`);

const BIOS = [
  'I laugh at my own jokes before I finish them.',
  'Coffee first, conversation second.',
  'My cat judges me daily. Come defend me.',
  "I learn languages to understand other countries' memes.",
  'I can cook two dishes and I repeat them shamelessly.',
  'Ideal Sunday: blanket, series, zero plans.',
  'Always late, but with a good playlist.',
  'Looking for people to talk about everything and nothing.',
  'I photograph sunsets and food, in that order.',
  'Better by text than by call, fair warning.',
  'Student by day, curious by night.',
  'I collect notebooks I never finish.',
  'Strong opinions about hot chocolate.',
  "I get lost with GPS on. It's a talent.",
  "I'll practice your language if you practice mine.",
  'Gym Monday and Wednesday; the rest is couch.',
  "Tell me your song of the moment and I'll tell you who you are.",
  'Low drama, big curiosity about new people.',
  'Travel is my excuse to eat strange things.',
  'I make friends everywhere except the gym.',
];
const FAMILY = ['an older brother who is a nurse', 'a younger sister still in high school', 'a mom who runs a small shop', 'two cousins she is very close to', 'a dad who fixes bikes as a hobby', 'a grandmother she calls every Sunday'];
const QUIRKS = ['runs early two mornings a week and complains about it', 'is learning to play the ukulele badly', 'keeps a plant that almost died twice', 'reads webtoons on the bus', 'has a rescue cat who hates visitors', 'is obsessed with true-crime podcasts', 'collects tiny notebooks', 'is trying to learn Korean from dramas', 'bakes when she is stressed', 'sketches people on public transport', 'plays pickup volleyball on Saturdays', 'edits short videos for fun'];
const TEXT_STYLE = ['short messages, lowercase, one emoji at most', 'warm and teasing, asks a lot of questions', 'dry humour, understated', 'enthusiastic but never over the top', 'calm and curious, replies with a small story'];
const rnd = (a) => a[Math.floor(Math.random() * a.length)];
const personaFor = ({ name, a, city, country, job, lookingFor, interests }) =>
  `${name}, ${a}, lives in ${city}, ${country}. Works/studies in: ${job}. Interests: ${(interests || []).join(', ')}. ` +
  `Has ${rnd(FAMILY)}. ${name} ${rnd(QUIRKS)}. Texting style: ${rnd(TEXT_STYLE)}. Here for: ${lookingFor}. ` +
  `Talks about ${name}'s own life with small concrete details, and mostly asks about the other person.`;

// ── select the rows ────────────────────────────────────────────────────────
const rows = [];
for (let from = 0; ; from += 1000) {
  const { data, error } = await db.from('profiles')
    .select('id, handle, age, job, looking_for, interests')
    .eq('is_ai', true).eq('country', FROM).eq('gender', 'f')
    .order('id', { ascending: true }).range(from, from + 999);
  if (error) throw error;
  rows.push(...data);
  if (data.length < 1000) break;
}
console.log(`${rows.length} AI account(s) in "${FROM}" (female) -> "${TO}".`);
if (!GO) {
  console.log('DRY RUN — nothing written. Re-run with --go to convert them.');
  process.exit(0);
}

let ok = 0, fail = 0, idx = 0;
async function worker() {
  while (idx < rows.length) {
    const r = rows[idx++];
    const name = rnd(T.names);
    const city = rnd(T.cities);
    // Même règle que les vrais comptes (jamais de « ai_ » visible) : prénom a-z0-9 + 6 derniers caractères de l'id.
    const handle = `${String(name).normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9]+/g, '').slice(0, 24) || 'user'}-${r.id.replace(/-/g, '').slice(-6)}`;
    const upd = await db.from('profiles').update({
      country: TO,
      city,
      language: T.language,
      display_name: name,
      bio: rnd(BIOS),
      handle,
      updated_at: new Date().toISOString(),
    }).eq('id', r.id).eq('is_ai', true);
    if (upd.error) { fail++; console.error(`x ${r.id}: ${upd.error.message}`); continue; }
    const per = await db.from('ai_personas').upsert({
      user_id: r.id,
      persona: personaFor({ name, a: r.age, city, country: TO, job: r.job || 'Étudiant', lookingFor: r.looking_for || 'Amitié', interests: r.interests }),
      updated_at: new Date().toISOString(),
    });
    if (per.error) console.warn(`persona ${r.id}: ${per.error.message}`);
    ok++;
    if (ok % 50 === 0) console.log(`... ${ok}/${rows.length}`);
  }
}
await Promise.all(Array.from({ length: 6 }, worker));
console.log(`\n${ok} converted, ${fail} failed.`);
