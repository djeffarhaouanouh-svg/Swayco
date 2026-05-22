'use strict';

// LiveKit token API + optional Flutter web UI (folder ./web from Docker build).

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const express = require('express');
const cors = require('cors');
const dotenv = require('dotenv');
const { AccessToken } = require('livekit-server-sdk');
const { notifyUser, broadcastLiveCall } = require('./notify');
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
 * Body: { text: "...", from?: "fr", to: "en" } (BCP-47 primary subtag)
 * Returns: { translated: "..." }
 * Cheap one-shot text translation via gpt-4.1-mini Chat Completions. Used
 * by the in-app "auto-translate messages" toggle to render each foreign
 * message in the reader's language.
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
    // Source and target match — no translation needed.
    return res.json({ translated: text });
  }
  try {
    const sys =
      `You are a translator. Translate the user's message into ${to}. ` +
      `Reply with the translated text ONLY, no quotes, no explanation, ` +
      `no language tags. Preserve emojis and proper nouns. If the message ` +
      `is already in ${to}, return it unchanged.`;
    const r = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${OPENAI_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: 'gpt-4.1-mini',
        messages: [
          { role: 'system', content: sys },
          { role: 'user', content: text },
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
    const translated = parsed?.choices?.[0]?.message?.content ?? '';
    // Token usage feeds the API-cost figure for in-app message
    // translation (gpt-4.1-mini), priced separately from realtime calls.
    track({
      event: 'text_translation',
      lang_from: from || undefined,
      lang_to: to,
      props: {
        model: 'gpt-4.1-mini',
        chars: text.length,
        prompt_tokens: parsed?.usage?.prompt_tokens ?? null,
        completion_tokens: parsed?.usage?.completion_tokens ?? null,
      },
    });
    return res.json({ translated });
  } catch (e) {
    // eslint-disable-next-line no-console
    console.error('translation text', e);
    return res.status(502).json({ error: 'openai_unreachable' });
  }
});

// Stripe Checkout — body: { tier: 'pro' | 'ultra' }. Authorization
// must carry the caller's Supabase JWT; the user_id is read from
// the verified token, never from the request body.
app.post('/api/stripe/checkout', async (req, res) => {
  const uid = await stripeAuthUserId(req);
  if (!uid) return res.status(401).json({ error: 'unauthenticated' });
  const tier = req.body?.tier;
  if (tier !== 'pro' && tier !== 'ultra') {
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

// "Someone is live" re-engagement fan-out. Called by the app when a user
// enters the live-call queue with nobody to pair with. Throttled two
// ways so it can never spam:
//   * global cooldown — at most one batch per LIVE_BROADCAST_COOLDOWN_MS,
//   * per recipient — at most one push per 24h (see notify.js).
// Requires the caller's Supabase JWT; their uid is excluded from the
// fan-out (no point notifying the host of their own call).
let lastLiveBroadcast = 0;
const LIVE_BROADCAST_COOLDOWN_MS = 15 * 60 * 1000;
app.post('/api/notify-live', async (req, res) => {
  const uid = await stripeAuthUserId(req);
  if (!uid) return res.status(401).json({ error: 'unauthenticated' });
  const now = Date.now();
  if (now - lastLiveBroadcast < LIVE_BROADCAST_COOLDOWN_MS) {
    return res.json({ skipped: 'cooldown' });
  }
  lastLiveBroadcast = now;
  try {
    const out = await broadcastLiveCall(uid);
    return res.json(out);
  } catch (e) {
    console.error('/api/notify-live error', e);
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
