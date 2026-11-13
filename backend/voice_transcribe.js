'use strict';

// Transcription des messages vocaux du chat.
//
// L'app dépose le fichier dans le bucket public `voice-messages` (dossier de
// l'expéditeur), insère la ligne `messages`, puis appelle
// POST /messages/voice/transcribe { messageId }. Ici on lit le fichier, on le
// fait transcrire (OpenAI /v1/audio/transcriptions) et on écrit le texte dans
// `messages.body` et la langue dans `messages.language` : le temps réel le
// pousse au destinataire, et la traduction du chat s'applique comme à un texte.
//
// Rien ici n'a de rapport avec le circuit des appels.

const MAX_BYTES = 3 * 1024 * 1024; // 60 s en AAC 64 kbit/s font ~480 Ko
// messages.id est un entier (436, 441…) ; un UUID reste accepté.
const ID_RE = /^(\d{1,18}|[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12})$/i;

function primaryTag(v) {
  const s = typeof v === 'string' ? v.trim().toLowerCase() : '';
  const i = s.search(/[-_]/);
  return i === -1 ? s : s.slice(0, i);
}

function validTag(tag) {
  return /^[a-z]{2,3}$/.test(tag);
}

/** Le seul endroit d'où on accepte de lire un fichier : le dossier de l'expéditeur. */
function ownFolderPrefix(supabaseUrl, uid) {
  return `${String(supabaseUrl || '').replace(/\/+$/, '')}/storage/v1/object/public/voice-messages/${uid}/`;
}

/**
 * Cette adresse est-elle bien un vocal de [uid] dans le bucket public ?
 *
 * On ne compare PLUS la chaîne à `SUPABASE_URL` : sur Railway elle n'a pas
 * toujours la même forme que celle que les apps ont écrite dans le message (tous
 * les vocaux étaient refusés). On exige donc, en lisant l'adresse : https, un hôte
 * qui est celui de `SUPABASE_URL` OU un `*.supabase.co`, et le chemin exact
 * `/storage/v1/object/public/voice-messages/<uid>/…`. Un hôte quelconque, un
 * autre bucket ou le dossier de quelqu'un d'autre restent refusés.
 */
function isOwnVoiceUrl(url, supabaseUrl, uid) {
  let u;
  try {
    u = new URL(String(url || ''));
  } catch (_) {
    return false;
  }
  if (u.protocol !== 'https:') return false;
  let configured = '';
  try {
    configured = new URL(String(supabaseUrl || '')).host.toLowerCase();
  } catch (_) {}
  const host = u.host.toLowerCase();
  const hostOk = (configured && host === configured) || host.endsWith('.supabase.co');
  if (!hostOk) return false;
  return u.pathname.startsWith(`/storage/v1/object/public/voice-messages/${uid}/`);
}

/**
 * Dans quel ordre essayer les services. OpenAI d'abord (ce qui a été convenu) ;
 * Grok ne sert que de secours (clé OpenAI sans crédit, panne). `provider`
 * ('grok' | 'openai') force le premier. Un service sans clé est ignoré.
 */
function sttOrder({ provider, openaiKey, grokKey }) {
  const first = String(provider || '').toLowerCase() === 'grok' ? ['grok', 'openai'] : ['openai', 'grok'];
  return first.filter((p) => (p === 'openai' ? !!openaiKey : !!grokKey));
}

/** Un essai chez un fournisseur. Jamais d'exception : { ok, text } ou { ok:false, error }. */
async function runStt({ p, audio, ext, mime, lang, openaiKey, model, grokKey, grokBase, fetchImpl }) {
  try {
    const form = new FormData();
    form.append('file', new Blob([audio], { type: mime }), `voice.${ext}`);
    let url;
    let key;
    if (p === 'grok') {
      // Grok : un seul champ, `file` (la langue est détectée ; rien d'autre n'est accepté).
      url = `${String(grokBase).replace(/\/+$/, '')}/stt`;
      key = grokKey;
    } else {
      form.append('model', model);
      if (validTag(lang)) form.append('language', lang);
      form.append('response_format', 'json');
      url = 'https://api.openai.com/v1/audio/transcriptions';
      key = openaiKey;
    }
    const r = await fetchImpl(url, { method: 'POST', headers: { Authorization: `Bearer ${key}` }, body: form });
    const raw = await r.text();
    if (!r.ok) {
      console.error(`[voice] ${p} stt error`, r.status, raw.slice(0, 200));
      return { ok: false, error: `${p}_http_${r.status}` };
    }
    return { ok: true, text: String(JSON.parse(raw).text || '').trim() };
  } catch (e) {
    console.error(`[voice] ${p} stt throw`, e && e.message);
    return { ok: false, error: `${p}_unreachable` };
  }
}
// ── Phrases fantômes de Whisper ─────────────────────────────────────────────
// Sur du silence, du bruit ou un souffle, Whisper n'écrit pas « rien » : il
// invente ce qu'il a le plus vu dans ses données d'entraînement (sous-titres de
// vidéos). Exemples réels reçus : « Sous-titrage Société Radio-Canada »,
// « Merci d'avoir regardé cette vidéo… abonnez-vous », « 3 3 3 3 3 3… ».
const GHOST_PHRASES = [
  'sous-titrage', 'sous-titres', 'sous titres realises', 'merci d\'avoir regarde',
  'n\'hesitez pas a vous abonner', 'abonnez-vous', 'a la prochaine video',
  'c\'est tout pour aujourd\'hui', 'je vous souhaite une bonne soiree',
  'thanks for watching', 'thank you for watching', 'subtitles by', 'amara.org',
  'please subscribe', 'like and subscribe', 'subtitulos', 'gracias por ver',
  'legendas pela comunidade', 'obrigado por assistir', 'untertitel',
  'vielen dank fürs zuschauen', 'ご視聴ありがとうございました', '字幕', '시청해 주셔서',
];

function plain(s) {
  return String(s || '')
    .toLowerCase()
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .replace(/[’‘`]/g, "'");
}

/**
 * Ce texte est-il une invention de Whisper plutôt que ce que la personne a dit ?
 * Trois signes : une phrase de fin de vidéo connue (et courte : un vrai vocal
 * long qui la contiendrait par hasard passe), un même mot répété en boucle, ou
 * un texte sans aucune lettre.
 */
function isWhisperGhost(text) {
  const t = String(text || '').trim();
  if (!t || !/\p{L}/u.test(t)) return true;
  if (t.length <= 160) {
    const p = plain(t);
    if (GHOST_PHRASES.some((g) => p.includes(plain(g)))) return true;
  }
  const words = t.toLowerCase().split(/\s+/).filter(Boolean);
  if (words.length >= 8) {
    const count = new Map();
    for (const w of words) count.set(w, (count.get(w) || 0) + 1);
    if (Math.max(...count.values()) / words.length >= 0.6) return true;
  }
  return false;
}

/**
 * @returns {Promise<{status:number, body:object}>}
 *
 * `uid` vient du JWT vérifié, jamais de la requête : on ne transcrit que MES
 * vocaux. L'adresse du fichier est lue en base et doit pointer vers mon dossier
 * du bucket (pas d'URL libre : pas de requête vers n'importe où).
 */
async function transcribeVoiceMessage({
  sb,
  uid,
  messageId,
  hintLang,
  supabaseUrl,
  openaiKey,
  model = 'whisper-1',
  grokKey = '',
  grokBase = 'https://api.x.ai/v1',
  provider = '',
  fetchImpl = fetch,
  // Appel du serveur lui-même (voir startVoiceTranscriber) : pas de JWT, c'est le
  // message qui dit à qui il appartient.
  trusted = false,
}) {
  if (!ID_RE.test(String(messageId || ''))) {
    return { status: 400, body: { error: 'invalid_message' } };
  }
  if (!sb || !(openaiKey || grokKey)) {
    return { status: 503, body: { error: 'transcription_not_configured' } };
  }

  const { data: msg, error } = await sb
    .from('messages')
    .select('id, sender, audio_url, body')
    .eq('id', messageId)
    .maybeSingle();
  if (error) return { status: 502, body: { error: 'lookup_failed' } };
  if (!msg) return { status: 404, body: { error: 'not_found' } };
  if (trusted) uid = String(msg.sender);
  if (String(msg.sender) !== String(uid)) {
    return { status: 403, body: { error: 'not_yours' } };
  }
  const url = String(msg.audio_url || '');
  if (!isOwnVoiceUrl(url, supabaseUrl, uid)) {
    return { status: 400, body: { error: 'not_a_voice_message' } };
  }
  if (String(msg.body || '').trim()) {
    return { status: 200, body: { ok: true, already: true } };
  }

  // La langue : l'indice de l'app, sinon celle du profil. Nommée à Whisper, elle
  // évite la détection (plus rapide) et qu'un vocal court soit pris pour une
  // autre langue.
  let lang = primaryTag(hintLang);
  if (!validTag(lang)) {
    const { data: prof } = await sb
      .from('profiles')
      .select('language')
      .eq('id', uid)
      .maybeSingle();
    lang = primaryTag(prof && prof.language);
  }

  let audio;
  try {
    const r = await fetchImpl(url);
    if (!r.ok) return { status: 502, body: { error: 'audio_unreachable' } };
    audio = Buffer.from(await r.arrayBuffer());
  } catch (_) {
    return { status: 502, body: { error: 'audio_unreachable' } };
  }
  if (audio.length === 0 || audio.length > MAX_BYTES) {
    return { status: 400, body: { error: 'audio_size' } };
  }

  // Le format suit l'extension du fichier : m4a (AAC) depuis un téléphone, webm
  // (Opus) depuis le navigateur. OpenAI le reconnaît à son nom.
  const ext = (/\.(m4a|webm|ogg|mp3|wav)$/i.exec(url) || [, 'm4a'])[1].toLowerCase();
  const mime = { m4a: 'audio/mp4', webm: 'audio/webm', ogg: 'audio/ogg', mp3: 'audio/mpeg', wav: 'audio/wav' }[ext];

  // Fournisseurs essayés dans l'ordre : si le premier échoue (clé sans crédit,
  // service en panne), le suivant prend le relais.
  let text = '';
  let failure = 'stt_error';
  let used = '';
  for (const p of sttOrder({ provider, openaiKey, grokKey })) {
    const res = await runStt({
      p, audio, ext, mime, lang, openaiKey, model, grokKey, grokBase, fetchImpl,
    });
    if (res.ok) {
      text = res.text;
      used = p;
      failure = '';
      voiceStatus.provider = p;
      break;
    }
    failure = res.error;
    voiceStatus.lastSttError = `${p}: ${res.error}`;
  }
  if (failure) return { status: 502, body: { error: failure } };

  // Du silence ou une toux : Whisper invente parfois une phrase toute faite.
  // Sans aucune lettre, il n'y a rien à garder.
  if (isWhisperGhost(text)) {
    if (text) console.log(`[voice] ghost dropped ${messageId}: ${JSON.stringify(text.slice(0, 60))}`);
    return { status: 200, body: { ok: true, empty: true } };
  }

  // Seulement si le texte n'est pas déjà là (deux appels en même temps).
  const { error: upErr } = await sb
    .from('messages')
    .update({ body: text, language: validTag(lang) ? lang : '' })
    .eq('id', messageId)
    .eq('body', '');
  if (upErr) return { status: 502, body: { error: 'update_failed' } };

  console.log(`[voice] transcribed ${messageId} via ${used} lang=${lang || '?'} chars=${text.length}`);
  return { status: 200, body: { ok: true } };
}

// ── Transcription automatique ───────────────────────────────────────────────
// Chaque vocal est transcrit PAR LE SERVEUR, sans dépendre de l'app de
// l'expéditeur (fermée, hors ligne, ou un compte IA : personne n'appellerait la
// route). Toutes les `intervalMs` on cherche les vocaux récents sans texte.
//
//  - `graceMs` : on laisse d'abord l'app de l'expéditeur demander la
//    transcription elle-même (avec la langue qu'elle connaît) ; ce n'est qu'au
//    bout de ce délai qu'on prend le relais.
//  - au plus `maxAttempts` essais par message (un vocal de silence resterait sans
//    texte et serait sinon repris à chaque tour : chaque essai coûte un appel
//    OpenAI). Compteur en mémoire : un redémarrage dans la fenêtre en refait un.
//  - `windowMs` : on ne remonte pas dans le passé (messages plus anciens ignorés).
/** Lisible sur GET /health : de quoi voir, sans les logs, si la boucle tourne et pourquoi elle échoue. Aucun secret : seulement des compteurs et un code d'erreur. */
const voiceStatus = { enabled: false, provider: null, lastRunAt: null, lastRows: 0, ok: 0, failed: 0, lastError: null, lastSttError: null };

function createVoiceTranscriber({
  sb,
  supabaseUrl,
  openaiKey,
  model,
  grokKey = '',
  grokBase,
  provider = '',
  fetchImpl = fetch,
  now = () => Date.now(),
  graceMs = 25000,
  windowMs = 15 * 60000,
  maxAttempts = 2,
  batch = 10,
}) {
  const attempts = new Map();

  /** Un tour. Rend le nombre de vocaux traités. */
  async function tick() {
    if (!sb || !(openaiKey || grokKey)) return 0;
    const t = now();
    voiceStatus.lastRunAt = new Date(t).toISOString();
    const { data: rows, error } = await sb
      .from('messages')
      .select('id, sender')
      .neq('audio_url', '')
      .eq('body', '')
      .gte('created_at', new Date(t - windowMs).toISOString())
      .lte('created_at', new Date(t - graceMs).toISOString())
      .order('id', { ascending: true })
      .limit(batch);
    if (error || !rows) {
      voiceStatus.lastError = 'query: ' + (error && (error.code || error.message) || 'no rows');
      return 0;
    }
    voiceStatus.lastRows = rows.length;
    let done = 0;
    for (const m of rows) {
      const n = attempts.get(m.id) || 0;
      if (n >= maxAttempts) continue;
      attempts.set(m.id, n + 1);
      try {
        const out = await transcribeVoiceMessage({
          sb, messageId: String(m.id), supabaseUrl, openaiKey, model, grokKey, grokBase, provider, fetchImpl, trusted: true,
        });
        if (out.status === 200) {
          done += 1;
          voiceStatus.ok += 1;
        } else {
          voiceStatus.failed += 1;
          voiceStatus.lastError = ` -> ${out.status} ${out.body && out.body.error}`;
          console.error('[voice] auto-transcription', m.id, '->', out.status, out.body && out.body.error);
        }
      } catch (e) {
        voiceStatus.failed += 1;
        voiceStatus.lastError = ` threw ${e && e.message}`;
        console.error('[voice] auto-transcription threw', m.id, e && e.message);
      }
    }
    // La mémoire ne grossit pas : on oublie ce qui est sorti de la fenêtre.
    if (attempts.size > 500) attempts.clear();
    return done;
  }

  return { tick };
}

/** Lance la boucle (une seule à la fois : un tour ne chevauche jamais le suivant). */
function startVoiceTranscriber({ supabase, supabaseUrl, openaiKey, model, grokKey, grokBase, provider, intervalMs = 10000 }) {
  const sb = typeof supabase === 'function' ? supabase() : supabase;
  if (!sb || !(openaiKey || grokKey)) {
    console.log('[voice] auto-transcription OFF (Supabase, or no OPENAI_API_KEY / GROK_API_KEY)');
    return () => {};
  }
  const tr = createVoiceTranscriber({ sb, supabaseUrl, openaiKey, model, grokKey, grokBase, provider });
  voiceStatus.enabled = true;
  let running = false;
  const timer = setInterval(async () => {
    if (running) return;
    running = true;
    try {
      await tr.tick();
    } catch (e) {
      console.error('[voice] auto-transcription tick failed', e && e.message);
    } finally {
      running = false;
    }
  }, intervalMs);
  if (typeof timer.unref === 'function') timer.unref();
  console.log('[voice] auto-transcription ON');
  return () => clearInterval(timer);
}

module.exports = {
  isWhisperGhost,
  transcribeVoiceMessage,
  ownFolderPrefix,
  createVoiceTranscriber,
  startVoiceTranscriber,
  voiceStatus,
};
