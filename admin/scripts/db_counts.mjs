// READ-ONLY: counts profiles by kind and by country. Writes nothing.
//   node admin/scripts/db_counts.mjs
import { createClient } from '@supabase/supabase-js';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const env = Object.fromEntries(
  readFileSync(resolve(import.meta.dirname, '..', '.env.local'), 'utf8')
    .split('\n').map((l) => l.trim())
    .filter((l) => l && !l.startsWith('#') && l.includes('='))
    .map((l) => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim()]; }),
);
const db = createClient(env.NEXT_PUBLIC_SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });

const count = async (label, q) => {
  const { count, error } = await q;
  console.log(`${label.padEnd(34)} ${error ? 'ERR ' + error.message : count}`);
};
const P = () => db.from('profiles').select('id', { count: 'exact', head: true });

await count('all profiles', P());
await count('is_ai = true', P().eq('is_ai', true));
await count('is_ai = false', P().eq('is_ai', false));

// By country, via the exact head counts (no 1 000-row cap involved).
const { data: rows, error } = await db.from('country_counts').select('country, total, humans, ai').order('total', { ascending: false });
console.log('\nview country_counts:', error ? 'ERR ' + error.message : '');
for (const r of rows ?? []) console.log(`  ${String(r.country).padEnd(16)} total ${String(r.total).padStart(5)}  humans ${String(r.humans).padStart(4)}  ai ${String(r.ai).padStart(5)}`);

console.log('\nexact head count per country (profiles table):');
for (const c of ['Brésil', 'Mexique', 'Argentine', 'Colombie', 'France', 'Allemagne', 'Espagne', 'Suède', 'Italie', 'Japon', 'Corée du Sud', 'Inde', 'Philippines']) {
  await count('  ' + c, P().eq('country', c));
}
