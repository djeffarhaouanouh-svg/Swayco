// Poste un message du compte officiel Swayco (lecture seule dans l'app).
//
//   node admin/scripts/post_official.mjs "Titre" "Texte du message" ["URL du GIF/vidéo"]
//   node admin/scripts/post_official.mjs --list
//   node admin/scripts/post_official.mjs --delete <id>
//
// Utilise SUPABASE_SERVICE_ROLE_KEY depuis admin/.env.local (contourne la RLS :
// l'app, elle, ne peut que LIRE la table official_posts).

import { createClient } from '@supabase/supabase-js';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const envPath = resolve(import.meta.dirname, '..', '.env.local');
const env = Object.fromEntries(
  readFileSync(envPath, 'utf8')
    .split('\n')
    .map((l) => l.trim())
    .filter((l) => l && !l.startsWith('#') && l.includes('='))
    .map((l) => {
      const i = l.indexOf('=');
      return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^"|"$/g, '')];
    }),
);

const url = env.NEXT_PUBLIC_SUPABASE_URL || env.SUPABASE_URL;
const key = env.SUPABASE_SERVICE_ROLE_KEY;
if (!url || !key) {
  console.error('SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY manquants dans admin/.env.local');
  process.exit(1);
}
const sb = createClient(url, key, { auth: { persistSession: false } });

const args = process.argv.slice(2);

if (args[0] === '--list') {
  const { data, error } = await sb
    .from('official_posts')
    .select('id, title, body, created_at')
    .order('created_at', { ascending: false })
    .limit(50);
  if (error) throw error;
  for (const p of data) console.log(`${p.id}  ${p.created_at}  ${p.title} — ${p.body}`);
} else if (args[0] === '--delete' && args[1]) {
  const { error } = await sb.from('official_posts').delete().eq('id', args[1]);
  if (error) throw error;
  console.log('supprimé');
} else if (args.length >= 2) {
  // Le 3e argument (optionnel) : l'URL d'un GIF / d'une image / d'une vidéo
  // posée en exemple sous le message.
  const [title, body, media_url = ''] = args;
  const { data, error } = await sb
    .from('official_posts')
    .insert({ title, body, media_url })
    .select('id')
    .single();
  if (error) throw error;
  console.log('publié', data.id);
} else {
  console.error('Usage : post_official.mjs "Titre" "Texte"  |  --list  |  --delete <id>');
  process.exit(1);
}
