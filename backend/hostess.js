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
//   HOSTESS_VOICE     « 0 » : plus de vocal d'accueil (défaut : envoyé)
//   HOSTESS_VOICE_URL un autre fichier audio d'accueil
//
// Juste après l'ajout, l'hôtesse envoie son VOCAL d'accueil (« Oiê, bem-vindo ! »,
// enregistré par elle), traduit comme n'importe quel vocal du chat.

const IASMIM_ID = '2b5383a3-9afa-4369-add9-87fe3f6298e6';
const HOSTESS_ID = (process.env.HOSTESS_USER_ID || IASMIM_ID).trim();
// La voix est celle d'Iasmim : elle ne part jamais au nom d'une autre hôtesse,
// sauf si un fichier est donné exprès.
const VOICE = {
  url: (process.env.HOSTESS_VOICE_URL ||
    (HOSTESS_ID === IASMIM_ID && process.env.SUPABASE_URL
      ? `${process.env.SUPABASE_URL.replace(/\/+$/, '')}/storage/v1/object/public/avatars/hostess/welcome_pt.m4a`
      : '')).trim(),
  durationMs: 3117,
  transcript: 'Oiê, bem-vindo!',
  language: 'pt',
};
const VOICE_PUSH = {
  fr: '🎤 Message vocal', en: '🎤 Voice message', es: '🎤 Mensaje de voz',
  de: '🎤 Sprachnachricht', it: '🎤 Messaggio vocale', pt: '🎤 Mensagem de voz',
  nl: '🎤 Spraakbericht', ar: '🎤 رسالة صوتية', ru: '🎤 Голосовое сообщение',
  zh: '🎤 语音消息', ja: '🎤 ボイスメッセージ', ko: '🎤 음성 메시지',
};
const DELAY_MS = Number(process.env.HOSTESS_DELAY_MS) || 60 * 1000;
// On ne remonte pas plus loin : un profil plus ancien n'est pas « qui vient de
// finir l'inscription », et un redémarrage ne doit pas ressusciter des mois
// d'inscrits.
const WINDOW_MS = 6 * 60 * 60 * 1000;
const PER_TICK = 25;

// Déjà traités dans CE processus : si quelqu'un se sépare de l'hôtesse dans les
// 6 h, on ne la lui remet pas de force.
const handled = new Set();

/** Le vocal d'accueil, dans la conversation de l'hôtesse et de [profile]. */
async function sendWelcomeVoice(sb, notifyUser, profile) {
  if (process.env.HOSTESS_VOICE === '0' || !VOICE.url) return false;
  const conversationId = `dm-${[HOSTESS_ID, profile.id].sort().join('-')}`;
  // Jamais sur une conversation déjà commencée (donc jamais deux fois).
  const { data: already, error: e0 } = await sb
    .from('messages')
    .select('id')
    .eq('conversation_id', conversationId)
    .eq('sender', HOSTESS_ID)
    .limit(1);
  if (e0 || (already && already.length)) return false;
  const { data: host } = await sb
    .from('profiles')
    .select('display_name')
    .eq('id', HOSTESS_ID)
    .maybeSingle();
  const name = String((host && host.display_name) || 'Iasmim').trim();
  const { error } = await sb.from('messages').insert({
    conversation_id: conversationId,
    sender: HOSTESS_ID,
    recipient: profile.id,
    sender_name: name,
    body: VOICE.transcript,
    language: VOICE.language,
    audio_url: VOICE.url,
    audio_duration_ms: VOICE.durationMs,
  });
  if (error) {
    console.error('[hostess] voice insert failed', profile.id, error.message);
    return false;
  }
  if (notifyUser) {
    const lang = String(profile.language || '').toLowerCase().split(/[-_]/)[0];
    await notifyUser(profile.id, {
      title: name,
      body: VOICE_PUSH[lang] || VOICE_PUSH.en,
      type: 'message',
      data: { conversationId, senderId: HOSTESS_ID },
    }).catch((e) => console.error('[hostess] voice push', e?.message || e));
  }
  return true;
}

async function runOnce(supabase, notifyUser) {
  const sb = supabase();
  if (!sb || !HOSTESS_ID) return { ok: false, reason: 'not_configured' };
  const now = Date.now();
  const newerThan = new Date(now - WINDOW_MS).toISOString();
  const olderThan = new Date(now - DELAY_MS).toISOString();

  const { data: fresh, error } = await sb
    .from('profiles')
    .select('id, handle, is_ai, created_at, language')
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
    await sendWelcomeVoice(sb, notifyUser, p).catch((e) =>
      console.error('[hostess] voice error', e?.message || e),
    );
  }
  if (added) console.log(`[hostess] ${added} nouvel(le)s ami(e)s pour l'hôtesse`);
  return { ok: true, added };
}

function start({ supabase, notifyUser }) {
  if (process.env.HOSTESS_ENABLED === '0') {
    console.log('[hostess] désactivée (HOSTESS_ENABLED=0)');
    return;
  }
  if (!supabase()) return;
  const timer = setInterval(() => {
    runOnce(supabase, notifyUser).catch((e) =>
      console.error('[hostess] error', e?.message || e),
    );
  }, 30 * 1000);
  timer.unref?.();
  console.log(`[hostess] actif (délai ${DELAY_MS} ms, hôtesse ${HOSTESS_ID.slice(0, 8)}…)`);
}

module.exports = { start, runOnce, sendWelcomeVoice };
