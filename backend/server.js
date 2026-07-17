'use strict';

// LiveKit token API + optional Flutter web UI (folder ./web from Docker build).

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const express = require('express');
const multer = require('multer');
const cors = require('cors');
const dotenv = require('dotenv');
const { AccessToken } = require('livekit-server-sdk');
const { notifyUser } = require('./notify');
const { onlineNotif } = require('./nationalities');
const { track, ingestEvents, countryFromReq } = require('./analytics');
const {
  authUserId: stripeAuthUserId,
  createCheckoutSession,
  createPortalSession,
  verifyWebhook,
  handleEvent: handleStripeEvent,
} = require('./stripe');

dotenv.config();

const LIVEKIT_URL = process.env.LIVEKIT_URL?.trim();
const LIVEKIT_API_KEY = process.env.LIVEKIT_API_KEY?.trim();
const LIVEKIT_API_SECRET = process.env.LIVEKIT_API_SECRET?.trim();
const OPENAI_API_KEY = process.env.OPENAI_API_KEY?.trim();
/**
 * TEST (web-only, revert with the VAD/Whisper experiment): the non-streaming
 * STT model behind POST /translation/whisper. The OpenAI API does not serve the
 * `small` checkpoint — `whisper-1` (large-v2) is the only Whisper it hosts, and
 * it is what this test measures. Override with WHISPER_MODEL if that changes.
 */
const WHISPER_MODEL = process.env.WHISPER_MODEL?.trim() || 'whisper-1';
/** Set to `1` to enable source-language transcription (slightly more latency / cost). */
const OPENAI_TRANSLATION_TRANSCRIBE = process.env.OPENAI_TRANSLATION_TRANSCRIBE?.trim() === '1';
/** Set to `0` to disable input noise reduction (tiny CPU win; noisier mics). */
const OPENAI_TRANSLATION_NOISE_REDUCTION = process.env.OPENAI_TRANSLATION_NOISE_REDUCTION?.trim() !== '0';
/**
 * OpenAI server VAD threshold (0..1). Lower = more sensitive (whispers,
 * quiet speech). OpenAI's default is ~0.5. Unset → we omit the
 * turn_detection block entirely so OpenAI uses its own defaults
 * (current behavior). Set to e.g. 0.2 to make whispers trigger.
 */
const OPENAI_TRANSLATION_VAD_THRESHOLD = (() => {
  const raw = process.env.OPENAI_TRANSLATION_VAD_THRESHOLD;
  if (raw === undefined || raw.trim() === '') return null;
  const n = Number(raw);
  if (!Number.isFinite(n) || n < 0 || n > 1) return null;
  return n;
})();
/** Padding (ms) of audio before detected speech that is forwarded for translation. */
const OPENAI_TRANSLATION_VAD_PREFIX_MS = (() => {
  const n = Number(process.env.OPENAI_TRANSLATION_VAD_PREFIX_MS);
  return Number.isFinite(n) && n >= 0 ? n : 300;
})();
/** Silence (ms) after speech before OpenAI commits the utterance. */
const OPENAI_TRANSLATION_VAD_SILENCE_MS = (() => {
  const n = Number(process.env.OPENAI_TRANSLATION_VAD_SILENCE_MS);
  return Number.isFinite(n) && n >= 0 ? n : 400;
})();
/**
 * Set to `1` to forward the client-provided `inputLanguage` to OpenAI under
 * `audio.input.language`. Avoids the multi-minute warm-up where OpenAI has
 * to auto-detect the source language. Off by default in case the field
 * name is not accepted by the translation endpoint — flip on, test, flip
 * off if it breaks (no code revert needed).
 */
const OPENAI_TRANSLATION_PASS_INPUT_LANGUAGE =
  process.env.OPENAI_TRANSLATION_PASS_INPUT_LANGUAGE?.trim() === '1';
const PORT = Number(process.env.PORT || 8787);

/**
 * HMAC key for signing guest-invite links. A dedicated secret is best, but
 * we fall back to LIVEKIT_API_SECRET so the feature works with zero extra
 * config on existing deployments. Empty → guest invites are disabled.
 */
const INVITE_SIGNING_SECRET = (
  process.env.INVITE_SIGNING_SECRET || LIVEKIT_API_SECRET || ''
).trim();
/** Guest-call rooms carry this prefix — used to gate signature verification. */
const GUEST_ROOM_PREFIX = 'guest-';
/** How long an invite link stays valid after creation. */
const INVITE_TTL_MS = 24 * 60 * 60 * 1000;

// ── "X Japonaises en ligne" pull-notification broadcast ──────────────────────
// Shared secret that gates the manual trigger (POST /api/notify-online-broadcast
// with header `x-broadcast-secret`). Falls back to INVITE_SIGNING_SECRET so it
// works with zero extra config; empty → manual endpoint disabled.
const BROADCAST_SECRET = (
  process.env.BROADCAST_SECRET || INVITE_SIGNING_SECRET || ''
).trim();
// Minimum opposite-sex users online in a country before we bother notifying —
// "1 en ligne" reads as desperate, so default to 3.
const BROADCAST_MIN_COUNT = Number(process.env.BROADCAST_MIN_COUNT || 3);
// Presence window in seconds (matches the SQL default).
const BROADCAST_WINDOW_SECONDS = Number(process.env.BROADCAST_WINDOW_SECONDS || 300);
// Per-market auto-broadcast. France and Japan are ~8h apart, so a single
// server-clock schedule can't hit both at their own peak — each market fires at
// its OWN local peak hours (DST-correct via Intl) and only nudges recipients in
// that market's language. Hours are a CSV in the market's local time; empty
// disables that market's auto-fire (the manual endpoint still works for it).
function parseHours(raw, fallback) {
  return String(raw ?? fallback)
    .split(',')
    .map((h) => Number(h.trim()))
    .filter((h) => Number.isInteger(h) && h >= 0 && h <= 23);
}
const BROADCAST_MARKETS = [
  { lang: 'fr', tz: 'Europe/Paris', hours: parseHours(process.env.BROADCAST_HOURS_FR, '19,21') },
  { lang: 'ja', tz: 'Asia/Tokyo', hours: parseHours(process.env.BROADCAST_HOURS_JA, '20,22') },
];
// Current { hour, day } in a given IANA timezone — drives both the hour match
// and a once-per-local-hour fire guard. Returns null on a bad zone.
function localParts(tz) {
  try {
    const parts = new Intl.DateTimeFormat('en-CA', {
      timeZone: tz,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      hour12: false,
    }).formatToParts(new Date());
    const o = {};
    for (const p of parts) o[p.type] = p.value;
    return { hour: Number(o.hour) % 24, day: `${o.year}-${o.month}-${o.day}` };
  } catch (e) {
    return null;
  }
}

/** Supabase service-role client — backs the guest-invite short-code store.
 *  Same env pair already used by notify.js / analytics.js. */
const SUPABASE_URL = process.env.SUPABASE_URL?.trim();
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY?.trim();
let _supabase;
function supabase() {
  if (_supabase !== undefined) return _supabase;
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    _supabase = null;
    return null;
  }
  const { createClient } = require('@supabase/supabase-js');
  _supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });
  return _supabase;
}

/** Short, URL-safe invite code (9 base62 chars). */
function newInviteCode() {
  const alphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  const bytes = crypto.randomBytes(9);
  let s = '';
  for (let i = 0; i < 9; i += 1) s += alphabet[bytes[i] % 62];
  return s;
}

const OPENAI_TRANSLATION_CLIENT_SECRETS =
  'https://api.openai.com/v1/realtime/translations/client_secrets';
const OPENAI_TRANSLATION_CALLS = 'https://api.openai.com/v1/realtime/translations/calls';

// ─── Text translation provider (POST /translation/text) ───────────────────
// Any OpenAI-compatible chat/completions endpoint.
//
// This is the one setting that decides whether the bill grows with success: the
// model is the ONLY cloud cost of a call, since speech recognition and speech
// synthesis both run on the device. Measured at 1000 one-hour calls/day, the
// same route spans 351 $/month to 5945 $/month depending on this block alone.
//
// The chosen engine takes over AS SOON AS ITS KEY EXISTS, and not before: until
// then the incumbent keeps serving. Pointing at a new host without its key would
// mean 401 on every sentence — no translation at all in every live call — so the
// key is what arms the switch, and it is the only variable that has to be set.
// Each part stays overridable on its own for a one-variable rollback.
// The host is public knowledge and worth stating — it is in the EU, which is the
// point of picking it. WHICH model runs there is not: that one stays out of the
// source and comes from TRANSLATE_MODEL. So the switch needs BOTH its key and its
// name; a key alone can never arm a half-configured route.
const _translateKey = process.env.TRANSLATE_KEY?.trim();
const _translateModel = process.env.TRANSLATE_MODEL?.trim();
const _translateSwitched = !!(_translateKey && _translateModel);
const TRANSLATE_KEY = _translateSwitched ? _translateKey : OPENAI_API_KEY;
const TRANSLATE_BASE = (
  process.env.TRANSLATE_BASE?.trim() ||
  (_translateSwitched
    ? 'https://oai.endpoints.kepler.ai.cloud.ovh.net/v1' // OVHcloud AI Endpoints, Gravelines
    : 'https://api.openai.com/v1')
).replace(/\/$/, '');
const TRANSLATE_MODEL = _translateSwitched ? _translateModel : 'gpt-4.1';
// Sent only when set — an engine that does not reason answers 400 to the field,
// so the incumbent must not carry it. On one that does, it is the biggest lever
// left: measured, it cuts the BILLED output from ~270 tokens to ~51 for the same
// sentence, because the thinking we pay for is never shown to anyone. The trade
// was measured too, on 40 real sentences: translating INTO a gender-marking
// language (fr) it costs ~2 slips per 40 — a masculine agreement, a clumsy turn,
// both still understood; INTO one that barely marks gender (ja) it costs nothing.
const TRANSLATE_EFFORT =
  process.env.TRANSLATE_REASONING_EFFORT?.trim() || (_translateSwitched ? 'low' : '');
// `cache_control` is an OpenAI extension; other gateways reject the array form.
const TRANSLATE_IS_OPENAI = TRANSLATE_BASE.includes('api.openai.com');

/**
 * Resolve a gender hedge the model produced anyway: "venu(e)", "tout(e) seul(e)",
 * "nouveau/nouvelle". The prompt forbids these, and the big models obey — but a
 * small one slips ~1 time in 20 (measured), and this is not cosmetic: the
 * translation is SPOKEN, so the TTS reads "parenthèse e" and "slash" out loud.
 *
 * We know the genders, so resolve it deterministically here rather than pay 25×
 * for a model that never hedges. A clause about "je" is the speaker's, one about
 * "tu" is the addressee's; when it is ambiguous or the gender is unknown we
 * leave the text untouched rather than guess wrong.
 */
function resolveGenderHedges(text, authorGender, peerGender) {
  if (!text || (!text.includes('(') && !text.includes('/'))) return text;
  const addressee = /\b(tu|te|toi)\b|\bt['’]/i.test(text);
  const speaker = /\b(je|me|moi)\b|\bj['’]/i.test(text);
  let g = '';
  if (addressee && !speaker) g = peerGender;
  else if (speaker && !addressee) g = authorGender;
  else g = authorGender || peerGender;
  // Unknown gender: fall back to masculine rather than leaving the hedge in. Not
  // a preference — measured, every model already answers "Je suis crevé" / "Tu es
  // nouveau ?" when told nothing, so this changes no output. What it changes is
  // that the net now resolves EVERY hedge, instead of letting a "content(e)"
  // through to be read aloud, parenthesis and all, on the one profile that never
  // filled its gender in.
  if (g !== 'm' && g !== 'f') g = 'm';
  let out = text.replace(/(\p{L}+)\((\p{L}{1,3})\)/gu, (_, w, suf) => (g === 'f' ? w + suf : w));
  // Slashed pairs, but never inside a URL — the prompt promises those verbatim.
  if (!/https?:|www\.|\/\//i.test(out)) {
    out = out.replace(/(\p{L}{3,})\/(\p{L}{3,})/gu, (_, a, b) => (g === 'f' ? b : a));
  }
  return out;
}

// ElevenLabs — voice messages (Scribe STT) + voice dubbing (TTS).
const ELEVENLABS_API_KEY = process.env.ELEVENLABS_API_KEY?.trim();
const ELEVENLABS_STT_MODEL =
  (process.env.ELEVENLABS_STT_MODEL?.trim() || 'scribe_v1');
const ELEVENLABS_STT_URL = 'https://api.elevenlabs.io/v1/speech-to-text';
const ELEVENLABS_TTS_MODEL =
  (process.env.ELEVENLABS_TTS_MODEL?.trim() || 'eleven_flash_v2_5');
/** Voice id used when the sender has not enrolled a cloned voice
 *  (i.e. Plus / Pro tiers, and Ultra users who have not yet recorded
 *  their sample). Defaults to a generic multilingual ElevenLabs voice. */
const ELEVENLABS_DEFAULT_VOICE_ID =
  (process.env.ELEVENLABS_DEFAULT_VOICE_ID?.trim() || '21m00Tcm4TlvDq8ikWAM');
// ─── Grok (xAI) — TEST translation pipeline (STT → translate → TTS) ──────
// Throwaway test path: VAD on the app captures one utterance, posts the audio
// here, and we run it fully through Grok. OpenAI/ElevenLabs paths are untouched.
// xAI is OpenAI-compatible for /chat/completions and exposes /v1/stt + /v1/tts.
const GROK_API_KEY = process.env.GROK_API_KEY?.trim();
const GROK_BASE = (process.env.GROK_BASE?.trim() || 'https://api.x.ai/v1').replace(/\/$/, '');
// Valid chat model ids (June 2026): grok-4.3, grok-4.20-*. `grok-3-mini`
// no longer exists → a bad default here 404s the translate step (502 to app).
const GROK_TRANSLATE_MODEL = (process.env.GROK_TRANSLATE_MODEL?.trim() || 'grok-4.20-0309-non-reasoning');
/** TTS model id — optional; only sent if set (the /v1/tts endpoint accepts
 *  text/voice_id/language without a model on most accounts). */
const GROK_TTS_MODEL = process.env.GROK_TTS_MODEL?.trim() || '';

// Public names of the utterance pipeline. The client only knows the `voice`
// spelling; the `grok` ones are answered for app builds already in the stores.
const VOICE_HTTP_PATHS = ['/translation/voice', '/translation/grok'];
const VOICE_STT_WS_PATHS = ['/translation/voice/stt', '/translation/grok/stt'];
/** One of: ara, eve, leo, rex, sal. */
const GROK_TTS_VOICE = (process.env.GROK_TTS_VOICE?.trim() || 'eve');
/** Realtime STT WebSocket base — derived from GROK_BASE (https→wss) unless
 *  overridden. e.g. https://api.x.ai/v1 → wss://api.x.ai/v1 (endpoint: /stt). */
const GROK_WS_BASE =
  (process.env.GROK_WS_BASE?.trim() || GROK_BASE.replace(/^http/i, 'ws'));

const { featuresFor, normalizeTier } = require('./tiers');
/** Hard cap on the multipart audio body. 60s of AAC ≈ ~1MB; we leave
 *  generous headroom for richer codecs / longer clips while still
 *  refusing pathological uploads. */
const VOICE_UPLOAD_MAX_BYTES = 8 * 1024 * 1024;
/** Bucket name created by 0022_voice_messages.sql. */
const VOICE_STORAGE_BUCKET = 'voice-messages';

const voiceUpload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: VOICE_UPLOAD_MAX_BYTES, files: 1 },
});

const webPath = path.join(__dirname, 'web');
const webIndex = path.join(webPath, 'index.html');
const hasWebUi = fs.existsSync(webIndex);

// Static legal site (Terms / Privacy / Help) lives alongside the
// Flutter web bundle. The Flutter app's Settings buttons link to
// /terms, /privacy, /help — those routes must serve the HTML from
// this folder, NOT fall through to the Flutter SPA fallback.
const legalPath = path.join(__dirname, 'legal-site');
const hasLegalSite = fs.existsSync(path.join(legalPath, 'terms.html'));


function assertEnv() {
  const missing = [];
  if (!LIVEKIT_URL) missing.push('LIVEKIT_URL');
  if (!LIVEKIT_API_KEY) missing.push('LIVEKIT_API_KEY');
  if (!LIVEKIT_API_SECRET) missing.push('LIVEKIT_API_SECRET');
  if (missing.length) {
    throw new Error(`Missing env: ${missing.join(', ')}`);
  }
}

function assertOpenAI() {
  if (!OPENAI_API_KEY) {
    throw new Error('Missing OPENAI_API_KEY');
  }
}

function primaryLanguageTag(bcp47) {
  const s = typeof bcp47 === 'string' ? bcp47.trim().toLowerCase() : '';
  if (!s) return '';
  const i = s.indexOf('-');
  return i === -1 ? s : s.slice(0, i);
}

function isReasonableLanguageTag(tag) {
  return typeof tag === 'string' && /^[a-z]{2,3}(-[a-z0-9]{1,8})?$/.test(tag);
}

const ROOM_RE = /^[a-zA-Z0-9_-]{3,64}$/;
const IDENTITY_RE = /^[a-zA-Z0-9_.:-]{1,128}$/;

function sanitizeRoomName(name) {
  if (typeof name !== 'string' || !ROOM_RE.test(name)) {
    return null;
  }
  return name;
}

function sanitizeIdentity(id) {
  if (typeof id !== 'string' || !IDENTITY_RE.test(id)) {
    return null;
  }
  return id;
}

/** HMAC-sign a `<room>.<expiryMs>` tuple → URL-safe base64 string. */
function signInvite(room, expStr) {
  return crypto
    .createHmac('sha256', INVITE_SIGNING_SECRET)
    .update(`${room}.${expStr}`)
    .digest('base64url');
}

/**
 * Verify a guest-invite signature in constant time and reject expired links.
 * `exp` / `sig` come straight from the request — treat both as untrusted.
 */
function verifyInvite(room, exp, sig) {
  if (!INVITE_SIGNING_SECRET) return false;
  if (typeof sig !== 'string' || !sig) return false;
  const expStr = String(exp);
  const expNum = Number(expStr);
  if (!Number.isFinite(expNum) || expNum < Date.now()) return false;
  const expected = signInvite(room, expStr);
  const a = Buffer.from(sig);
  const b = Buffer.from(expected);
  if (a.length !== b.length) return false;
  return crypto.timingSafeEqual(a, b);
}

// ── Rate limiting ─────────────────────────────────────────────────────────
// Lightweight in-memory limiter (no external deps). Per-process, so it's a
// first line of defense against request floods / cost-abuse, not a distributed
// quota. For multi-instance deployments, move the bucket store to Redis later.
const _rlBuckets = new Map(); // key -> { count, resetAt }

function _clientKey(req) {
  const xff = req.headers['x-forwarded-for'];
  return (
    (typeof xff === 'string' && xff.split(',')[0].trim()) ||
    req.socket?.remoteAddress ||
    'unknown'
  );
}

function rateLimit({ name = 'rl', windowMs = 60000, max = 120 }) {
  return (req, res, next) => {
    const now = Date.now();
    const key = `${name}:${_clientKey(req)}`;
    let b = _rlBuckets.get(key);
    if (!b || now >= b.resetAt) {
      b = { count: 0, resetAt: now + windowMs };
      _rlBuckets.set(key, b);
    }
    b.count += 1;
    if (b.count > max) {
      const retry = Math.max(1, Math.ceil((b.resetAt - now) / 1000));
      res.set('Retry-After', String(retry));
      return res.status(429).json({ error: 'rate_limited', retryAfter: retry });
    }
    return next();
  };
}

// Drop expired buckets every minute so the Map can't grow unbounded.
setInterval(() => {
  const now = Date.now();
  for (const [k, b] of _rlBuckets) {
    if (now >= b.resetAt) _rlBuckets.delete(k);
  }
}, 60000).unref();

// Heavy / cost-bearing endpoints (OpenAI / ElevenLabs) — tight per-IP caps.
const _limTight = rateLimit({ name: 'ai', windowMs: 60000, max: 30 });
const _limText = rateLimit({ name: 'text', windowMs: 60000, max: 90 });
const _limClone = rateLimit({ name: 'clone', windowMs: 60000, max: 6 });
// Cheaper endpoints (invites, push) — looser caps.
const _limLite = rateLimit({ name: 'lite', windowMs: 60000, max: 120 });
// LiveKit token minting: zero OpenAI/ElevenLabs cost, and shared-IP
// households (two testers/devices on the same wifi) legitimately burst this
// on retries/reconnects — give it its own high ceiling instead of sharing
// the "lite" bucket with invite/notify traffic.
const _limToken = rateLimit({ name: 'token', windowMs: 60000, max: 600 });

const app = express();
app.use(cors());

// Global flood guard. Skips the Stripe webhook, which legitimately bursts from
// a handful of Stripe IPs and must never be rate-limited (dropped = billing
// desync).
const _limGlobal = rateLimit({ name: 'global', windowMs: 60000, max: 600 });
app.use((req, res, next) => {
  if (req.path === '/api/stripe/webhook') return next();
  return _limGlobal(req, res, next);
});

// Raw SDP body (not JSON) — must run before express.json().
app.post(
  '/translation/realtime/calls',
  _limTight,
  express.text({ limit: '1mb', type: '*/*' }),
  async (req, res) => {
    const auth = req.headers.authorization;
    const m = typeof auth === 'string' ? /^Bearer\s+(.+)$/i.exec(auth.trim()) : null;
    const clientSecret = m ? m[1] : '';
    const sdpOffer = typeof req.body === 'string' ? req.body : '';
    if (!clientSecret || !sdpOffer.trim()) {
      return res.status(400).json({ error: 'missing_client_secret_or_sdp' });
    }
    try {
      const r = await fetch(OPENAI_TRANSLATION_CALLS, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${clientSecret}`,
          'Content-Type': 'application/sdp',
        },
        body: sdpOffer,
      });
      const answer = await r.text();
      return res.status(r.status).type('application/sdp').send(answer);
    } catch (e) {
      // eslint-disable-next-line no-console
      console.error('translation calls proxy', e);
      return res.status(502).json({ error: 'openai_unreachable' });
    }
  },
);

// Stripe webhook — needs the raw body buffer to verify the signature.
// MUST run before `express.json` below, otherwise the body gets parsed
// to a JS object and the HMAC over the original bytes fails.
app.post(
  '/api/stripe/webhook',
  express.raw({ type: 'application/json' }),
  async (req, res) => {
    const sig = req.headers['stripe-signature'];
    let event;
    try {
      event = verifyWebhook(req.body, sig);
    } catch (e) {
      // eslint-disable-next-line no-console
      console.error('[stripe webhook] signature failed:', e.message);
      return res.status(400).send(`Webhook Error: ${e.message}`);
    }
    try {
      await handleStripeEvent(event);
      return res.json({ received: true });
    } catch (e) {
      // eslint-disable-next-line no-console
      console.error('[stripe webhook] handler failed:', e);
      // Return 500 so Stripe retries.
      return res.status(500).json({ error: 'handler_failed' });
    }
  },
);

// Analytics ingest — the app POSTs a batch of events here. Its own JSON
// parser (larger limit than the 16kb global below) so a full 50-event
// batch always fits. Registered before the global parser so this limit
// wins for this route.
app.post(
  '/api/events',
  express.json({ limit: '64kb' }),
  async (req, res) => {
    // Auth is optional: guests (invite-link callers, no Supabase account)
    // still produce analytics. A valid Bearer token → events are
    // attributed to that user; otherwise user_id stays null.
    const uid = await stripeAuthUserId(req);
    const events = Array.isArray(req.body?.events) ? req.body.events : [];
    try {
      const out = await ingestEvents(uid, events, countryFromReq(req));
      return res.json(out);
    } catch (e) {
      // eslint-disable-next-line no-console
      console.error('/api/events error', e);
      return res.status(500).json({ error: 'ingest_failed' });
    }
  },
);

app.use(express.json({ limit: '16kb' }));

app.get('/health', (_req, res) => {
  res.json({ ok: true, webUi: hasWebUi });
});

app.get('/api', (_req, res) => {
  res.json({
    service: 'livekit-translate',
    webUi: hasWebUi,
    routes: {
      health: 'GET /health',
      livekitToken: 'POST /livekit/token',
      translationSession: 'POST /translation/realtime/session',
      translationCalls: 'POST /translation/realtime/calls (SDP relay, Authorization: Bearer ephemeral)',
      translationVoice: 'POST /translation/voice (multipart audio → STT/translate/TTS)',
    },
  });
});

/**
 * POST /livekit/token
 * Body: { roomName, identity, displayName?, sourceLang?, targetLang? }
 * Participant metadata (for a future OpenAI Realtime bridge):
 * - sourceLang: this participant's spoken language (BCP-47). Translate the remote participant's speech into this language for this participant to hear.
 * - targetLang: the remote participant's spoken language (BCP-47). Translate this participant's speech into this language for the remote participant to hear.
 */
app.post('/livekit/token', _limToken, async (req, res) => {
  try {
    assertEnv();
  } catch (e) {
    return res.status(500).json({ error: 'server_misconfigured' });
  }

  const { roomName, identity, displayName, sourceLang, targetLang } = req.body || {};
  const room = sanitizeRoomName(roomName);
  const id = sanitizeIdentity(identity);
  if (!room || !id) {
    return res.status(400).json({ error: 'invalid_room_or_identity' });
  }

  // Guest-call rooms are joinable without a Supabase account, so they must
  // carry a valid, unexpired HMAC signature minted by POST /invite/create.
  // Regular `call-*` / `live-*` rooms are unaffected.
  if (room.startsWith(GUEST_ROOM_PREFIX)) {
    const { inviteSig, inviteExp } = req.body || {};
    if (!verifyInvite(room, inviteExp, inviteSig)) {
      return res.status(403).json({ error: 'invalid_or_expired_invite' });
    }
  }

  const name =
    typeof displayName === 'string' && displayName.length > 0 && displayName.length <= 64
      ? displayName.slice(0, 64)
      : undefined;

  const at = new AccessToken(LIVEKIT_API_KEY, LIVEKIT_API_SECRET, {
    identity: id,
    name,
    metadata: JSON.stringify({
      sourceLang: typeof sourceLang === 'string' ? sourceLang.slice(0, 16) : '',
      targetLang: typeof targetLang === 'string' ? targetLang.slice(0, 16) : '',
    }),
  });

  at.addGrant({
    roomJoin: true,
    room,
    canPublish: true,
    canSubscribe: true,
  });

  const token = await at.toJwt();

  return res.json({
    url: LIVEKIT_URL,
    token,
    roomName: room,
  });
});

/**
 * POST /invite/create
 * Auth: Authorization: Bearer <Supabase JWT> (the host must be signed in).
 * Mints a one-off guest-call room + a signed, time-limited invite. The host
 * shares the link; whoever opens it can join that room with no account.
 * Returns: { roomName, exp, sig, ttlMs }
 */
app.post('/invite/create', _limLite, async (req, res) => {
  const uid = await stripeAuthUserId(req);
  if (!uid) return res.status(401).json({ error: 'unauthenticated' });
  if (!INVITE_SIGNING_SECRET) {
    return res.status(500).json({ error: 'invite_signing_unconfigured' });
  }
  // 'guest-' + 24 hex chars = 30 chars — well inside the 3-64 room limit.
  const room = GUEST_ROOM_PREFIX + crypto.randomBytes(12).toString('hex');
  const exp = Date.now() + INVITE_TTL_MS;
  const sig = signInvite(room, String(exp));

  // Persist a short code → invite mapping so the shared link can be a
  // tiny `…/i/<code>` rather than carrying the room + 43-char signature
  // inline. Best-effort: if Supabase isn't configured the client falls
  // back to the long inline link.
  let code = null;
  const sb = supabase();
  if (sb) {
    try {
      code = newInviteCode();
      const { error } = await sb
        .from('guest_invites')
        .insert({ code, room, exp, sig });
      if (error) {
        console.error('[invite] store failed:', error.message);
        code = null;
      }
      // Opportunistic cleanup of expired rows — keeps the table tiny.
      sb.from('guest_invites')
        .delete()
        .lt('exp', Date.now())
        .then(() => {}, () => {});
    } catch (e) {
      console.error('[invite] store exception:', e);
      code = null;
    }
  }
  return res.json({ roomName: room, exp, sig, ttlMs: INVITE_TTL_MS, code });
});

/**
 * GET /invite/resolve?code=<code>
 * Public — resolves a short invite code back to { roomName, sig, exp } so
 * a `…/i/<code>` link can be opened with no account. 404 unknown,
 * 410 expired.
 */
app.get('/invite/resolve', async (req, res) => {
  const code = String(req.query.code || '').trim();
  if (!code) return res.status(400).json({ error: 'missing_code' });
  const sb = supabase();
  if (!sb) return res.status(500).json({ error: 'store_unconfigured' });
  try {
    const { data, error } = await sb
      .from('guest_invites')
      .select('room, exp, sig')
      .eq('code', code)
      .maybeSingle();
    if (error || !data) return res.status(404).json({ error: 'not_found' });
    if (Number(data.exp) < Date.now()) {
      return res.status(410).json({ error: 'expired' });
    }
    return res.json({
      roomName: data.room,
      sig: data.sig,
      exp: String(data.exp),
    });
  } catch (e) {
    console.error('[invite] resolve exception:', e);
    return res.status(500).json({ error: 'resolve_failed' });
  }
});

/**
 * POST /translation/realtime/session
 * Body: { outputLanguage: "fr", inputLanguage?: "en" }  (BCP-47; primary subtag is used)
 * Proxies OpenAI Realtime Translation client_secrets (short-lived key for WebRTC).
 */
app.post('/translation/realtime/session', _limTight, async (req, res) => {
  try {
    assertOpenAI();
  } catch (e) {
    return res.status(500).json({ error: 'openai_misconfigured' });
  }

  const raw = req.body?.outputLanguage;
  const tag = primaryLanguageTag(raw);
  if (!tag || !isReasonableLanguageTag(tag)) {
    return res.status(400).json({ error: 'invalid_output_language' });
  }

  // Optional client-provided source language — forwarded only if the env
  // gate is on. Validated independently so a malformed value cannot poison
  // the request.
  const inputTagCandidate = primaryLanguageTag(req.body?.inputLanguage);
  const inputTag =
    isReasonableLanguageTag(inputTagCandidate) ? inputTagCandidate : null;

  // Credit gate: an authenticated user must have live-translation credit left
  // before we mint an OpenAI session (each session is billable). Guests (no
  // Supabase JWT) pass through and are bounded by the rate limiter above. We
  // only GATE here — the client still owns debiting / refilling the balance.
  // Fail-open on any lookup error so a flaky auth/DB never kills translation.
  try {
    const uid = await stripeAuthUserId(req);
    if (uid) {
      const sb = supabase();
      if (sb) {
        const { data: prof } = await sb
          .from('profiles')
          .select('subscription_tier, credits_seconds, credits_reset_at')
          .eq('id', uid)
          .maybeSingle();
        if (prof) {
          const tier = normalizeTier(prof.subscription_tier);
          const allotment = featuresFor(tier).monthlySeconds;
          const resetAt = prof.credits_reset_at
            ? new Date(prof.credits_reset_at).getTime()
            : 0;
          // If the refill window has elapsed the balance is effectively full
          // (the client tops it up lazily); otherwise use the stored balance.
          const available =
            !resetAt || Date.now() >= resetAt
              ? allotment
              : Number(prof.credits_seconds) || 0;
          if (available <= 0) {
            return res.status(402).json({ error: 'out_of_credits' });
          }
        }
      }
    }
  } catch (e) {
    // eslint-disable-next-line no-console
    console.error('[xlate-session] credit gate error', e);
  }

  try {
    const audioInput = {};
    if (OPENAI_TRANSLATION_TRANSCRIBE) {
      audioInput.transcription = { model: 'gpt-realtime-whisper' };
    }
    if (OPENAI_TRANSLATION_NOISE_REDUCTION) {
      audioInput.noise_reduction = { type: 'near_field' };
    }
    if (OPENAI_TRANSLATION_VAD_THRESHOLD !== null) {
      audioInput.turn_detection = {
        type: 'server_vad',
        threshold: OPENAI_TRANSLATION_VAD_THRESHOLD,
        prefix_padding_ms: OPENAI_TRANSLATION_VAD_PREFIX_MS,
        silence_duration_ms: OPENAI_TRANSLATION_VAD_SILENCE_MS,
      };
    }
    if (OPENAI_TRANSLATION_PASS_INPUT_LANGUAGE && inputTag) {
      audioInput.language = inputTag;
    }

    const sessionPayload = {
      model: 'gpt-realtime-translate',
      audio: {
        ...(Object.keys(audioInput).length > 0 ? { input: audioInput } : {}),
        output: { language: tag },
      },
    };
    const r = await fetch(OPENAI_TRANSLATION_CLIENT_SECRETS, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${OPENAI_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        session: sessionPayload,
      }),
    });
    const text = await r.text();
    let parsed;
    try {
      parsed = JSON.parse(text);
    } catch (_) {
      // eslint-disable-next-line no-console
      console.error('[xlate-session] non-JSON response', r.status, text.slice(0, 300));
      return res.status(502).json({ error: 'openai_bad_response', body: text.slice(0, 200) });
    }
    if (r.status >= 400) {
      // Surface the full OpenAI error body in server logs so we can see
      // exactly why the key was rejected (revoked, quota, model mismatch…).
      // eslint-disable-next-line no-console
      console.error('[xlate-session] OpenAI error', r.status, JSON.stringify(parsed).slice(0, 600));
      track({
        event: 'translation_session_failed',
        lang_to: tag,
        lang_from: inputTag || undefined,
        props: { status: r.status },
      });
    } else {
      // One translation session minted = the unit OpenAI Realtime bills
      // on. The dashboard turns the count + matching call durations into
      // the per-minute cost figure.
      track({
        event: 'translation_session',
        lang_to: tag,
        lang_from: inputTag || undefined,
        props: { model: 'gpt-realtime-translate' },
      });
    }
    return res.status(r.status).json(parsed);
  } catch (e) {
    // eslint-disable-next-line no-console
    console.error('translation session', e);
    return res.status(502).json({ error: 'openai_unreachable' });
  }
});

/**
 * POST /translation/text
 * Body: {
 *   text: "...",                       // message to translate (required)
 *   from?: "fr",                       // BCP-47 source primary subtag (optional)
 *   to: "en",                          // BCP-47 target primary subtag (required)
 *   history?: [                        // last N messages in the thread, oldest→newest
 *     { author: "me"|"peer", text: "...", lang?: "fr" }
 *   ],
 *   context?: {
 *     authorName?: string,             // sender display name
 *     authorGender?: "m"|"f"|"x",
 *     authorLang?: string,             // sender's native language
 *     peerName?: string,               // reader display name
 *     peerGender?: "m"|"f"|"x",
 *     peerLang?: string,               // reader's native language
 *     relationship?: string            // "couple"|"friends"|"dating"|"business"|...
 *   }
 * }
 * Returns: { translated: "..." }
 *
 * Context-aware message translation. Uses gpt-4.1 (full model) with the last
 * messages of the thread + speaker profiles so pronouns, in-jokes, gender
 * agreement, register (tu/vous) and ongoing references resolve correctly.
 * The system prompt is wrapped with `cache_control` so OpenAI caches it
 * across requests in the same 5-min window (~-50% on input tokens).
 */
app.post('/translation/text', _limText, async (req, res) => {
  try {
    assertOpenAI();
  } catch (e) {
    return res.status(500).json({ error: 'openai_misconfigured' });
  }
  const rawText = typeof req.body?.text === 'string' ? req.body.text : '';
  const text = rawText.trim().slice(0, 4000);
  const from = primaryLanguageTag(req.body?.from);
  const to = primaryLanguageTag(req.body?.to);
  if (!text || !isReasonableLanguageTag(to)) {
    return res.status(400).json({ error: 'invalid_input' });
  }
  if (from && from === to) {
    return res.json({ translated: text });
  }
  // Set by the call path: this is a raw on-device STT transcript, not something
  // anyone typed. It both arms the repair rule and drops the chat-only rules —
  // see the prompt below.
  const isSpeech = req.body?.speech === true;

  // Sanitise the supplied history. Cap at last 10 messages, 400 chars each,
  // so a hostile or buggy client can't blow up the prompt size.
  const historyIn = Array.isArray(req.body?.history) ? req.body.history : [];
  const history = historyIn
    .slice(-10)
    .map((h) => {
      const author = h?.author === 'peer' ? 'peer' : 'me';
      const t = typeof h?.text === 'string' ? h.text.trim().slice(0, 400) : '';
      return t ? { author, text: t } : null;
    })
    .filter(Boolean);

  const ctx = (req.body?.context && typeof req.body.context === 'object')
    ? req.body.context
    : {};
  const safeStr = (v, max = 60) =>
    typeof v === 'string' ? v.trim().slice(0, max) : '';
  const safeGender = (v) =>
    v === 'm' || v === 'f' || v === 'x' ? v : '';
  const authorName = safeStr(ctx.authorName);
  const authorGender = safeGender(ctx.authorGender);
  const authorLang = primaryLanguageTag(ctx.authorLang);
  const peerName = safeStr(ctx.peerName);
  const peerGender = safeGender(ctx.peerGender);
  const peerLang = primaryLanguageTag(ctx.peerLang);
  const relationship = safeStr(ctx.relationship, 30);

  // Cacheable system prompt — kept generic and identity-free so OpenAI's
  // prompt cache hits across all users of the app. The per-conversation
  // context goes in the user turn so we don't bust the cache.
  const sys =
    `You are a professional chat-message translator. Translate the LAST ` +
    `message of the supplied conversation into the target language only. ` +
    `The conversation history is provided as context — do NOT retranslate it.\n\n` +
    `Rules:\n` +
    `- Resolve pronouns and elliptical references using the history.\n` +
    `- Match the register (formal / casual / flirty / slang) that a native ` +
    `speaker of the target language would naturally use given the relationship.\n` +
    `- When the relationship is not specified, DEFAULT to an informal, friendly ` +
    `register — tutoiement: "tu" in French, "du" in German, informal "you", etc. ` +
    `This is a casual social app where people meet and chat, never a formal one. ` +
    `Keep ONE register for the whole conversation so it never flips between ` +
    `"tu" and "vous" from one message to the next.\n` +
    `- Say it the way a native speaker actually would, not word-for-word. Drop ` +
    `literal politeness nouns ("優しい方" → "tu es gentille", not "tu es une ` +
    `personne gentille"; Korean 님, etc.) and reorder to sound natural.\n` +
    `- For gendered languages, use the correct grammatical gender for the ` +
    `speaker and the addressee.\n` +
    `- NEVER hedge with a parenthetical or slashed alternative: "content(e)", ` +
    `"nouveau/nouvelle", "allé(e) seul(e)" are forbidden. This text is read ` +
    `ALOUD by a speech voice, which pronounces the parenthesis and the slash. ` +
    `Pick the single most likely form and commit to it.\n` +
    `- When the context marks the input as speech recognition, treat it as a ` +
    `possibly-misheard transcript: expect phonetic errors and missing ` +
    `punctuation. Translate what the speaker MEANT. A word that makes no sense ` +
    `where it stands is far more likely a recognition error than a real ` +
    `utterance, so repair it from the surrounding context instead of ` +
    `translating the mis-hearing literally.\n` +
    // Chat only. Speech has no emoji, no @mention, no URL and no punctuation to
    // preserve — nobody pronounces an at-sign — so these two lines are ~31
    // tokens billed on every single spoken sentence for nothing. The system
    // prompt is ~80% of a call's input tokens, and gateways without a prompt
    // cache re-charge every one of them per sentence.
    (isSpeech
      ? ''
      : `- Preserve emojis, proper nouns, @mentions, #hashtags and URLs verbatim.\n` +
        `- Keep punctuation, capitalisation and message length close to the original.\n`) +
    `- If a phrase was already translated earlier in the conversation, ` +
    `reuse the same wording for consistency.\n` +
    `- If the last message is already in the target language, return it unchanged.\n` +
    `- Reply with the translated text ONLY — no quotes, no notes, no language tags, ` +
    `no markdown fences.`;

  const contextLines = [];
  if (from) contextLines.push(`Source language: ${from}`);
  contextLines.push(`Target language: ${to}`);
  // Set by the call path: the text is a raw on-device STT transcript, not
  // something the user typed. Arms the repair rule in the system prompt — chat
  // messages must NOT claim this, they are typed and mean exactly what they say.
  if (req.body?.speech === true) {
    contextLines.push(
      'Input: speech recognition (raw transcript — expect phonetic errors and no punctuation)',
    );
  }
  if (authorName || authorGender || authorLang) {
    contextLines.push(
      `Sender${authorName ? ` (${authorName})` : ''}: ` +
        [authorGender && `gender=${authorGender}`, authorLang && `native=${authorLang}`]
          .filter(Boolean)
          .join(', '),
    );
  }
  if (peerName || peerGender || peerLang) {
    contextLines.push(
      `Reader${peerName ? ` (${peerName})` : ''}: ` +
        [peerGender && `gender=${peerGender}`, peerLang && `native=${peerLang}`]
          .filter(Boolean)
          .join(', '),
    );
  }
  if (relationship) contextLines.push(`Relationship: ${relationship}`);

  const historyBlock = history.length
    ? '\n\n[Conversation history, oldest→newest]\n' +
      history
        .map((h) => `${h.author === 'me' ? 'Sender' : 'Reader'}: ${h.text}`)
        .join('\n')
    : '';

  const userMsg =
    `[Context]\n${contextLines.join('\n')}` +
    historyBlock +
    `\n\n[Last message to translate — translate THIS one only]\n${text}`;

  try {
    const r = await fetch(`${TRANSLATE_BASE}/chat/completions`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${TRANSLATE_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        // Set by TRANSLATE_MODEL — see the provider block near the top. Measured
        // on the same 20 real sentences with this exact prompt: the large
        // engines never hedge and read 明日は早いから寝るね correctly, while the
        // small ones hedge about 1 time in 20 ("T'es venu(e) tout(e) seul(e)")
        // and can invert that sentence's meaning. Hence resolveGenderHedges()
        // below, and hence a variable rather than a hard-coded name: the trade
        // between the two is a business call, remade without touching this file.
        model: TRANSLATE_MODEL,
        ...(TRANSLATE_EFFORT ? { reasoning_effort: TRANSLATE_EFFORT } : {}),
        messages: [
          {
            role: 'system',
            // cache_control is an OpenAI extension: the array form is rejected
            // elsewhere, and other gateways cache automatically anyway.
            content: TRANSLATE_IS_OPENAI
              ? [{ type: 'text', text: sys, cache_control: { type: 'ephemeral' } }]
              : sys,
          },
          { role: 'user', content: userMsg },
        ],
        temperature: 0.2,
      }),
    });
    const body = await r.text();
    let parsed;
    try {
      parsed = JSON.parse(body);
    } catch (_) {
      return res
        .status(502)
        .json({ error: 'openai_bad_response', body: body.slice(0, 200) });
    }
    if (!r.ok) {
      return res.status(r.status).json({ error: 'openai_error', detail: parsed });
    }
    let translated = parsed?.choices?.[0]?.message?.content ?? '';
    if (typeof translated !== 'string') translated = '';
    translated = translated.trim();
    // Defensive: strip a leading/trailing pair of straight or smart quotes
    // some models still add despite the explicit instruction.
    translated = translated.replace(/^["“”'‘’]+|["“”'‘’]+$/g, '').trim();
    // Last line against "venu(e) tout(e) seul(e)" reaching a speech voice.
    translated = resolveGenderHedges(translated, authorGender, peerGender);

    track({
      event: 'text_translation',
      lang_from: from || undefined,
      lang_to: to,
      props: {
        model: 'gpt-4.1',
        chars: text.length,
        history_msgs: history.length,
        has_context: Boolean(authorGender || peerGender || relationship),
        prompt_tokens: parsed?.usage?.prompt_tokens ?? null,
        cached_tokens:
          parsed?.usage?.prompt_tokens_details?.cached_tokens ?? null,
        completion_tokens: parsed?.usage?.completion_tokens ?? null,
      },
    });
    return res.json({ translated: translated || text });
  } catch (e) {
    console.error('translation text', e);
    return res.status(502).json({ error: 'openai_unreachable' });
  }
});

/**
 * Translate one transcript through Grok (/v1/chat/completions, OpenAI-compatible).
 * Returns { translated } on success, or { error, status, detail? } on failure.
 * When `from` is known and equals `to`, the transcript is returned unchanged.
 * Shared by the POST /translation/grok route and the realtime STT WebSocket.
 */
async function grokTranslateText({ transcript, from, to }) {
  if (from && from === to) return { translated: transcript };
  try {
    const sys =
      `You are a translation engine. Translate the user's text into ${to}` +
      `${from ? ` (it is in ${from})` : ''}. ` +
      `Use an informal, friendly register — tutoiement: "tu" in French, "du" in ` +
      `German, informal "you", etc. This is a casual social app where people ` +
      `meet and chat, never a formal one; do NOT use "vous" / formal forms. ` +
      `Say it the way a native speaker actually would, not word-for-word — drop ` +
      `literal politeness nouns and reorder to sound natural in the target language. ` +
      `Reply with the translation ONLY — no quotes, no notes, no language tags.`;
    const r = await fetch(`${GROK_BASE}/chat/completions`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${GROK_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: GROK_TRANSLATE_MODEL,
        messages: [
          { role: 'system', content: sys },
          { role: 'user', content: transcript },
        ],
        temperature: 0.2,
      }),
    });
    const body = await r.text();
    if (!r.ok) {
      console.error('grok translate error', r.status, body.slice(0, 300));
      return { error: 'grok_translate_error', status: 502, detail: body.slice(0, 300) };
    }
    const parsed = JSON.parse(body);
    let out = parsed?.choices?.[0]?.message?.content ?? '';
    if (typeof out !== 'string') out = '';
    out = out.trim().replace(/^[“”’"']+|[“”’"']+$/g, "").trim();
    // Strip Grok confidence markers that leak into translation output (e.g. \confidence{80}).
    out = out.replace(/\\confidence\{[^}]*\}/gi, '').trim();
    return { translated: out || transcript };
  } catch (e) {
    console.error('grok translate throw', e);
    return { error: 'grok_translate_unreachable', status: 502 };
  }
}

/**
 * Synthesize speech through Grok (/v1/tts → mp3). Returns { audio: Buffer } on
 * success, or { error, status, detail? } on failure. Shared by the POST route
 * and the realtime STT WebSocket.
 */
async function grokSynthesizeSpeech({ text, voice, lang }) {
  try {
    const ttsBody = { text, voice_id: voice, language: lang };
    if (GROK_TTS_MODEL) ttsBody.model = GROK_TTS_MODEL;
    const r = await fetch(`${GROK_BASE}/tts`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${GROK_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(ttsBody),
    });
    if (!r.ok) {
      const errText = await r.text();
      console.error('grok tts error', r.status, errText.slice(0, 300));
      return { error: 'grok_tts_error', status: 502, detail: errText.slice(0, 300) };
    }
    const audio = Buffer.from(await r.arrayBuffer());
    if (audio.length === 0) return { error: 'grok_tts_empty', status: 502 };
    return { audio };
  } catch (e) {
    console.error('grok tts throw', e);
    return { error: 'grok_tts_unreachable', status: 502 };
  }
}

/**
 * POST /translation/tts  (application/json)
 * Body: { text, lang?, voice? }  →  audio/mpeg (Grok TTS).
 *
 * Used by the app's fetchSpeech() to speak an incoming translated caption in a
 * REAL (Grok) voice instead of the device's built-in TTS. Without this route
 * the app gets a 404 and falls back to flutter_tts (the robotic device voice).
 * The app sends OpenAI-style voice names (e.g. "alloy"); anything not a valid
 * Grok voice is mapped to the default.
 */
app.post('/translation/tts', _limText, async (req, res) => {
  if (!GROK_API_KEY) {
    return res.status(500).json({ error: 'grok_not_configured' });
  }
  const text = typeof req.body?.text === 'string' ? req.body.text.trim() : '';
  if (!text) {
    return res.status(400).json({ error: 'text_missing' });
  }
  const lang = primaryLanguageTag(req.body?.lang);
  const v = typeof req.body?.voice === 'string' ? req.body.voice.trim().toLowerCase() : '';
  const voice = ['ara', 'eve', 'leo', 'rex', 'sal'].includes(v) ? v : GROK_TTS_VOICE;
  const sp = await grokSynthesizeSpeech({ text, voice, lang });
  if (sp.error) {
    return res
      .status(sp.status)
      .json({ error: sp.error, ...(sp.detail ? { detail: sp.detail } : {}) });
  }
  return res.status(200).type('audio/mpeg').send(sp.audio);
});

/**
 * POST /translation/voice  (multipart/form-data)
 *
 * Fields:
 *   audio   — one captured utterance (webm / m4a / mp3 / wav / ogg)
 *   from?   — BCP-47 source primary subtag (the spoken language)
 *   to      — BCP-47 target primary subtag (what to speak back)
 *   voice?  — voice id (ara|eve|leo|rex|sal)
 *
 * Returns: audio/mpeg (the translated speech).
 * On STT producing empty text, returns 204 (nothing to speak).
 *
 * Runs one utterance through the cloud STT → translate → TTS chain. The
 * transcript and the translation are echoed back in the `X-Sway-Transcript` /
 * `X-Sway-Translation` response headers so the on-screen debug panel can show
 * them.
 *
 * `/translation/grok` is the legacy path: app builds already in the stores call
 * it and read the `X-Grok-*` headers. Both are answered by this one handler,
 * and both header sets are sent, until those builds age out.
 */
app.post(VOICE_HTTP_PATHS, _limTight, voiceUpload.single('audio'), async (req, res) => {
  if (!GROK_API_KEY) {
    return res.status(500).json({ error: 'grok_not_configured' });
  }
  const file = req.file;
  if (!file || !file.buffer || file.buffer.length === 0) {
    return res.status(400).json({ error: 'audio_missing' });
  }
  const from = primaryLanguageTag(req.body?.from);
  const to = primaryLanguageTag(req.body?.to);
  if (!isReasonableLanguageTag(to)) {
    return res.status(400).json({ error: 'invalid_target' });
  }
  const voice = (() => {
    const v = typeof req.body?.voice === 'string' ? req.body.voice.trim().toLowerCase() : '';
    return ['ara', 'eve', 'leo', 'rex', 'sal'].includes(v) ? v : GROK_TTS_VOICE;
  })();

  const mime = (file.mimetype || '').toLowerCase();
  const ext = (() => {
    if (mime.includes('webm')) return 'webm';
    if (mime.includes('ogg')) return 'ogg';
    if (mime.includes('mpeg') || mime.includes('mp3')) return 'mp3';
    if (mime.includes('wav')) return 'wav';
    if (mime.includes('mp4') || mime.includes('m4a') || mime.includes('aac')) return 'm4a';
    return 'webm';
  })();

  // 1) STT — Grok /v1/stt (multipart). Node 18+ global FormData / Blob.
  // Per the official docs the endpoint takes ONLY `file` (language is
  // auto-detected, no model id) — sending extra fields gets the request
  // rejected, so we keep it to the single file part.
  let transcript = '';
  try {
    const form = new FormData();
    form.append('file', new Blob([file.buffer], { type: file.mimetype || 'audio/webm' }), `utt.${ext}`);
    const r = await fetch(`${GROK_BASE}/stt`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${GROK_API_KEY}` },
      body: form,
    });
    const body = await r.text();
    if (!r.ok) {
      console.error('grok stt error', r.status, body.slice(0, 300));
      return res.status(502).json({ error: 'grok_stt_error', detail: body.slice(0, 300) });
    }
    let parsed;
    try {
      parsed = JSON.parse(body);
    } catch (_) {
      console.error('grok stt parse', body.slice(0, 200));
      return res.status(502).json({ error: 'grok_stt_bad_response' });
    }
    transcript = typeof parsed.text === 'string' ? parsed.text.trim() : '';
  } catch (e) {
    console.error('grok stt throw', e);
    return res.status(502).json({ error: 'grok_stt_unreachable' });
  }

  if (!transcript) {
    // Nothing was said (silence / noise) — no audio to return.
    return res.status(204).end();
  }

  // 2) Translate — Grok /v1/chat/completions (OpenAI-compatible).
  const tr = await grokTranslateText({ transcript, from, to });
  if (tr.error) {
    return res
      .status(tr.status)
      .json({ error: tr.error, ...(tr.detail ? { detail: tr.detail } : {}) });
  }
  const translated = tr.translated;

  // 3) TTS — Grok /v1/tts → mp3 bytes.
  {
    const sp = await grokSynthesizeSpeech({ text: translated, voice, lang: to });
    if (sp.error) {
      return res
        .status(sp.status)
        .json({ error: sp.error, ...(sp.detail ? { detail: sp.detail } : {}) });
    }
    const audio = sp.audio;
    track({
      event: 'grok_test_translation',
      lang_from: from || undefined,
      lang_to: to,
      props: { chars: transcript.length, voice },
    });
    // Encode the texts so non-ASCII (accents, CJK) survives HTTP header rules.
    // `X-Grok-*` duplicates `X-Sway-*` for app builds already in the stores.
    const encTranscript = encodeURIComponent(transcript);
    const encTranslation = encodeURIComponent(translated);
    res.set('X-Sway-Transcript', encTranscript);
    res.set('X-Sway-Translation', encTranslation);
    res.set('X-Grok-Transcript', encTranscript);
    res.set('X-Grok-Translation', encTranslation);
    res.set(
      'Access-Control-Expose-Headers',
      'X-Sway-Transcript, X-Sway-Translation, X-Grok-Transcript, X-Grok-Translation',
    );
    return res.status(200).type('audio/mpeg').send(audio);
  }
});

/* ─── TEST — non-streaming STT (Silero VAD + Whisper) ──────────────────────
 *
 * TEMPORARY, WEB-ONLY EXPERIMENT — revert together with the rest of the test.
 *
 * The browser runs Silero VAD on the live mic, clips one utterance at the
 * 300 ms silence mark, and POSTs it here as a 16 kHz mono WAV. We transcribe
 * the WHOLE clip in one shot (no streaming, no partials), translate it, and
 * return text only — the peer speaks it with its device TTS, exactly as the
 * streaming path already does with `local_tts=true`.
 *
 * Fields: `audio` (WAV bytes), `from` / `to` (BCP-47).
 * Returns: { orig, trans, lang, ms: { stt, translate, total } }
 *          204 when the recogniser heard nothing worth saying.
 */
// `/translation/whisper` is the legacy spelling: builds already installed call
// it. Both are answered by this one handler until those builds age out.
const CLIP_STT_PATHS = ['/translation/clip', '/translation/whisper'];

app.post(CLIP_STT_PATHS, _limTight, voiceUpload.single('audio'), async (req, res) => {
  if (!OPENAI_API_KEY) {
    return res.status(500).json({ error: 'openai_not_configured' });
  }
  const file = req.file;
  if (!file || !file.buffer || file.buffer.length === 0) {
    return res.status(400).json({ error: 'audio_missing' });
  }
  const from = primaryLanguageTag(req.body?.from);
  const to = primaryLanguageTag(req.body?.to);
  if (!isReasonableLanguageTag(to)) {
    return res.status(400).json({ error: 'invalid_target' });
  }

  const t0 = Date.now();
  let transcript = '';
  try {
    const form = new FormData();
    form.append('file', new Blob([file.buffer], { type: 'audio/wav' }), 'utt.wav');
    form.append('model', WHISPER_MODEL);
    // Naming the language skips Whisper's detection pass — faster, and it stops
    // a short clip being mistaken for another language.
    if (isReasonableLanguageTag(from)) form.append('language', from);
    form.append('response_format', 'json');
    const r = await fetch('https://api.openai.com/v1/audio/transcriptions', {
      method: 'POST',
      headers: { Authorization: `Bearer ${OPENAI_API_KEY}` },
      body: form,
    });
    const body = await r.text();
    if (!r.ok) {
      console.error('whisper stt error', r.status, body.slice(0, 300));
      return res.status(502).json({ error: 'whisper_stt_error', detail: body.slice(0, 300) });
    }
    transcript = (JSON.parse(body).text || '').trim();
  } catch (e) {
    console.error('whisper stt throw', e);
    return res.status(502).json({ error: 'whisper_stt_unreachable' });
  }
  const tStt = Date.now();

  // Fed silence or a cough, Whisper hallucinates a stock phrase ("Sous-titrage
  // Société Radio-Canada", "Thank you."). The VAD filters most of it; drop
  // whatever still carries no letters.
  if (!transcript || !/\p{L}/u.test(transcript)) {
    return res.status(204).end();
  }

  const tr = await grokTranslateText({ transcript, from, to });
  if (tr.error) {
    return res
      .status(tr.status)
      .json({ error: tr.error, ...(tr.detail ? { detail: tr.detail } : {}) });
  }
  const tEnd = Date.now();

  console.log(
    `[whisper-test] "${transcript.slice(0, 60)}" → "${tr.translated.slice(0, 60)}" ` +
      `stt=${tStt - t0}ms tr=${tEnd - tStt}ms bytes=${file.buffer.length}`,
  );

  return res.json({
    orig: transcript,
    trans: tr.translated,
    lang: to,
    ms: { stt: tStt - t0, translate: tEnd - tStt, total: tEnd - t0 },
  });
});

/**
 * POST /messages/voice  (multipart/form-data)
 *
 * Fields:
 *   audio              — the recording (m4a / mp3 / webm / ogg / wav)
 *   conversationId     — string
 *   recipientId        — string (Supabase user_id of the peer)
 *   senderName         — string (display name of the caller)
 *   durationMs         — int    (recording length in ms, client-measured)
 *   hintLanguage       — optional BCP-47 primary subtag; speeds up Scribe
 *                        by not having to auto-detect
 *
 * Authorization: Bearer <Supabase JWT> — the sender is read from the
 *                                        verified token, never the body.
 *
 * Flow:
 *   1. Upload the raw audio bytes to `voice-messages/<senderId>/<uuid>.<ext>`
 *      so the bubble can stream the original recording.
 *   2. Send the bytes to ElevenLabs Scribe → transcription + detected
 *      language. The transcription becomes the message `body` so the
 *      existing /translation/text path picks it up unchanged.
 *   3. Insert a row in `messages` with audio_url + audio_duration_ms +
 *      detected language.
 *   4. Fire-and-forget push to the recipient (best-effort).
 *
 * Returns the inserted row so the client can render it locally without
 * waiting on the realtime subscription.
 */
app.post('/messages/voice', _limTight, voiceUpload.single('audio'), async (req, res) => {
  if (!ELEVENLABS_API_KEY) {
    return res.status(500).json({ error: 'elevenlabs_not_configured' });
  }
  const sb = supabase();
  if (!sb) {
    return res.status(500).json({ error: 'supabase_not_configured' });
  }
  const uid = await stripeAuthUserId(req);
  if (!uid) {
    return res.status(401).json({ error: 'unauthenticated' });
  }
  const file = req.file;
  if (!file || !file.buffer || file.buffer.length === 0) {
    return res.status(400).json({ error: 'audio_missing' });
  }

  const conversationId =
    typeof req.body?.conversationId === 'string'
      ? req.body.conversationId.trim().slice(0, 200)
      : '';
  const recipientId =
    typeof req.body?.recipientId === 'string'
      ? req.body.recipientId.trim().slice(0, 200)
      : '';
  const senderName =
    typeof req.body?.senderName === 'string'
      ? req.body.senderName.trim().slice(0, 120)
      : '';
  const durationMs = (() => {
    const n = Number(req.body?.durationMs);
    if (!Number.isFinite(n)) return null;
    const v = Math.round(n);
    if (v <= 0 || v > 120000) return null;
    return v;
  })();
  const hintLanguage = primaryLanguageTag(req.body?.hintLanguage);

  if (!conversationId || !recipientId) {
    return res.status(400).json({ error: 'invalid_input' });
  }

  // Pick an extension we'll trust on the storage URL. Default to `.m4a`
  // when the client didn't send a recognisable mime, since that's what
  // Flutter's `record` package emits on iOS/Android by default.
  const mime = (file.mimetype || '').toLowerCase();
  const ext = (() => {
    if (mime.includes('webm')) return 'webm';
    if (mime.includes('ogg')) return 'ogg';
    if (mime.includes('mpeg') || mime.includes('mp3')) return 'mp3';
    if (mime.includes('wav')) return 'wav';
    if (mime.includes('aac')) return 'm4a';
    if (mime.includes('mp4') || mime.includes('m4a')) return 'm4a';
    return 'm4a';
  })();
  const objectKey = `${uid}/${crypto.randomUUID()}.${ext}`;

  // 1) Upload the original recording to Supabase Storage. Failure here
  // is fatal — we can't insert a "voice message" row without the audio.
  try {
    const { error: upErr } = await sb.storage
      .from(VOICE_STORAGE_BUCKET)
      .upload(objectKey, file.buffer, {
        contentType: file.mimetype || 'audio/m4a',
        upsert: false,
        cacheControl: '3600',
      });
    if (upErr) {
      console.error('voice upload', upErr);
      return res.status(502).json({ error: 'storage_failed', detail: upErr.message });
    }
  } catch (e) {
    console.error('voice upload throw', e);
    return res.status(502).json({ error: 'storage_failed' });
  }
  const audioUrl = sb.storage
    .from(VOICE_STORAGE_BUCKET)
    .getPublicUrl(objectKey).data.publicUrl;

  // 2) STT via ElevenLabs Scribe. The recording is sent as multipart
  // form-data — Node 18+'s built-in FormData / Blob can shape this.
  let transcript = '';
  let detectedLanguage = hintLanguage || '';
  try {
    const form = new FormData();
    form.append('model_id', ELEVENLABS_STT_MODEL);
    if (hintLanguage) form.append('language_code', hintLanguage);
    form.append(
      'file',
      new Blob([file.buffer], { type: file.mimetype || 'audio/m4a' }),
      `voice.${ext}`,
    );
    const r = await fetch(ELEVENLABS_STT_URL, {
      method: 'POST',
      headers: { 'xi-api-key': ELEVENLABS_API_KEY },
      body: form,
    });
    const body = await r.text();
    let parsed;
    try {
      parsed = JSON.parse(body);
    } catch (_) {
      console.error('scribe parse', body.slice(0, 200));
      return res.status(502).json({ error: 'stt_bad_response' });
    }
    if (!r.ok) {
      console.error('scribe error', r.status, parsed);
      return res.status(502).json({ error: 'stt_error', detail: parsed });
    }
    transcript = typeof parsed.text === 'string' ? parsed.text.trim() : '';
    const lang = primaryLanguageTag(parsed.language_code);
    if (lang) detectedLanguage = lang;
  } catch (e) {
    console.error('scribe throw', e);
    return res.status(502).json({ error: 'stt_unreachable' });
  }

  // 3) Insert the message row. The transcript flows into the existing
  // `body` column so chat_thread_screen's translator picks it up unchanged.
  let inserted;
  try {
    const { data, error: insErr } = await sb
      .from('messages')
      .insert({
        conversation_id: conversationId,
        sender: uid,
        recipient: recipientId,
        sender_name: senderName,
        body: transcript,
        language: detectedLanguage || null,
        audio_url: audioUrl,
        audio_duration_ms: durationMs,
      })
      .select()
      .single();
    if (insErr) {
      console.error('voice insert', insErr);
      return res.status(502).json({ error: 'insert_failed', detail: insErr.message });
    }
    inserted = data;
  } catch (e) {
    console.error('voice insert throw', e);
    return res.status(502).json({ error: 'insert_failed' });
  }

  // 4) Push the recipient — best-effort, never blocks the response.
  (async () => {
    try {
      await notifyUser(recipientId, {
        title: senderName || 'Nouveau message',
        // Voice messages have no original-language hint on the
        // notification body; surface a generic "🎙 message vocal".
        body: transcript ? `🎙 ${transcript.slice(0, 120)}` : '🎙 Message vocal',
        type: 'message',
        data: { conversationId, senderId: uid, voice: '1' },
      });
    } catch (e) {
      console.error('voice notify', e);
    }
  })();

  track({
    event: 'voice_message_sent',
    lang_from: detectedLanguage || undefined,
    props: {
      stt_model: ELEVENLABS_STT_MODEL,
      bytes: file.buffer.length,
      duration_ms: durationMs,
      transcript_chars: transcript.length,
    },
  });

  return res.json({ message: inserted });
});

/**
 * POST /voice/dub
 *
 * Body: { messageId, targetLang, text }
 *   - messageId   — the voice message to dub (must be a row the caller
 *                   participates in)
 *   - targetLang  — BCP-47 primary subtag, e.g. "en"
 *   - text        — the already-translated text (client passes the
 *                   output of /translation/text so we don't re-bill
 *                   gpt-4.1 server-side just to dub)
 *
 * Returns: { audioUrl, cached }
 *
 * Gating:
 *   - tier === 'free'   → 402 upgrade_required
 *   - tier === 'plus'   → quota 60 dubs / rolling 30 days
 *   - tier === 'pro'    → unlimited, generic voice
 *   - tier === 'ultra'  → unlimited, uses the sender's cloned voice
 *                         when enrolled, generic voice otherwise
 *
 * Cache: results are keyed by (message_id, target_language) in the
 * `voice_dubs` table so a second listener never re-bills ElevenLabs.
 */
app.post('/voice/dub', _limTight, async (req, res) => {
  if (!ELEVENLABS_API_KEY) {
    return res.status(500).json({ error: 'elevenlabs_not_configured' });
  }
  const sb = supabase();
  if (!sb) {
    return res.status(500).json({ error: 'supabase_not_configured' });
  }
  const uid = await stripeAuthUserId(req);
  if (!uid) {
    return res.status(401).json({ error: 'unauthenticated' });
  }

  const messageId =
    typeof req.body?.messageId === 'string' ? req.body.messageId.trim() : '';
  const targetLang = primaryLanguageTag(req.body?.targetLang);
  const text =
    typeof req.body?.text === 'string'
      ? req.body.text.trim().slice(0, 4000)
      : '';
  if (!messageId || !isReasonableLanguageTag(targetLang) || !text) {
    return res.status(400).json({ error: 'invalid_input' });
  }

  // 1) Tier + quota — read profile + reset counter if its window is up.
  const { data: profile, error: profErr } = await sb
    .from('profiles')
    .select(
      'subscription_tier, voice_dubs_used_this_month, voice_dubs_reset_at, elevenlabs_voice_id',
    )
    .eq('id', uid)
    .maybeSingle();
  if (profErr || !profile) {
    return res.status(404).json({ error: 'profile_not_found' });
  }
  const tier = normalizeTier(profile.subscription_tier);
  const features = featuresFor(tier);
  if (features.voiceDub === 'none') {
    return res.status(402).json({ error: 'upgrade_required', minTier: 'plus' });
  }

  let used = Number(profile.voice_dubs_used_this_month) || 0;
  let resetAt = new Date(profile.voice_dubs_reset_at || Date.now());
  const now = new Date();
  if (now >= resetAt) {
    used = 0;
    resetAt = new Date(now.getTime() + 30 * 24 * 60 * 60 * 1000);
    await sb
      .from('profiles')
      .update({
        voice_dubs_used_this_month: 0,
        voice_dubs_reset_at: resetAt.toISOString(),
      })
      .eq('id', uid);
  }
  if (Number.isFinite(features.voiceDubsPerMonth) && used >= features.voiceDubsPerMonth) {
    return res.status(402).json({
      error: 'quota_exceeded',
      resetAt: resetAt.toISOString(),
      cap: features.voiceDubsPerMonth,
    });
  }

  // 2) Auth on the message — caller must participate in the
  //    conversation. Anyone with a valid messageId could otherwise
  //    rack up bills on someone else's thread.
  const { data: msg, error: msgErr } = await sb
    .from('messages')
    .select('id, sender, recipient')
    .eq('id', messageId)
    .maybeSingle();
  if (msgErr || !msg) {
    return res.status(404).json({ error: 'message_not_found' });
  }
  if (msg.sender !== uid && msg.recipient !== uid) {
    return res.status(403).json({ error: 'forbidden' });
  }

  // 3) Cache lookup. Concurrent requests on the same (msg,lang) race;
  //    whoever inserted first wins, the second one falls through to
  //    a fresh generation but the upsert below will resolve it.
  const { data: cached } = await sb
    .from('voice_dubs')
    .select('audio_url')
    .eq('message_id', messageId)
    .eq('target_language', targetLang)
    .maybeSingle();
  if (cached?.audio_url) {
    return res.json({ audioUrl: cached.audio_url, cached: true });
  }

  // 4) Pick the voice. Ultra → use the sender's cloned voice when they
  //    have one. Otherwise fall back to the default multilingual voice.
  let voiceId = ELEVENLABS_DEFAULT_VOICE_ID;
  let usedCloned = false;
  if (features.voiceDub === 'cloned') {
    // The clone we want is the SENDER's, not the listener's — the
    // whole point is "hear them in their voice but in your language".
    const { data: senderProfile } = await sb
      .from('profiles')
      .select('elevenlabs_voice_id')
      .eq('id', msg.sender)
      .maybeSingle();
    const cloneId = senderProfile?.elevenlabs_voice_id;
    if (cloneId) {
      voiceId = cloneId;
      usedCloned = true;
    }
  }

  // 5) Generate TTS via ElevenLabs Flash. Flash is multilingual; we
  //    pass `language_code` so the model doesn't auto-detect.
  let audioBuffer;
  try {
    const ttsUrl = `https://api.elevenlabs.io/v1/text-to-speech/${voiceId}`;
    const r = await fetch(ttsUrl, {
      method: 'POST',
      headers: {
        'xi-api-key': ELEVENLABS_API_KEY,
        'Content-Type': 'application/json',
        accept: 'audio/mpeg',
      },
      body: JSON.stringify({
        text,
        model_id: ELEVENLABS_TTS_MODEL,
        language_code: targetLang,
      }),
    });
    if (!r.ok) {
      const errText = await r.text();
      console.error('elevenlabs tts', r.status, errText.slice(0, 200));
      return res
        .status(502)
        .json({ error: 'tts_failed', detail: errText.slice(0, 200) });
    }
    const ab = await r.arrayBuffer();
    audioBuffer = Buffer.from(ab);
  } catch (e) {
    console.error('elevenlabs tts throw', e);
    return res.status(502).json({ error: 'tts_unreachable' });
  }

  // 6) Upload the dub to storage. Path mirrors the original recording
  //    layout but under `dubs/<msgId>/<lang>.mp3` so a single message
  //    can carry one cached dub per target language.
  const key = `dubs/${messageId}/${targetLang}.mp3`;
  try {
    const { error: upErr } = await sb.storage
      .from(VOICE_STORAGE_BUCKET)
      .upload(key, audioBuffer, {
        contentType: 'audio/mpeg',
        upsert: true,
        cacheControl: '86400',
      });
    if (upErr) {
      console.error('dub upload', upErr);
      return res.status(502).json({ error: 'storage_failed', detail: upErr.message });
    }
  } catch (e) {
    console.error('dub upload throw', e);
    return res.status(502).json({ error: 'storage_failed' });
  }
  const audioUrl = sb.storage
    .from(VOICE_STORAGE_BUCKET)
    .getPublicUrl(key).data.publicUrl;

  // 7) Cache + counter. Non-fatal: if these fail we still serve the
  //    audio so the listener isn't penalised by an ops issue.
  try {
    await sb.from('voice_dubs').upsert({
      message_id: messageId,
      target_language: targetLang,
      audio_url: audioUrl,
      tts_model: ELEVENLABS_TTS_MODEL,
      voice_id: voiceId,
    });
  } catch (e) {
    console.error('voice_dubs upsert', e);
  }
  try {
    await sb
      .from('profiles')
      .update({ voice_dubs_used_this_month: used + 1 })
      .eq('id', uid);
  } catch (e) {
    console.error('dub counter inc', e);
  }

  track({
    event: 'voice_dub',
    lang_to: targetLang,
    props: {
      tier,
      tts_model: ELEVENLABS_TTS_MODEL,
      used_cloned_voice: usedCloned,
      chars: text.length,
    },
  });

  return res.json({ audioUrl, cached: false });
});

/**
 * POST /voice/enroll   (multipart/form-data)
 *
 * Fields:
 *   audio  — ~30-60 s of clean speech from the caller
 *
 * Auth:   Bearer <Supabase JWT>
 * Gate:   featuresFor(tier).voiceClone === true  (Ultra only)
 *
 * Flow:
 *   1. Build a multipart POST to ElevenLabs `/v1/voices/add` (Instant
 *      Voice Cloning). IVC is included in the plan — no per-clone
 *      charge — but the account has a finite number of voice slots,
 *      so we gate strictly on Ultra so the slots scale with revenue.
 *   2. If the caller already enrolled before, DELETE the previous
 *      voice first so we don't leak slots on re-enrolment.
 *   3. Write the returned voice_id onto profiles.elevenlabs_voice_id.
 *      From then on the user's outgoing voice messages get dubbed with
 *      this voice when an Ultra listener taps "Écouter la traduction".
 *
 * Returns: { voiceId }
 */
app.post('/voice/enroll', _limClone, voiceUpload.single('audio'), async (req, res) => {
  if (!ELEVENLABS_API_KEY) {
    return res.status(500).json({ error: 'elevenlabs_not_configured' });
  }
  const sb = supabase();
  if (!sb) {
    return res.status(500).json({ error: 'supabase_not_configured' });
  }
  const uid = await stripeAuthUserId(req);
  if (!uid) {
    return res.status(401).json({ error: 'unauthenticated' });
  }
  const file = req.file;
  if (!file || !file.buffer || file.buffer.length === 0) {
    return res.status(400).json({ error: 'audio_missing' });
  }

  const { data: profile, error: profErr } = await sb
    .from('profiles')
    .select('subscription_tier, display_name, elevenlabs_voice_id')
    .eq('id', uid)
    .maybeSingle();
  if (profErr || !profile) {
    return res.status(404).json({ error: 'profile_not_found' });
  }
  const tier = normalizeTier(profile.subscription_tier);
  if (!featuresFor(tier).voiceClone) {
    return res.status(402).json({ error: 'upgrade_required', minTier: 'ultra' });
  }

  // 1) Best-effort delete of the previous clone — never blocks the
  //    re-enrolment. If the old voice was already removed manually on
  //    the ElevenLabs side, the DELETE 404s and we just move on.
  const previousVoiceId =
    typeof profile.elevenlabs_voice_id === 'string'
      ? profile.elevenlabs_voice_id.trim()
      : '';
  if (previousVoiceId) {
    try {
      await fetch(`https://api.elevenlabs.io/v1/voices/${previousVoiceId}`, {
        method: 'DELETE',
        headers: { 'xi-api-key': ELEVENLABS_API_KEY },
      });
    } catch (e) {
      console.error('elevenlabs delete previous voice', e);
    }
  }

  // 2) Add the new voice. ElevenLabs needs at least one audio file and
  //    a voice name; the name is internal — we tag it with the user id
  //    so support / dashboard queries can map back to a Supabase row.
  const ext = (() => {
    const m = (file.mimetype || '').toLowerCase();
    if (m.includes('webm')) return 'webm';
    if (m.includes('mpeg') || m.includes('mp3')) return 'mp3';
    if (m.includes('wav')) return 'wav';
    return 'm4a';
  })();
  const displayName =
    (typeof profile.display_name === 'string' ? profile.display_name : '')
      .trim()
      .slice(0, 40);
  const voiceName = `user_${uid.slice(0, 8)}${displayName ? `_${displayName}` : ''}`;

  let voiceId;
  try {
    const form = new FormData();
    form.append('name', voiceName);
    form.append('description', 'Swayco user-cloned voice (Ultra tier)');
    form.append(
      'files',
      new Blob([file.buffer], { type: file.mimetype || 'audio/m4a' }),
      `enroll.${ext}`,
    );
    const r = await fetch('https://api.elevenlabs.io/v1/voices/add', {
      method: 'POST',
      headers: { 'xi-api-key': ELEVENLABS_API_KEY },
      body: form,
    });
    const body = await r.text();
    let parsed;
    try {
      parsed = JSON.parse(body);
    } catch (_) {
      console.error('elevenlabs add parse', body.slice(0, 200));
      return res.status(502).json({ error: 'elevenlabs_bad_response' });
    }
    if (!r.ok) {
      console.error('elevenlabs add', r.status, parsed);
      return res
        .status(502)
        .json({ error: 'enroll_failed', detail: parsed });
    }
    voiceId =
      typeof parsed.voice_id === 'string' ? parsed.voice_id.trim() : '';
    if (!voiceId) {
      return res.status(502).json({ error: 'no_voice_id' });
    }
  } catch (e) {
    console.error('elevenlabs add throw', e);
    return res.status(502).json({ error: 'elevenlabs_unreachable' });
  }

  // 3) Persist the voice_id. Failure here is fatal for the feature —
  //    the voice slot is occupied on ElevenLabs but the app would not
  //    know to use it — surface the error so the caller can retry.
  try {
    const { error: upErr } = await sb
      .from('profiles')
      .update({ elevenlabs_voice_id: voiceId })
      .eq('id', uid);
    if (upErr) {
      console.error('voice id persist', upErr);
      return res
        .status(502)
        .json({ error: 'profile_update_failed', detail: upErr.message });
    }
  } catch (e) {
    console.error('voice id persist throw', e);
    return res.status(502).json({ error: 'profile_update_failed' });
  }

  track({
    event: 'voice_enroll',
    props: {
      tier,
      bytes: file.buffer.length,
      reenroll: Boolean(previousVoiceId),
    },
  });

  return res.json({ voiceId });
});

// Stripe Checkout — body: { tier: 'plus' | 'pro' | 'ultra' }. Authorization
// must carry the caller's Supabase JWT; the user_id is read from
// the verified token, never from the request body.
app.post('/api/stripe/checkout', async (req, res) => {
  const uid = await stripeAuthUserId(req);
  if (!uid) return res.status(401).json({ error: 'unauthenticated' });
  const tier = req.body?.tier;
  if (tier !== 'plus' && tier !== 'ultra_plus') {
    return res.status(400).json({ error: 'invalid_tier' });
  }
  try {
    const url = await createCheckoutSession(uid, tier);
    return res.json({ url });
  } catch (e) {
    // eslint-disable-next-line no-console
    console.error('[stripe checkout] error:', e?.message || e);
    return res.status(500).json({ error: e?.message || 'checkout_failed' });
  }
});

// Stripe Customer Portal — same auth as checkout.
app.post('/api/stripe/portal', async (req, res) => {
  const uid = await stripeAuthUserId(req);
  if (!uid) return res.status(401).json({ error: 'unauthenticated' });
  try {
    const url = await createPortalSession(uid);
    return res.json({ url });
  } catch (e) {
    // eslint-disable-next-line no-console
    console.error('[stripe portal] error:', e?.message || e);
    return res.status(500).json({ error: e?.message || 'portal_failed' });
  }
});

// Fan-out push notification dispatcher. Body: { recipientUid, title,
// body, type, data }. See backend/notify.js for env-var requirements.
app.post('/api/notify', _limLite, async (req, res) => {
  const { recipientUid, title, body, type, data } = req.body || {};
  if (!recipientUid || !title) {
    return res.status(400).json({ error: 'missing_recipient_or_title' });
  }
  try {
    const out = await notifyUser(recipientUid, { title, body, type, data });
    return res.json(out);
  } catch (e) {
    console.error('/api/notify error', e);
    return res.status(500).json({ error: 'notify_failed' });
  }
});

// ── "X Japonaises en ligne" broadcast engine ─────────────────────────────────
// For each push-registered user who is NOT currently in the app, find the
// country with the most opposite-sex users online right now and nudge them with
// it. Recipient gender unknown/'x'/NULL is treated as a man (→ advertise women).
async function runOnlineBroadcast({
  minCount,
  windowSeconds,
  dryRun,
  recipientLang,
} = {}) {
  const sb = supabase();
  if (!sb) return { ok: false, error: 'supabase_not_configured' };
  recipientLang = recipientLang
    ? String(recipientLang).toLowerCase().split(/[-_]/)[0]
    : null;
  minCount = Number.isFinite(minCount) ? minCount : BROADCAST_MIN_COUNT;
  windowSeconds = Number.isFinite(windowSeconds)
    ? windowSeconds
    : BROADCAST_WINDOW_SECONDS;

  // 1. Who's online, by country + gender.
  const { data: counts, error: cErr } = await sb.rpc(
    'online_counts_by_country_gender',
    { p_window_seconds: windowSeconds },
  );
  if (cErr) return { ok: false, error: cErr.message };

  // For each target gender, keep the country with the most online users of it.
  const bestByGender = { m: null, f: null };
  for (const row of counts || []) {
    const g = row.gender;
    if (g !== 'm' && g !== 'f') continue;
    if (row.n < minCount) continue;
    if (!bestByGender[g] || row.n > bestByGender[g].n) {
      bestByGender[g] = { country: row.country, n: row.n };
    }
  }
  if (!bestByGender.m && !bestByGender.f) {
    return { ok: true, sent: 0, skipped: 0, reason: 'nobody_online_above_min' };
  }

  // 2. Recipients = everyone with a registered push target.
  const { data: targets, error: tErr } = await sb
    .from('notification_targets')
    .select('user_id');
  if (tErr) return { ok: false, error: tErr.message };
  const recipientIds = [...new Set((targets || []).map((t) => t.user_id))];
  if (recipientIds.length === 0) {
    return { ok: true, sent: 0, skipped: 0, reason: 'no_push_targets' };
  }

  // Their gender + language + presence (chunked to keep the IN() list sane).
  const profiles = [];
  for (let i = 0; i < recipientIds.length; i += 500) {
    const slice = recipientIds.slice(i, i + 500);
    let q = sb
      .from('profiles')
      .select('id, gender, language, last_seen')
      .in('id', slice);
    // Market-targeted run: only this language's users (matches 'fr', 'fr-FR'…).
    if (recipientLang) q = q.ilike('language', `${recipientLang}%`);
    // eslint-disable-next-line no-await-in-loop
    const { data, error } = await q;
    if (error) return { ok: false, error: error.message };
    if (data) profiles.push(...data);
  }

  const onlineCutoffMs = Date.now() - windowSeconds * 1000;
  let skipped = 0;
  const sends = [];
  for (const p of profiles) {
    // Already in the app → they can see who's online themselves. Skip.
    const seen = p.last_seen ? Date.parse(p.last_seen) : 0;
    if (seen && seen > onlineCutoffMs) {
      skipped += 1;
      continue;
    }
    // 'f' → advertise men; anything else (m / x / null) → advertise women.
    const targetGender = p.gender === 'f' ? 'm' : 'f';
    const best = bestByGender[targetGender];
    if (!best) {
      skipped += 1;
      continue;
    }
    const lang = (p.language || 'en').toLowerCase().split(/[-_]/)[0];
    const payload = onlineNotif(lang, best.country, targetGender, best.n);
    if (!payload) {
      skipped += 1;
      continue;
    }
    sends.push({ uid: p.id, payload });
  }

  if (dryRun) {
    return {
      ok: true,
      dryRun: true,
      wouldSend: sends.length,
      skipped,
      bestByGender,
      sample: sends.slice(0, 5).map((s) => s.payload.title),
    };
  }

  // Fan out with a small concurrency cap so we don't stampede push/DB.
  let sent = 0;
  const POOL = 16;
  for (let i = 0; i < sends.length; i += POOL) {
    const batch = sends.slice(i, i + POOL);
    // eslint-disable-next-line no-await-in-loop
    await Promise.all(
      batch.map(async (s) => {
        try {
          await notifyUser(s.uid, s.payload);
          sent += 1;
        } catch (e) {
          console.error('[broadcast] notify failed', s.uid, e?.message || e);
        }
      }),
    );
  }
  return { ok: true, sent, skipped, bestByGender };
}

// Manual trigger. Header `x-broadcast-secret` must equal BROADCAST_SECRET.
// Body (all optional): { minCount, windowSeconds, dryRun }.
app.post('/api/notify-online-broadcast', async (req, res) => {
  if (!BROADCAST_SECRET || req.get('x-broadcast-secret') !== BROADCAST_SECRET) {
    return res.status(401).json({ error: 'unauthorized' });
  }
  const { minCount, windowSeconds, dryRun, recipientLang } = req.body || {};
  try {
    const out = await runOnlineBroadcast({
      minCount: minCount != null ? Number(minCount) : undefined,
      windowSeconds: windowSeconds != null ? Number(windowSeconds) : undefined,
      dryRun: dryRun === true || dryRun === 'true',
      recipientLang: recipientLang || undefined,
    });
    return res.json(out);
  } catch (e) {
    console.error('/api/notify-online-broadcast error', e);
    return res.status(500).json({ error: 'broadcast_failed' });
  }
});

// Legal site — Terms, Privacy, Help. Must be registered BEFORE the
// Flutter SPA fallback so /terms etc. serve the HTML files rather
// than falling through to the Flutter index.html.
if (hasLegalSite) {
  // CSS + future assets under /legal-assets/* (absolute path that
  // can't collide with anything Flutter ships).
  app.use('/legal-assets', express.static(legalPath));
  // Clean URLs matching what the Flutter Settings screen links to.
  const legalRoutes = {
    '/legal': 'index.html',
    '/terms': 'terms.html',
    '/privacy': 'privacy.html',
    '/help': 'help.html',
    // App Store Connect requires a "Support URL" in app metadata.
    // /support serves the same FAQ page as /help so the URL we hand
    // to Apple (https://www.swayco.fr/support) is self-explanatory.
    '/support': 'help.html',
    '/child-safety': 'child-safety.html',
  };
  for (const [route, file] of Object.entries(legalRoutes)) {
    app.get(route, (_req, res) =>
      res.sendFile(path.join(legalPath, file)),
    );
  }
}

// One-click unsubscribe from re-engagement emails. Every email footer links
// here with the user id + their secret token (RGPD requirement). Registered
// BEFORE the Flutter SPA fallback so it isn't swallowed by index.html.
function unsubPage(ok) {
  const msg = ok
    ? 'Vous êtes désabonné des e-mails Swayco. / You have been unsubscribed from Swayco emails.'
    : 'Lien invalide ou expiré. / Invalid or expired link.';
  return (
    '<!doctype html><html><head><meta charset="utf-8">' +
    '<meta name="viewport" content="width=device-width,initial-scale=1"></head>' +
    '<body style="font-family:-apple-system,Segoe UI,Roboto,sans-serif;background:#0e0e0e;' +
    'color:#fff;display:flex;min-height:100vh;align-items:center;justify-content:center;' +
    'text-align:center;padding:24px;margin:0;"><div>' +
    '<div style="font-size:22px;font-weight:800;margin-bottom:16px;">swayco' +
    '<span style="color:#00BCD4;">.ai</span></div>' +
    `<p style="color:#bbb;max-width:360px;">${msg}</p></div></body></html>`
  );
}
app.get('/email/unsubscribe', async (req, res) => {
  const u = String(req.query.u || '');
  const t = String(req.query.t || '');
  const sb = supabase();
  if (!sb || !u || !t) {
    return res.status(400).type('html').send(unsubPage(false));
  }
  try {
    const { data: prof } = await sb
      .from('profiles')
      .select('email_unsub_token')
      .eq('id', u)
      .maybeSingle();
    if (!prof || String(prof.email_unsub_token) !== t) {
      return res.status(403).type('html').send(unsubPage(false));
    }
    await sb
      .from('profiles')
      .update({ email_notifications: false })
      .eq('id', u);
    return res.type('html').send(unsubPage(true));
  } catch (e) {
    console.error('/email/unsubscribe error', e);
    return res.status(500).type('html').send(unsubPage(false));
  }
});

if (hasWebUi) {
  app.use(express.static(webPath));
  app.use((req, res, next) => {
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      return next();
    }
    const p = req.path || '';
    if (
      p.startsWith('/livekit') ||
      p === '/health' ||
      p.startsWith('/translation') ||
      p.startsWith('/api') ||
      p.startsWith('/legal-assets') ||
      p === '/legal' ||
      p === '/terms' ||
      p === '/privacy' ||
      p === '/help' ||
      p === '/support' ||
      p === '/child-safety'
    ) {
      return next();
    }
    return res.sendFile(webIndex, (err) => (err ? next(err) : undefined));
  });
} else {
  app.get('/', (_req, res) => {
    res.type('application/json').send(
      JSON.stringify(
        {
          service: 'livekit-translate-token-api',
          hint: 'Build with Docker to bundle Flutter web in ./web',
          routes: {
            health: 'GET /health',
            livekitToken: 'POST /livekit/token',
            translationSession: 'POST /translation/realtime/session',
            translationCalls: 'POST /translation/realtime/calls',
          },
        },
        null,
        2,
      ),
    );
  });
}

// ─── Cloud realtime STT — WebSocket proxy ──────────────────────────────────
// The app streams its OWN microphone PCM16 (16 kHz, 100 ms frames) to us; we
// relay it to the upstream realtime STT WebSocket (the API key stays
// server-side, as the provider requires), and on each utterance-final
// transcript we translate + TTS and push the result back. The app then forwards
// that translation to the peer over the LiveKit data channel. STT runs on the
// LOCAL outgoing mic, never the remote track — that is what makes this
// native-direct (no PCM tap on a remote WebRTC stream). Shares the translate /
// synthesize helpers with the POST path.
// Endpoint: wss://<host>/translation/voice/stt?from=fr&to=ja&voice=eve
const { WebSocketServer, WebSocket: WsClient } = require('ws');

const GROK_STT_SAMPLE_RATES = [8000, 16000, 22050, 24000, 44100, 48000];

function attachGrokSttWs(server) {
  // `noServer` + manual upgrade routing: a `ws` server bound with `path`
  // destroys every upgrade that misses its path, so two of them on one HTTP
  // server would fight. One server, both paths, legacy builds keep working.
  const wss = new WebSocketServer({ noServer: true });
  server.on('upgrade', (req, socket, head) => {
    const path = (req.url || '').split('?')[0];
    if (!VOICE_STT_WS_PATHS.includes(path)) {
      socket.destroy();
      return;
    }
    wss.handleUpgrade(req, socket, head, (ws) => wss.emit('connection', ws, req));
  });

  wss.on('connection', (client, req) => {
    const sendCtl = (obj) => {
      if (client.readyState === WsClient.OPEN) client.send(JSON.stringify(obj));
    };
    if (!GROK_API_KEY) {
      sendCtl({ type: 'error', error: 'grok_not_configured' });
      client.close();
      return;
    }

    const url = new URL(req.url, 'http://localhost');
    const from = primaryLanguageTag(url.searchParams.get('from') || '');
    const to = primaryLanguageTag(url.searchParams.get('to') || '');
    // local_tts=true → native client synthesises locally; skip cloud TTS. The
    // `kokoro` spelling is what app builds already in the stores send.
    const localTtsMode =
      url.searchParams.get('local_tts') === 'true' ||
      url.searchParams.get('kokoro') === 'true';
    const voice = (() => {
      const v = (url.searchParams.get('voice') || '').trim().toLowerCase();
      return ['ara', 'eve', 'leo', 'rex', 'sal'].includes(v) ? v : GROK_TTS_VOICE;
    })();
    const sampleRate = (() => {
      const n = Number(url.searchParams.get('sample_rate'));
      return GROK_STT_SAMPLE_RATES.includes(n) ? n : 16000;
    })();
    if (!isReasonableLanguageTag(to)) {
      sendCtl({ type: 'error', error: 'invalid_target' });
      client.close();
      return;
    }

    // Upstream xAI realtime STT socket — with auto-reconnect.
    // xAI closes the upstream after its own session/utterance limits; we reopen
    // it transparently without dropping the client connection or losing state.
    const params = new URLSearchParams({
      sample_rate: String(sampleRate),
      encoding: 'pcm', // xAI: pcm | mulaw | alaw (pcm = signed 16-bit LE)
      endpointing: '500',
    });
    if (from) params.set('language', from);

    let upstreamOpen = false;
    let closing = false;
    const pending = []; // PCM frames buffered while upstream is (re)connecting
    let currentUpstream = null;

    let lastFinalText = '';
    let pendingText = '';   // accumulated is_final text, waiting for transcript.done
    let pendingTimer = null;

    function openUpstream() {
      if (closing) return;
      const up = new WsClient(`${GROK_WS_BASE}/stt?${params.toString()}`, {
        headers: { Authorization: `Bearer ${GROK_API_KEY}` },
      });
      currentUpstream = up;
      up.on('open', () => {
        upstreamOpen = true;
        console.log('grok stt upstream OPEN');
        for (const buf of pending) up.send(buf);
        pending.length = 0;
      });
      up.on('message', handleUpstreamMessage);
      up.on('error', (e) => {
        console.error('grok stt ws upstream error', e?.message || e);
      });
      up.on('close', () => {
        upstreamOpen = false;
        if (!closing) {
          // Client VAD controls session lifecycle (audio.done on silence);
          // this reconnect covers network drops and xAI internal limits.
          console.log('grok stt upstream closed by xAI — reconnecting in 100ms');
          setTimeout(openUpstream, 100);
        }
      });
    }
    openUpstream();

    // Translate a complete utterance. Deduplicates against the last sent text.
    const translateUtterance = async (text) => {
      const transcript = (text || '').trim();
      if (!transcript || transcript === lastFinalText) return;
      lastFinalText = transcript;
      console.log('grok stt → translate', JSON.stringify(transcript.slice(0, 80)));

      // Segment finalised → translate, then TTS only when client needs it.
      const tr = await grokTranslateText({ transcript, from, to });
      if (tr.error) return sendCtl({ type: 'error', error: tr.error });

      if (localTtsMode) {
        track({
          event: 'grok_stt_translation',
          lang_from: from || undefined,
          lang_to: to,
          props: { chars: transcript.length, tts: 'local' },
        });
        sendCtl({
          type: 'translation',
          orig: transcript,
          trans: tr.translated,
          lang: to,
          audio: '',
        });
      } else {
        const sp = await grokSynthesizeSpeech({ text: tr.translated, voice, lang: to });
        if (sp.error) return sendCtl({ type: 'error', error: sp.error });
        track({
          event: 'grok_stt_translation',
          lang_from: from || undefined,
          lang_to: to,
          props: { chars: transcript.length, voice, tts: 'grok' },
        });
        sendCtl({
          type: 'translation',
          orig: transcript,
          trans: tr.translated,
          lang: to,
          audio: sp.audio.toString('base64'),
        });
      }
    };

    // Named handler so openUpstream() can re-attach it on each new socket.
    async function handleUpstreamMessage(data) {
      let evt;
      try {
        evt = JSON.parse(data.toString());
      } catch (_) {
        return;
      }

      // Stream partials for live captions (no translation yet).
      if (evt.type === 'transcript.partial' && !evt.is_final) {
        if (typeof evt.text === 'string') sendCtl({ type: 'partial', text: evt.text });
        if (evt.speech_final === true) {
          console.log('grok stt SPEECH_FINAL (non-final partial) text=',
            (typeof evt.text === 'string' ? evt.text : '').slice(0, 80));
        }
        return;
      }

      // is_final: a ~3 s locked segment — safety fallback only.
      // Client VAD sends audio.done on silence so transcript.done is the
      // normal path; this timer fires only if the client never sends audio.done.
      if (evt.type === 'transcript.partial' && evt.is_final === true) {
        if (evt.speech_final === true) {
          console.log('grok stt SPEECH_FINAL (on is_final) text=',
            (typeof evt.text === 'string' ? evt.text : '').slice(0, 80));
        }
        const text = (typeof evt.text === 'string' ? evt.text : '').trim();
        if (!text) return;
        pendingText = text;
        clearTimeout(pendingTimer);
        pendingTimer = setTimeout(() => {
          const t = pendingText;
          pendingText = '';
          pendingTimer = null;
          translateUtterance(t);
        }, 4000);
        return;
      }

      // transcript.done: utterance complete (sent by xAI after audio.done or silence).
      if (evt.type === 'transcript.done') {
        if (evt.speech_final === true) {
          console.log('grok stt SPEECH_FINAL (on transcript.done) text=',
            (typeof evt.text === 'string' ? evt.text : '').slice(0, 80));
        }
        clearTimeout(pendingTimer);
        pendingTimer = null;
        pendingText = '';
        const text = (typeof evt.text === 'string' ? evt.text : '').trim();
        translateUtterance(text);
      }
    }

    // App → us. Binary frames are raw PCM; text frames are control messages.
    client.on('message', (data, isBinary) => {
      if (isBinary) {
        if (upstreamOpen && currentUpstream?.readyState === WsClient.OPEN) {
          currentUpstream.send(data);
        } else {
          pending.push(data);
        }
        return;
      }
      let msg;
      try {
        msg = JSON.parse(data.toString());
      } catch (_) {
        return;
      }
      if (msg.type === 'audio.done' && currentUpstream?.readyState === WsClient.OPEN) {
        currentUpstream.send(JSON.stringify({ type: 'audio.done' }));
      }
    });

    client.on('close', () => {
      closing = true;
      clearTimeout(pendingTimer);
      pendingTimer = null;
      try {
        if (currentUpstream?.readyState === WsClient.OPEN) {
          currentUpstream.send(JSON.stringify({ type: 'audio.done' }));
        }
        currentUpstream?.close();
      } catch (_) {}
    });
    client.on('error', () => {
      clearTimeout(pendingTimer);
      pendingTimer = null;
      try {
        upstream.close();
      } catch (_) {}
    });
  });

  return wss;
}

const server = app.listen(PORT, '0.0.0.0', () => {
  // eslint-disable-next-line no-console
  console.log(
    `Listening on http://0.0.0.0:${PORT} (web UI: ${hasWebUi ? 'yes' : 'no'})`,
  );
});
attachGrokSttWs(server);

// In-process per-market scheduler for the "X en ligne" broadcast. Zero-dep:
// every minute, for each market, it checks the market's LOCAL hour (DST-correct)
// and fires once per matching local hour, nudging only that market's language.
// A market with no hours configured is skipped; the manual endpoint still works.
const activeMarkets = BROADCAST_MARKETS.filter((m) => m.hours.length > 0);
if (activeMarkets.length > 0) {
  const lastSlot = {}; // lang → last fired "day-hour"
  const timer = setInterval(() => {
    for (const m of activeMarkets) {
      const p = localParts(m.tz);
      if (!p || !m.hours.includes(p.hour)) continue;
      const slot = `${p.day}-${p.hour}`;
      if (lastSlot[m.lang] === slot) continue; // already fired this local hour
      lastSlot[m.lang] = slot;
      runOnlineBroadcast({ recipientLang: m.lang })
        .then((out) =>
          console.log(`[broadcast] auto ${m.lang}`, JSON.stringify(out)))
        .catch((e) =>
          console.error(`[broadcast] auto ${m.lang} error`, e?.message || e));
    }
  }, 60 * 1000);
  timer.unref?.();
  // eslint-disable-next-line no-console
  console.log(
    `[broadcast] scheduler on: ${activeMarkets
      .map((m) => `${m.lang}@${m.tz}[${m.hours.join(',')}]`)
      .join(' ')}`,
  );
}

// Reminder copy, localised into each RECIPIENT's language (so a Japanese user
// never gets a French reminder). Falls back en → fr for unlisted languages.
const SCHED_REMINDER_I18N = {
  fr: { title: '📞 Rappel d\'appel', body: (n) => `Ton appel avec ${n} commence bientôt`, none: 'Ton appel planifié commence bientôt' },
  en: { title: '📞 Call reminder', body: (n) => `Your call with ${n} starts soon`, none: 'Your scheduled call starts soon' },
  es: { title: '📞 Recordatorio de llamada', body: (n) => `Tu llamada con ${n} empieza pronto`, none: 'Tu llamada programada empieza pronto' },
  de: { title: '📞 Anruf-Erinnerung', body: (n) => `Dein Anruf mit ${n} beginnt bald`, none: 'Dein geplanter Anruf beginnt bald' },
  it: { title: '📞 Promemoria chiamata', body: (n) => `La tua chiamata con ${n} sta per iniziare`, none: 'La tua chiamata pianificata sta per iniziare' },
  pt: { title: '📞 Lembrete de chamada', body: (n) => `A tua chamada com ${n} começa em breve`, none: 'A tua chamada agendada começa em breve' },
  nl: { title: '📞 Herinnering oproep', body: (n) => `Je gesprek met ${n} begint binnenkort`, none: 'Je geplande gesprek begint binnenkort' },
  ar: { title: '📞 تذكير بمكالمة', body: (n) => `مكالمتك مع ${n} ستبدأ قريبًا`, none: 'مكالمتك المجدولة ستبدأ قريبًا' },
  ru: { title: '📞 Напоминание о звонке', body: (n) => `Твой звонок с ${n} скоро начнётся`, none: 'Твой запланированный звонок скоро начнётся' },
  zh: { title: '📞 通话提醒', body: (n) => `你和 ${n} 的通话即将开始`, none: '你预约的通话即将开始' },
  ja: { title: '📞 通話リマインダー', body: (n) => `${n} との通話がまもなく始まります`, none: '予約した通話がまもなく始まります' },
  ko: { title: '📞 통화 알림', body: (n) => `${n} 님과의 통화가 곧 시작돼요`, none: '예약한 통화가 곧 시작돼요' },
};
function schedReminderPayload(lang, peerName, callId) {
  const code = String(lang || '').toLowerCase().split(/[-_]/)[0];
  const m = SCHED_REMINDER_I18N[code] || SCHED_REMINDER_I18N.en;
  return {
    title: m.title,
    body: peerName ? m.body(peerName) : m.none,
    type: 'call_reminder',
    data: { scheduledCallId: String(callId) },
  };
}

// ── Scheduled-call reminders ─────────────────────────────────────────────────
// Every minute, find planned calls (table `scheduled_calls`, migration 0042)
// whose start is within SCHEDULED_CALL_LEAD_MS and that haven't been reminded
// yet, push BOTH parties, and stamp `reminder_sent_at` so each fires exactly
// once. Rows whose start is long past are marked without notifying (stale).
const SCHEDULED_CALL_LEAD_MS = Number(
  process.env.SCHEDULED_CALL_LEAD_MS || 5 * 60 * 1000,
);
async function runScheduledCallReminders() {
  const sb = supabase();
  if (!sb) return { ok: false, error: 'supabase_not_configured' };
  const now = Date.now();
  const dueBefore = new Date(now + SCHEDULED_CALL_LEAD_MS).toISOString();
  const staleBefore = now - 2 * 60 * 60 * 1000; // 2h grace window
  const { data: rows, error } = await sb
    .from('scheduled_calls')
    .select('id, caller, callee, scheduled_at')
    .is('reminder_sent_at', null)
    .lte('scheduled_at', dueBefore)
    .order('scheduled_at', { ascending: true })
    .limit(100);
  if (error) {
    console.error('[sched] query error', error.message || error);
    return { ok: false, error: 'query_failed' };
  }
  let sent = 0;
  for (const r of rows || []) {
    const startMs = Date.parse(r.scheduled_at);
    // Stamp FIRST so a transient push failure can't make a row re-fire forever.
    await sb
      .from('scheduled_calls')
      .update({ reminder_sent_at: new Date().toISOString() })
      .eq('id', r.id);
    if (Number.isFinite(startMs) && startMs < staleBefore) continue; // stale
    // Each party's name (for the body) and language (to localise) — best-effort.
    const { data: people } = await sb
      .from('profiles')
      .select('id, display_name, language')
      .in('id', [r.caller, r.callee]);
    const personOf = (id) => (people || []).find((x) => x.id === id) || {};
    const nameOf = (id) => {
      const p = personOf(id);
      return typeof p.display_name === 'string' ? p.display_name.trim() : '';
    };
    const langOf = (id) => {
      const p = personOf(id);
      return typeof p.language === 'string' ? p.language : '';
    };
    try {
      await notifyUser(
        r.caller,
        schedReminderPayload(langOf(r.caller), nameOf(r.callee), r.id),
      );
      await notifyUser(
        r.callee,
        schedReminderPayload(langOf(r.callee), nameOf(r.caller), r.id),
      );
      sent += 1;
    } catch (e) {
      console.error('[sched] notify error', e?.message || e);
    }
  }
  return { ok: true, scanned: (rows || []).length, sent };
}

if (supabase()) {
  const schedTimer = setInterval(() => {
    runScheduledCallReminders()
      .then((out) => {
        if (out && out.sent) console.log('[sched] reminders', JSON.stringify(out));
      })
      .catch((e) => console.error('[sched] error', e?.message || e));
  }, 60 * 1000);
  schedTimer.unref?.();
  // eslint-disable-next-line no-console
  console.log(`[sched] reminder scheduler on (lead ${SCHEDULED_CALL_LEAD_MS}ms)`);
}
