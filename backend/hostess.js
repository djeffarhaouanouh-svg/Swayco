'use strict';

// L'hôtesse d'accueil : une minute après la fin de l'inscription, chaque nouvel
// utilisateur devient AMI avec le compte de l'hôtesse (Iasmim), qui l'accueille.
// La conversation existe alors dans sa liste dès le départ (et l'écran « c'est
// un match » s'affiche) au lieu d'un onglet Messages vide — ce qui faisait fuir
// les nouvelles inscrites en 5 minutes.
//
// Variables d'environnement :
//   HOSTESS_ENABLED   « 0 » coupe tout (défaut : actif)
//   HOSTESS_USER_ID   l'id du compte hôtesse (défaut : Iasmim)
//   HOSTESS_DELAY_MS  attente après la création du profil (défaut : 60 000)

const HOSTESS_ID =
  (process.env.HOSTESS_USER_ID || '2b5383a3-9afa-4369-add9-87fe3f6298e6').trim();
const DELAY_MS = Number(process.env.HOSTESS_DELAY_MS) || 60 * 1000;
// On ne remonte pas plus loin : un profil plus ancien n'est pas « qui vient de
// finir l'inscription », et un redémarrage ne doit pas ressusciter des mois
// d'inscrits.
const WINDOW_MS = 6 * 60 * 60 * 1000;
const PER_TICK = 25;

// Déjà traités dans CE processus : si quelqu'un se sépare de l'hôtesse dans les
// 6 h, on ne la lui remet pas de force.
const handled = new Set();

async function runOnce(supabase) {
  const sb = supabase();
  if (!sb || !HOSTESS_ID) return { ok: false, reason: 'not_configured' };
  const now = Date.now();
  const newerThan = new Date(now - WINDOW_MS).toISOString();
  const olderThan = new Date(now - DELAY_MS).toISOString();

  const { data: fresh, error } = await sb
    .from('profiles')
    .select('id, handle, is_ai, created_at')
    .eq('is_ai', false)
    .neq('id', HOSTESS_ID)
    .gte('created_at', newerThan)
    .lte('created_at', olderThan)
    .order('created_at', { ascending: true })
    .limit(200);
  if (error) return { ok: false, error: error.message };

  // Ni les comptes de test, ni ceux déjà traités.
  const candidates = (fresh || []).filter(
    (p) => !handled.has(p.id) && !String(p.handle || '').startsWith('seed_'),
  );
  if (candidates.length === 0) return { ok: true, added: 0 };

  const ids = candidates.map((p) => p.id);
  // Qui a déjà un lien (quel que soit son état) avec l'hôtesse ?
  const { data: existing, error: e2 } = await sb
    .from('friendships')
    .select('requester, addressee')
    .or(
      `and(requester.eq.${HOSTESS_ID},addressee.in.(${ids.join(',')})),` +
        `and(addressee.eq.${HOSTESS_ID},requester.in.(${ids.join(',')}))`,
    );
  if (e2) return { ok: false, error: e2.message };
  const linked = new Set();
  for (const f of existing || []) {
    linked.add(f.requester === HOSTESS_ID ? f.addressee : f.requester);
  }

  let added = 0;
  for (const p of candidates) {
    handled.add(p.id);
    if (linked.has(p.id)) continue;
    if (added >= PER_TICK) break;
    const stamp = new Date().toISOString();
    const { error: e3 } = await sb.from('friendships').insert({
      requester: p.id,
      addressee: HOSTESS_ID,
      status: 'accepted',
      responded_at: stamp,
    });
    if (e3) {
      console.error('[hostess] insert failed', p.id, e3.message);
      handled.delete(p.id);
      continue;
    }
    added += 1;
  }
  if (added) console.log(`[hostess] ${added} nouvel(le)s ami(e)s pour l'hôtesse`);
  return { ok: true, added };
}

function start({ supabase }) {
  if (process.env.HOSTESS_ENABLED === '0') {
    console.log('[hostess] désactivée (HOSTESS_ENABLED=0)');
    return;
  }
  if (!supabase()) return;
  const timer = setInterval(() => {
    runOnce(supabase).catch((e) =>
      console.error('[hostess] error', e?.message || e),
    );
  }, 30 * 1000);
  timer.unref?.();
  console.log(`[hostess] actif (délai ${DELAY_MS} ms, hôtesse ${HOSTESS_ID.slice(0, 8)}…)`);
}

module.exports = { start, runOnce };
