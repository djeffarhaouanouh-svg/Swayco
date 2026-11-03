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
const UUID_RE = /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;

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
  fetchImpl = fetch,
}) {
  if (!UUID_RE.test(String(messageId || ''))) {
    return { status: 400, body: { error: 'invalid_message' } };
  }
  if (!sb || !openaiKey) {
    return { status: 503, body: { error: 'transcription_not_configured' } };
  }

  const { data: msg, error } = await sb
    .from('messages')
    .select('id, sender, audio_url, body')
    .eq('id', messageId)
    .maybeSingle();
  if (error) return { status: 502, body: { error: 'lookup_failed' } };
  if (!msg) return { status: 404, body: { error: 'not_found' } };
  if (String(msg.sender) !== String(uid)) {
    return { status: 403, body: { error: 'not_yours' } };
  }
  const url = String(msg.audio_url || '');
  if (!url.startsWith(ownFolderPrefix(supabaseUrl, uid))) {
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

  let text = '';
  try {
    const form = new FormData();
    form.append('file', new Blob([audio], { type: 'audio/mp4' }), 'voice.m4a');
    form.append('model', model);
    if (validTag(lang)) form.append('language', lang);
    form.append('response_format', 'json');
    const r = await fetchImpl('https://api.openai.com/v1/audio/transcriptions', {
      method: 'POST',
      headers: { Authorization: `Bearer ${openaiKey}` },
      body: form,
    });
    const raw = await r.text();
    if (!r.ok) {
      console.error('[voice] stt error', r.status, raw.slice(0, 300));
      return { status: 502, body: { error: 'stt_error' } };
    }
    text = String(JSON.parse(raw).text || '').trim();
  } catch (e) {
    console.error('[voice] stt throw', e && e.message);
    return { status: 502, body: { error: 'stt_unreachable' } };
  }

  // Du silence ou une toux : Whisper invente parfois une phrase toute faite.
  // Sans aucune lettre, il n'y a rien à garder.
  if (!text || !/\p{L}/u.test(text)) {
    return { status: 200, body: { ok: true, empty: true } };
  }

  // Seulement si le texte n'est pas déjà là (deux appels en même temps).
  const { error: upErr } = await sb
    .from('messages')
    .update({ body: text, language: validTag(lang) ? lang : '' })
    .eq('id', messageId)
    .eq('body', '');
  if (upErr) return { status: 502, body: { error: 'update_failed' } };

  console.log(`[voice] transcribed ${messageId} lang=${lang || '?'} chars=${text.length}`);
  return { status: 200, body: { ok: true } };
}

module.exports = { transcribeVoiceMessage, ownFolderPrefix };
