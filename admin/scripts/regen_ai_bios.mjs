// Réécrit les bios des comptes IA : les anciennes viennent d'un petit stock de
// phrases toutes faites (139 textes pour ~3 000 comptes, certains posés une
// centaine de fois). Chaque compte reçoit une bio courte, propre à lui, dans SA
// langue, écrite par DeepSeek à partir de son métier, de ses intérêts et de sa
// ville — sans les détails du personnage (qui se répétaient d'un compte à l'autre).
//
// Seuls les comptes qui ONT déjà une bio sont réécrits (un compte sans bio reste
// sans bio). L'ancien texte est sauvegardé dans .bios_backup.json.
//
//   node admin/scripts/regen_ai_bios.mjs --sample=30     aperçu de 30 bios (n'écrit rien)
//   node admin/scripts/regen_ai_bios.mjs --apply         écrit toutes les bios
//   node admin/scripts/regen_ai_bios.mjs --restore       remet les anciennes bios
//
// Utilise SUPABASE_SERVICE_ROLE_KEY de admin/.env.local et FIX_KEY de .env.local (racine).
import { createClient } from '@supabase/supabase-js';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

const APPLY = process.argv.includes('--apply');
const RESTORE = process.argv.includes('--restore');
const SAMPLE = Number((process.argv.find((a) => a.startsWith('--sample=')) || '').split('=')[1] || 0);

const parseEnv = (path) =>
  Object.fromEntries(
    readFileSync(path, 'utf8').split('\n').map((l) => l.trim())
      .filter((l) => l && !l.startsWith('#') && l.includes('='))
      .map((l) => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^["']|["']$/g, '')]; }),
  );
const adminEnv = parseEnv(resolve(import.meta.dirname, '..', '.env.local'));
const rootEnv = parseEnv(resolve(import.meta.dirname, '..', '..', '.env.local'));
const db = createClient(adminEnv.NEXT_PUBLIC_SUPABASE_URL, adminEnv.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const BACKUP = resolve(import.meta.dirname, '..', '..', '.bios_backup.json');

const LANG = {
  fr: 'French', en: 'English', es: 'Spanish', it: 'Italian', pt: 'Portuguese (Brazil)', nl: 'Dutch',
  ar: 'Arabic', ru: 'Russian', zh: 'Chinese', ko: 'Korean', de: 'German', ja: 'Japanese',
};
// Un angle différent par compte : sans ça le modèle retombe sur les mêmes images.
const ANGLES = [
  'what they do on a typical weekend', 'a small food habit', 'the music they listen to lately',
  'their work or studies, in a human way', 'a sport or physical activity', 'a place in their city they love',
  'something they are learning right now', 'how they like to talk with new people', 'a show, book or game they are into',
  'what a good day looks like for them', 'a hobby they do alone', 'what they look for in a conversation',
  'a trip they dream of', 'their morning or evening routine', 'a skill they are proud of',
];
const pick = (arr) => arr[Math.floor(Math.random() * arr.length)];

async function ask(p) {
  const lang = LANG[p.language] || 'English';
  const sys = [
    `You write the short bio of a real 20-something on a dating / language-exchange app, in ${lang}.`,
    'One short line, 5 to 14 words, casual, specific, the way a real person types it in 10 seconds.',
    `Angle for this one: ${pick(ANGLES)}. Use the profile only as loose inspiration, do not list facts.`,
    `The author is ${p.gender === 'm' ? 'a man' : 'a woman'}: use the matching grammatical gender wherever the language marks it.`,
    'Never write the name, the age or the city. No emoji, no hashtags, no quotation marks.',
    'No jokes built on a formula ("I have strong opinions about…", "I collect…", "I make friends everywhere except…").',
    'Never mention AI, bots, apps or the profile itself. Output ONLY the bio.',
  ].join(' ');
  const usr = `Job field: ${p.job || 'n/a'}. Interests: ${(p.interests || []).join(', ') || 'n/a'}. Looking for: ${p.looking_for || 'n/a'}. City: ${p.city || ''}.`;
  const base = (rootEnv.FIX_BASE || 'https://api.deepseek.com').replace(/\/+$/, '');
  const res = await fetch(`${base}/chat/completions`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${rootEnv.FIX_KEY}` },
    body: JSON.stringify({
      model: rootEnv.FIX_MODEL || 'deepseek-v4-flash',
      messages: [{ role: 'system', content: sys }, { role: 'user', content: usr }],
      temperature: 1.1, max_tokens: 70, thinking: { type: 'disabled' },
    }),
  });
  const j = await res.json();
  return (j.choices?.[0]?.message?.content || '').trim().replace(/^["“«'`]+|["”»'`]+$/g, '').replace(/\s+/g, ' ');
}

const EMOJI = /\p{Extended_Pictographic}/u;
function valid(bio, p, used) {
  if (!bio || EMOJI.test(bio)) return false;
  const cjk = /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]/u.test(bio);
  if (bio.length < (cjk ? 6 : 18) || bio.length > (cjk ? 70 : 120)) return false;
  if (bio.includes('\n') || /#/.test(bio)) return false;
  if (new RegExp(`\\b${p.age}\\b`).test(bio)) return false;
  if (p.display_name && bio.toLowerCase().includes(p.display_name.toLowerCase())) return false;
  if (/\b(IA|AI|bot|chatbot|KI|IA\.)\b/.test(bio)) return false;
  if (used.has(bio.toLowerCase())) return false;
  return true;
}

async function loadAll() {
  const rows = [];
  for (let from = 0; ; from += 1000) {
    const { data, error } = await db.from('profiles')
      .select('id,display_name,age,city,job,interests,looking_for,language,gender,bio')
      .eq('is_ai', true).not('bio', 'is', null).neq('bio', '')
      .order('id').range(from, from + 999);
    if (error) throw error;
    rows.push(...data);
    if (data.length < 1000) break;
  }
  return rows;
}

if (RESTORE) {
  const old = JSON.parse(readFileSync(BACKUP, 'utf8'));
  let n = 0;
  for (const [id, bio] of Object.entries(old)) {
    const { error } = await db.from('profiles').update({ bio }).eq('id', id);
    if (error) console.error(id, error.message); else n++;
  }
  console.log(`restaurées : ${n}`);
  process.exit(0);
}

let rows = await loadAll();
console.log(`comptes IA avec bio : ${rows.length}`);
if (SAMPLE) rows = rows.sort(() => Math.random() - 0.5).slice(0, SAMPLE);

if (APPLY && !existsSync(BACKUP)) {
  writeFileSync(BACKUP, JSON.stringify(Object.fromEntries(rows.map((r) => [r.id, r.bio])), null, 1));
  console.log(`sauvegarde : ${BACKUP}`);
}

const used = new Set();
const openings = new Map(); // les 3 premiers mots : pas plus de 4 fois la même ouverture
let done = 0, failed = 0, i = 0;
async function worker() {
  while (i < rows.length) {
    const p = rows[i++];
    let bio = '';
    for (let t = 0; t < 4; t++) {
      try { bio = await ask(p); } catch { bio = ''; }
      const open = bio.split(/\s+/).slice(0, 3).join(' ').toLowerCase();
      if (valid(bio, p, used) && (openings.get(open) || 0) < 4) { openings.set(open, (openings.get(open) || 0) + 1); break; }
      bio = '';
    }
    if (!bio) { failed++; continue; }
    used.add(bio.toLowerCase());
    if (SAMPLE) console.log(`[${p.language}] ${p.display_name}\n   avant : ${p.bio}\n   après : ${bio}`);
    else if (APPLY) {
      const { error } = await db.from('profiles').update({ bio }).eq('id', p.id);
      if (error) { failed++; console.error(p.id, error.message); continue; }
    }
    if (++done % 100 === 0) console.log(`  ${done}/${rows.length}`);
  }
}
await Promise.all(Array.from({ length: 8 }, worker));
console.log(`terminé : ${done} bios, ${failed} échecs${APPLY ? '' : ' (rien écrit)'}`);

