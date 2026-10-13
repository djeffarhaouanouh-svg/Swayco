// Gives the AI accounts the SAME kind of handle as real accounts. The seeders
// used `ai_<iso>_<6 hex>` (e.g. @ai_jap_efeb34), which shows "ai" on the profile.
// New handle = display name stripped to a-z0-9 (accents folded), a dash, and 6
// characters of the account id (the LAST ones: the seeded ids start with zeros) — exactly the app's own rule
// (ProfileApi._deriveHandle): `lou-2f80fb`. Falls back to `user-xxxxxx` when the
// name has no latin letter (梨音, Анна, 서연…). Handles stay unique.
//
//   node admin/scripts/neutral_ai_handles.mjs            dry run (writes nothing)
//   node admin/scripts/neutral_ai_handles.mjs --apply    writes
//
// Only profiles.handle of rows with is_ai = true and handle LIKE 'ai\_%' changes.
import { createClient } from '@supabase/supabase-js';
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

const APPLY = process.argv.includes('--apply');
const env = Object.fromEntries(
  readFileSync(resolve(import.meta.dirname, '..', '.env.local'), 'utf8')
    .split('\n').map((l) => l.trim())
    .filter((l) => l && !l.startsWith('#') && l.includes('='))
    .map((l) => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim()]; }),
);
const db = createClient(env.NEXT_PUBLIC_SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });

const fetchAll = async (cols, build) => {
  const out = [];
  for (let from = 0; ; from += 1000) {
    const { data, error } = await build(db.from('profiles').select(cols)).order('id').range(from, from + 999);
    if (error) throw error;
    out.push(...data);
    if (data.length < 1000) break;
  }
  return out;
};

const slug = (name) => String(name || '')
  .normalize('NFD').replace(/[̀-ͯ]/g, '')
  .toLowerCase().replace(/[^a-z0-9]+/g, '').slice(0, 24);

const ais = await fetchAll('id, handle, display_name', (q) => q.eq('is_ai', true).like('handle', 'ai\\_%'));
const all = await fetchAll('id, handle', (q) => q);
const used = new Set(all.map((r) => r.handle));

const plan = [];
for (const r of ais) {
  const base = slug(r.display_name) || 'user';
  const hex = r.id.replace(/-/g, '');
  let h = `${base}-${hex.slice(-6)}`;
  for (let n = 8; used.has(h) && n <= 16; n += 2) h = `${base}-${hex.slice(-n)}`;
  if (used.has(h)) throw new Error(`no free handle for ${r.id}`);
  used.add(h);
  plan.push({ id: r.id, from: r.handle, to: h });
}

console.log(`${ais.length} AI accounts with an ai_ handle; ${plan.length} renames planned`);
console.log(plan.slice(0, 8).map((p) => `  ${p.from}  →  ${p.to}`).join('\n'));
if (plan.some((p) => /^ai[_-]/i.test(p.to))) throw new Error('a new handle still starts with ai');
if (APPLY && plan.length) {
  // Sauvegarde des anciens handles, écrite seulement quand on modifie vraiment.
  writeFileSync(resolve(import.meta.dirname, '.neutral_ai_handles_plan.json'), JSON.stringify(plan));
}

if (APPLY) {
  let done = 0;
  for (let i = 0; i < plan.length; i += 20) {
    await Promise.all(plan.slice(i, i + 20).map(async (p) => {
      const { error } = await db.from('profiles').update({ handle: p.to }).eq('id', p.id).eq('is_ai', true);
      if (error) console.error('ERR', p.id, error.message); else done++;
    }));
  }
  console.log(`${done}/${plan.length} updated (backup of the old handles: admin/scripts/.neutral_ai_handles_plan.json)`);
}

