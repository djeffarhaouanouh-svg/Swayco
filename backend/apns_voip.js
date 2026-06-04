'use strict';

// APNs VoIP push sender — wakes an iOS device's PushKit handler so it can
// report a CallKit incoming call (full-screen ring) even when the app is
// killed. FCM/firebase-admin cannot send VoIP pushes, so we talk to APNs
// directly over HTTP/2 with a token-based (.p8) provider key.
//
// Configuration (all required for VoIP to work; missing → no-op):
//   * APNS_AUTH_KEY    — the full contents of the AuthKey_XXXX.p8 file
//                        (the "-----BEGIN PRIVATE KEY----- …" block).
//   * APNS_KEY_ID      — the key's 10-char ID (e.g. ML4Q9NMY68).
//   * APNS_TEAM_ID     — the Apple Developer team ID (e.g. VXYW3LN267).
//   * APNS_BUNDLE_ID   — defaults to the app's bundle id; the VoIP topic
//                        is `<bundle>.voip`.
//   * APNS_USE_SANDBOX — set to "1" only for debug builds run from Xcode
//                        (sandbox APNs). TestFlight / App Store use prod.

const http2 = require('http2');

const AUTH_KEY = process.env.APNS_AUTH_KEY?.trim();
const KEY_ID = process.env.APNS_KEY_ID?.trim();
const TEAM_ID = process.env.APNS_TEAM_ID?.trim();
const BUNDLE_ID =
  process.env.APNS_BUNDLE_ID?.trim() || 'com.translate.livekit.livekitTranslate';
const PROD_HOST = 'https://api.push.apple.com';
const SANDBOX_HOST = 'https://api.sandbox.push.apple.com';
// APNs rejection reasons that mean "right token, wrong environment" — we
// retry the same token on the other host instead of giving up. Lets one
// backend serve both production (TestFlight/App Store) and sandbox (debug
// from Xcode) builds without knowing how the app was signed.
const ENV_MISMATCH_REASONS = new Set([
  'BadEnvironmentKeyInToken',
  'BadDeviceToken',
]);

function apnsConfigured() {
  return Boolean(AUTH_KEY && KEY_ID && TEAM_ID && BUNDLE_ID);
}

// APNs provider tokens are valid up to 60 min and should be reused (Apple
// rate-limits frequent token generation). Refresh every ~50 min.
let _cachedToken = null;
let _cachedAt = 0;
function providerToken() {
  const now = Date.now();
  if (_cachedToken && now - _cachedAt < 50 * 60 * 1000) return _cachedToken;
  // Lazy require so a missing dep can never crash server startup — it just
  // makes VoIP a no-op error at send time.
  const jwt = require('jsonwebtoken');
  _cachedToken = jwt.sign(
    { iss: TEAM_ID, iat: Math.floor(now / 1000) },
    AUTH_KEY,
    { algorithm: 'ES256', header: { alg: 'ES256', kid: KEY_ID } },
  );
  _cachedAt = now;
  return _cachedToken;
}

// Low-level: POST the VoIP push to ONE specific APNs host.
function _post(host, deviceToken, payload) {
  return new Promise((resolve) => {
    let settled = false;
    const done = (r) => {
      if (settled) return;
      settled = true;
      resolve(r);
    };

    let client;
    try {
      client = http2.connect(host);
    } catch (e) {
      return done({ ok: false, reason: e.message });
    }
    client.on('error', (e) => done({ ok: false, reason: e.message }));

    const body = JSON.stringify(payload);
    const req = client.request({
      ':method': 'POST',
      ':path': `/3/device/${deviceToken}`,
      authorization: `bearer ${providerToken()}`,
      'apns-topic': `${BUNDLE_ID}.voip`,
      'apns-push-type': 'voip',
      'apns-priority': '10',
      'content-type': 'application/json',
      'content-length': Buffer.byteLength(body),
    });

    let status = 0;
    let data = '';
    req.on('response', (headers) => {
      status = headers[':status'];
    });
    req.setEncoding('utf8');
    req.on('data', (chunk) => {
      data += chunk;
    });
    req.on('end', () => {
      try {
        client.close();
      } catch (_) {
        /* noop */
      }
      const ok = status >= 200 && status < 300;
      let reason;
      if (!ok) {
        try {
          reason = JSON.parse(data).reason;
        } catch (_) {
          reason = data || `status-${status}`;
        }
      }
      done({ ok, status, reason });
    });
    req.on('error', (e) => {
      try {
        client.close();
      } catch (_) {
        /* noop */
      }
      done({ ok: false, reason: e.message });
    });
    req.end(body);
  });
}

/**
 * Send a VoIP push to a single device token. Tries one APNs environment,
 * and if the token is rejected for being in the wrong environment, retries
 * on the other host — so the same backend works for both TestFlight/App
 * Store (production) and Xcode-debug (sandbox) builds without us having to
 * know how the app was signed. `APNS_USE_SANDBOX=1` just flips which host
 * is tried first.
 * @param {string} deviceToken hex VoIP token from PushKit.
 * @param {object} payload flat keys the iOS PushKit handler reads
 *   (callId, roomName, callerId, callerName, type).
 * @returns {Promise<{ok:boolean,status?:number,reason?:string}>}
 */
async function sendVoipPush(deviceToken, payload) {
  if (!apnsConfigured()) return { ok: false, reason: 'apns-not-configured' };
  if (!deviceToken) return { ok: false, reason: 'no-token' };

  const sandboxFirst = process.env.APNS_USE_SANDBOX === '1';
  const firstHost = sandboxFirst ? SANDBOX_HOST : PROD_HOST;
  const secondHost = sandboxFirst ? PROD_HOST : SANDBOX_HOST;

  // Verbose diagnosis: show the topic, token prefix, and what EACH APNs
  // environment replies, so a key/topic/environment problem is unambiguous.
  console.log(
    `[voip] topic=${BUNDLE_ID}.voip token=${deviceToken.slice(0, 12)}… ` +
      `key=${KEY_ID} team=${TEAM_ID}`,
  );
  let res = await _post(firstHost, deviceToken, payload);
  console.log(`[voip] ${firstHost} -> ${res.ok ? 'OK' : res.reason} (status ${res.status})`);
  if (!res.ok && ENV_MISMATCH_REASONS.has(res.reason)) {
    res = await _post(secondHost, deviceToken, payload);
    console.log(`[voip] ${secondHost} -> ${res.ok ? 'OK' : res.reason} (status ${res.status})`);
  }
  return res;
}

module.exports = { sendVoipPush, apnsConfigured };
