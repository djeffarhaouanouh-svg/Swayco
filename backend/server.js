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

const app = express();
app.use(cors());

// Raw SDP body (not JSON) — must run before express.json().
app.post(
  '/translation/realtime/calls',
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

// Boot-time diagnostic endpoint hit by lib/services/diag.dart. The
// Flutter app fire-and-forgets one GET /diag per startup step so we
// can see — from Railway logs alone — how far a Release build on a
// real device gets before going silent. Returns instantly, never
// blocks, never throws. Logged with [diag] prefix so a Railway
// search for "[diag]" filters the whole boot trace per session.
app.get('/diag', (req, res) => {
  try {
    const ip =
      req.headers['x-forwarded-for'] ||
      req.headers['cf-connecting-ip'] ||
      req.socket?.remoteAddress ||
      '';
    const safe = {
      step: String(req.query.step || '').slice(0, 64),
      session: String(req.query.session || '').slice(0, 64),
      seq: String(req.query.seq || '').slice(0, 8),
      platform: String(req.query.platform || '').slice(0, 16),
      build: String(req.query.build || '').slice(0, 32),
      note: String(req.query.note || '').slice(0, 800),
      ip: String(ip).split(',')[0].trim(),
    };
    console.log(`[diag] ${JSON.stringify(safe)}`);
  } catch (_) {
    // Never let a diagnostic ping take the server down.
  }
  res.json({ ok: true });
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
app.post('/livekit/token', async (req, res) => {
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
app.post('/invite/create', async (req, res) => {
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
app.post('/translation/realtime/session', async (req, res) => {
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
app.post('/translation/text', async (req, res) => {
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
    `- For gendered languages, use the correct grammatical gender for the ` +
    `speaker and the addressee.\n` +
    `- Preserve emojis, proper nouns, @mentions, #hashtags and URLs verbatim.\n` +
    `- Keep punctuation, capitalisation and message length close to the original.\n` +
    `- If a phrase was already translated earlier in the conversation, ` +
    `reuse the same wording for consistency.\n` +
    `- If the last message is already in the target language, return it unchanged.\n` +
    `- Reply with the translated text ONLY — no quotes, no notes, no language tags, ` +
    `no markdown fences.`;

  const contextLines = [];
  if (from) contextLines.push(`Source language: ${from}`);
  contextLines.push(`Target language: ${to}`);
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
    const r = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${OPENAI_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        // gpt-4.1-mini: 5× cheaper than gpt-4.1 on both input and
        // output tokens, with no measurable quality loss on this
        // single-message translation prompt. Switch back to gpt-4.1
        // (full) if we ever see register / gender-accord errors creep
        // in for tricky language pairs.
        model: 'gpt-4.1-mini',
        messages: [
          {
            role: 'system',
            content: [
              {
                type: 'text',
                text: sys,
                cache_control: { type: 'ephemeral' },
              },
            ],
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
app.post('/messages/voice', voiceUpload.single('audio'), async (req, res) => {
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
app.post('/voice/dub', async (req, res) => {
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
app.post('/voice/enroll', voiceUpload.single('audio'), async (req, res) => {
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
app.post('/api/notify', async (req, res) => {
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

app.listen(PORT, '0.0.0.0', () => {
  // eslint-disable-next-line no-console
  console.log(
    `Listening on http://0.0.0.0:${PORT} (web UI: ${hasWebUi ? 'yes' : 'no'})`,
  );
});
