'use strict';

// Push-notification dispatcher. Fans out a single logical event to
// every Web Push subscription and FCM token registered for the
// recipient in `public.notification_targets`.
//
// Configuration (all optional — features lazy-load):
//   * Web Push:  VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT
//                ("mailto:you@example.com")
//   * FCM:       FIREBASE_SERVICE_ACCOUNT_JSON (the entire JSON pasted in
//                a single-line env var, OR FIREBASE_SERVICE_ACCOUNT_FILE
//                pointing to a JSON path on disk)
//   * Supabase:  SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY (required for
//                fan-out queries — we need to read every target row,
//                which RLS would otherwise gate on auth.uid())
//
// Without those env vars set, the relevant transport is a no-op:
//  - VAPID missing → web push targets skipped
//  - Firebase missing → fcm tokens skipped
//  - Supabase missing → endpoint returns 503

const { sendVoipPush, apnsConfigured } = require('./apns_voip');
const { maybeEmailNotification } = require('./email');

const SUPABASE_URL = process.env.SUPABASE_URL?.trim();
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY?.trim();
const VAPID_PUBLIC_KEY = process.env.VAPID_PUBLIC_KEY?.trim();
const VAPID_PRIVATE_KEY = process.env.VAPID_PRIVATE_KEY?.trim();
const VAPID_SUBJECT = process.env.VAPID_SUBJECT?.trim() || 'mailto:admin@example.com';

let _supabase = null;
function supabase() {
  if (_supabase) return _supabase;
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) return null;
  const { createClient } = require('@supabase/supabase-js');
  _supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return _supabase;
}

let _webPushReady = false;
function webPush() {
  const wp = require('web-push');
  if (_webPushReady) return wp;
  if (!VAPID_PUBLIC_KEY || !VAPID_PRIVATE_KEY) return null;
  wp.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);
  _webPushReady = true;
  return wp;
}

let _firebase = null;
function firebaseMessaging() {
  if (_firebase) return _firebase;
  let serviceAccount;
  const inline = process.env.FIREBASE_SERVICE_ACCOUNT_JSON?.trim();
  const filePath = process.env.FIREBASE_SERVICE_ACCOUNT_FILE?.trim();
  if (inline) {
    try {
      serviceAccount = JSON.parse(inline);
    } catch (e) {
      console.error('[notify] FIREBASE_SERVICE_ACCOUNT_JSON parse failed', e);
      return null;
    }
  } else if (filePath) {
    try {
      const fs = require('fs');
      serviceAccount = JSON.parse(fs.readFileSync(filePath, 'utf8'));
    } catch (e) {
      console.error('[notify] FIREBASE_SERVICE_ACCOUNT_FILE read failed', e);
      return null;
    }
  } else {
    return null;
  }
  const admin = require('firebase-admin');
  try {
    if (!admin.apps.length) {
      admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
    }
    _firebase = admin.messaging();
    return _firebase;
  } catch (e) {
    console.error('[notify] firebase-admin init failed', e);
    return null;
  }
}

/**
 * Fan-out push to every transport registered for `recipientUid`.
 * Returns a per-target outcome array so callers can log /
 * troubleshoot. Never throws — caller errors are surfaced in the array.
 *
 * `payload` shape:
 *   {
 *     title: 'Lenny',
 *     body:  '👋 Coucou !',
 *     type:  'message' | 'friend_request' | 'incoming_call' | 'like',
 *     data:  { conversationId?, callerId?, …optional extras }
 *   }
 */
/**
 * Remove, from a callee's target list, every device that is ALSO registered to
 * the caller — those are the caller's own phones and ringing them makes the
 * caller's device show an incoming call from itself. Only meaningful for
 * `incoming_call`; every other notification type passes straight through.
 */
async function withoutCallerDevices(sb, targets, payload) {
  const callerId = payload.type === 'incoming_call'
    ? String((payload.data || {}).callerId || '')
    : '';
  if (!callerId) return targets;

  const { data: mine, error } = await sb
    .from('notification_targets')
    .select('fcm_token, endpoint')
    .eq('user_id', callerId);
  // On a lookup failure, ring as before rather than silently dropping a call.
  if (error || !mine || mine.length === 0) return targets;

  const callerTokens = new Set(mine.map((t) => t.fcm_token).filter(Boolean));
  const callerEndpoints = new Set(mine.map((t) => t.endpoint).filter(Boolean));
  return targets.filter(
    (t) => !(t.fcm_token && callerTokens.has(t.fcm_token))
        && !(t.endpoint && callerEndpoints.has(t.endpoint)),
  );
}

async function notifyUser(recipientUid, payload) {
  const out = { ok: 0, failed: 0, results: [] };
  const sb = supabase();
  if (!sb) {
    out.results.push({ error: 'supabase-not-configured' });
    return out;
  }
  if (!recipientUid || !payload || !payload.title) {
    out.results.push({ error: 'invalid-args' });
    return out;
  }

  const { data: allTargets, error } = await sb
    .from('notification_targets')
    .select('*')
    .eq('user_id', recipientUid);
  if (error) {
    out.results.push({ error: error.message });
    return out;
  }
  if (!allTargets || allTargets.length === 0) {
    return out;
  }

  // A device the CALLER is signed into must never ring for the caller's own
  // call. Migration 0045 makes a token single-owner, but a device registered
  // to the callee before that shipped can still linger, and a phone can be
  // signed into both accounts across a reinstall. Drop any target of the
  // callee that is also one of the caller's own devices.
  const targets = await withoutCallerDevices(sb, allTargets, payload);
  if (targets.length === 0) {
    out.results.push({ skipped: 'all-targets-belong-to-caller' });
    return out;
  }

  const wp = webPush();
  const fcm = firebaseMessaging();

  await Promise.all(
    targets.map(async (t) => {
      try {
        if (t.platform === 'web') {
          if (!wp) {
            out.results.push({ id: t.id, skipped: 'vapid-missing' });
            return;
          }
          const subscription = {
            endpoint: t.endpoint,
            keys: { p256dh: t.p256dh, auth: t.auth_key },
          };
          await wp.sendNotification(
            subscription,
            JSON.stringify(payload),
            { TTL: 60 },
          );
          out.ok += 1;
          out.results.push({ id: t.id, sent: 'web' });
        } else if (t.platform === 'ios' || t.platform === 'android') {
          if (!fcm) {
            out.results.push({ id: t.id, skipped: 'firebase-missing' });
            return;
          }
          // Android incoming calls go out DATA-ONLY: a `notification`
          // block would make the OS draw a plain tray banner and skip our
          // Dart background isolate, so the full-screen WhatsApp-style
          // ringer (flutter_local_notifications, fullScreenIntent) would
          // never run. Without the notification block the background
          // handler wakes and builds the call UI itself — title/body are
          // passed inside `data` instead. iOS keeps the notification block
          // (CallKit/VoIP is a separate follow-up) so it still rings.
          const isCallAndroid =
            payload.type === 'incoming_call' && t.platform === 'android';
          const data = {
            ...Object.fromEntries(
              Object.entries(payload.data || {}).map(([k, v]) => [k, String(v)]),
            ),
            // Carry the notification type so a tap can route the app
            // to the right screen (see NotificationRouter on the client).
            ...(payload.type ? { type: String(payload.type) } : {}),
            ...(isCallAndroid
              ? { title: String(payload.title || ''), body: String(payload.body || '') }
              : {}),
          };
          const msg = {
            token: t.fcm_token,
            ...(isCallAndroid
              ? {}
              : { notification: { title: payload.title, body: payload.body || '' } }),
            data,
            android: { priority: 'high' },
            apns: {
              payload: { aps: { sound: 'default' } },
              headers: { 'apns-priority': '10' },
            },
          };
          await fcm.send(msg);
          out.ok += 1;
          out.results.push({ id: t.id, sent: t.platform });
        } else if (t.platform === 'ios_voip') {
          // iOS CallKit rides a VoIP push sent straight to APNs (FCM can't
          // send VoIP). Only calls use this transport — anything else would
          // just wake the device for nothing.
          if (payload.type !== 'incoming_call') {
            out.results.push({ id: t.id, skipped: 'voip-non-call' });
            return;
          }
          if (!apnsConfigured()) {
            out.results.push({ id: t.id, skipped: 'apns-not-configured' });
            return;
          }
          const d = payload.data || {};
          const res = await sendVoipPush(t.fcm_token, {
            type: 'incoming_call',
            callId: String(d.callId || ''),
            roomName: String(d.roomName || ''),
            callerId: String(d.callerId || ''),
            callerName: String(payload.title || ''),
          });
          if (res.ok) {
            out.ok += 1;
            out.results.push({ id: t.id, sent: 'ios_voip' });
          } else {
            out.failed += 1;
            out.results.push({ id: t.id, error: res.reason });
            // Only purge tokens APNs says are truly GONE. We deliberately do
            // NOT purge on BadDeviceToken / BadEnvironmentKeyInToken anymore:
            // those can indicate a config issue (wrong key/topic/environment)
            // rather than a dead token, and purging them every failed call was
            // making the row vanish before it could be inspected.
            if (res.status === 410 || res.reason === 'Unregistered') {
              await sb.from('notification_targets').delete().eq('id', t.id);
            }
          }
        } else {
          out.results.push({ id: t.id, skipped: 'unknown-platform' });
        }
      } catch (e) {
        out.failed += 1;
        out.results.push({ id: t.id, error: e?.message || String(e) });
        // Gone / expired subscription → purge so we stop re-trying.
        const status = e?.statusCode || e?.code;
        if (status === 404 || status === 410 ||
            status === 'messaging/registration-token-not-registered') {
          await sb.from('notification_targets').delete().eq('id', t.id);
        }
      }
    }),
  );

  // Re-engagement email fallback — best-effort, fire-and-forget so it never
  // adds latency to (or fails) the push path. Self-gates on offline + throttle
  // + opt-out inside, and no-ops entirely when RESEND_API_KEY is unset.
  maybeEmailNotification(sb, recipientUid, payload).catch(() => {});

  // Per-target outcome in the Railway logs so a missing push can be
  // diagnosed at a glance: e.g. `sent: ios_voip`, `error: BadDeviceToken`,
  // `skipped: apns-not-configured`.
  console.log(
    `[notify] uid=${recipientUid} type=${payload.type} ` +
      `ok=${out.ok} failed=${out.failed} ${JSON.stringify(out.results)}`,
  );

  return out;
}

module.exports = { notifyUser };
