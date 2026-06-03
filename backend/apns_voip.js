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
const HOST =
  process.env.APNS_USE_SANDBOX === '1'
    ? 'https://api.sandbox.push.apple.com'
    : 'https://api.push.apple.com';

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

/**
 * Send a VoIP push to a single device token.
 * @param {string} deviceToken hex VoIP token from PushKit.
 * @param {object} payload flat keys the iOS PushKit handler reads
 *   (callId, roomName, callerId, callerName, type).
 * @returns {Promise<{ok:boolean,status?:number,reason?:string}>}
 */
function sendVoipPush(deviceToken, payload) {
  if (!apnsConfigured()) return Promise.resolve({ ok: false, reason: 'apns-not-configured' });
  if (!deviceToken) return Promise.resolve({ ok: false, reason: 'no-token' });

  return new Promise((resolve) => {
    let settled = false;
    const done = (r) => {
      if (settled) return;
      settled = true;
      resolve(r);
    };

    let client;
    try {
      client = http2.connect(HOST);
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

module.exports = { sendVoipPush, apnsConfigured };
