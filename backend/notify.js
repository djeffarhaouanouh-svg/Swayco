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

function isHttpsImage(url) {
  if (typeof url !== 'string') return '';
  const u = url.trim();
  if (!/^https:\/\//i.test(u) || u.length > 2000) return '';
  return u;
}

function actorIdFromPayload(payload) {
  const d = payload.data || {};
  return String(
    d.senderId || d.callerId || d.requesterId || d.peerId || d.inviterId || '',
  );
}

/**
 * Instagram / Snap style: the tray shows the ACTOR's face, not the app logo.
 * `payload.image` wins when the client already has it. We look the rest up
 * from profiles — except friend_request, where a missing image is deliberate
 * (blurred likes must not leak a face).
 */
async function resolveActorImage(sb, payload) {
  const explicit = isHttpsImage(payload.image);
  if (explicit) return explicit;
  if (payload.type === 'friend_request' || payload.type === 'call_cancel') {
    return '';
  }
  const id = actorIdFromPayload(payload);
  if (!id) return '';
  const { data } = await sb
    .from('profiles')
    .select('avatar_url, discover_photo_url, photos')
    .eq('id', id)
    .maybeSingle();
  if (!data) return '';
  const photos = Array.isArray(data.photos) ? data.photos : [];
  return (
    isHttpsImage(data.avatar_url) ||
    isHttpsImage(data.discover_photo_url) ||
    isHttpsImage(photos[0]) ||
    ''
  );
}

// Pays (tel que stocke dans `profiles.country`, en francais) -> code ISO2.
// Meme liste que `_kIso2` de lib/services/locations.dart.
const COUNTRY_ISO2 = {
  'France': 'fr', 'Belgique': 'be', 'Suisse': 'ch', 'Canada': 'ca',
  'États-Unis': 'us', 'Royaume-Uni': 'gb', 'Espagne': 'es', 'Portugal': 'pt',
  'Italie': 'it', 'Allemagne': 'de', 'Pays-Bas': 'nl', 'Mexique': 'mx',
  'Argentine': 'ar', 'Colombie': 'co', 'Brésil': 'br', 'Maroc': 'ma',
  'Algérie': 'dz', 'Tunisie': 'tn', 'Sénégal': 'sn', "Côte d'Ivoire": 'ci',
  'Égypte': 'eg', 'Arabie Saoudite': 'sa', 'Émirats arabes unis': 'ae',
  'Turquie': 'tr', 'Russie': 'ru', 'Chine': 'cn', 'Japon': 'jp',
  'Corée du Sud': 'kr', 'Inde': 'in', 'Australie': 'au', 'Luxembourg': 'lu',
  'Islande': 'is', 'Norvège': 'no', 'Suède': 'se', 'Danemark': 'dk',
  'Finlande': 'fi', 'Irlande': 'ie', 'Pologne': 'pl', 'Ukraine': 'ua',
  'Grèce': 'gr',
};

function flagEmoji(iso2) {
  if (!/^[a-z]{2}$/i.test(iso2 || '')) return '';
  return String.fromCodePoint(
    ...iso2.toUpperCase().split('').map((c) => 127397 + c.charCodeAt(0)),
  );
}

/**
 * Drapeau (emoji) du pays de celui qui fait l'action, ou ''.
 *
 * Seulement AVANT la rencontre : la presentation (demande, signe, message
 * special, message d'un inconnu) porte le drapeau, pour dire d'ou vient la
 * personne. Une fois qu'ils se sont likes (amitie acceptee) ou au moment du
 * match, on n'en met plus : ils se connaissent.
 */
async function resolveActorFlag(sb, payload, recipientUid) {
  const id = actorIdFromPayload(payload);
  if (!id) return '';
  if (payload.type === 'match') return '';
  try {
    const isUuid = (s) => /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(String(s));
    if (recipientUid && isUuid(id) && isUuid(recipientUid)) {
      const { data: rows } = await sb
        .from('friendships')
        .select('id')
        .eq('status', 'accepted')
        .or(
          `and(requester.eq.${id},addressee.eq.${recipientUid}),` +
            `and(requester.eq.${recipientUid},addressee.eq.${id})`,
        )
        .limit(1);
      if (rows && rows.length > 0) return '';
    }
    const { data } = await sb
      .from('profiles')
      .select('country')
      .eq('id', id)
      .maybeSingle();
    return flagEmoji(COUNTRY_ISO2[String((data && data.country) || '').trim()]);
  } catch (_) {
    return '';
  }
}

/**
 * Le drapeau remplace les emojis decoratifs des notifications : « Léa t'a
 * ajouté 🇧🇷 ». Sur un message le corps est le texte de la personne, donc le
 * drapeau va a cote de son nom (titre) ; partout ailleurs, en fin de phrase.
 * Les appels (CallKit / sonnerie) restent tels quels.
 */
function withActorFlag(payload, flag) {
  if (!flag) return payload;
  const t = payload.type;
  if (t === 'incoming_call' || t === 'call_cancel') return payload;
  const d = payload.data || {};
  const isPlainMessage =
    t === 'message' && d.kind !== 'reaction' && String(d.special || '') !== 'true';
  if (isPlainMessage) return { ...payload, title: `${payload.title} ${flag}` };
  return { ...payload, body: `${payload.body || ''} ${flag}`.trim() };
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

  // Call mute: if this is an incoming call and the callee has muted the
  // caller, drop the whole push — this is the only way to keep iOS CallKit
  // (which rings straight from the VoIP push) silent for that pair.
  if (payload.type === 'incoming_call') {
    const callerId = String((payload.data || {}).callerId || '');
    if (callerId) {
      const { data: prof } = await sb
        .from('profiles')
        .select('muted_call_peers')
        .eq('id', recipientUid)
        .maybeSingle();
      const muted = (prof && prof.muted_call_peers) || [];
      if (Array.isArray(muted) && muted.includes(callerId)) {
        out.results.push({ skipped: 'callee-muted-caller' });
        return out;
      }
    }
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
  const imageUrl = await resolveActorImage(sb, payload);
  const flag = await resolveActorFlag(sb, payload, recipientUid);
  const flagged = withActorFlag(payload, flag);
  const payloadOut = imageUrl ? { ...flagged, image: imageUrl } : flagged;

  await Promise.all(
    targets.map(async (t) => {
      try {
        if (payload.type === 'call_cancel' && t.platform === 'web') {
          // Nothing to stop on web: the ring there is a DOM dialog owned by a
          // tab that is, by definition, already running — the realtime cancel
          // reaches it directly.
          out.results.push({ id: t.id, skipped: 'cancel-not-web' });
          return;
        }
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
            JSON.stringify(payloadOut),
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
          // Le renoncement voyage comme la sonnerie : DONNÉES SEULES, pas de
          // bloc `notification`. Deux raisons, et les deux comptent. Un bloc
          // `notification` ne réveille pas l'isolat Dart quand l'app est morte,
          // et c'est précisément là qu'il faut agir : la sonnerie Android est
          // `ongoing`, l'utilisateur ne peut pas la balayer, seul du code la
          // retire. Et il afficherait une bannière — pour un message dont le
          // seul rôle est d'en EFFACER une.
          //
          // Ce cas ne partait pas du tout vers Android : « le chemin où l'app
          // est vivante s'en charge par le temps réel », disait le commentaire.
          // Vrai, sauf que l'app morte est le seul cas où la notification
          // existe.
          const isCallAndroid =
            (payload.type === 'incoming_call' ||
              payload.type === 'call_cancel') &&
            t.platform === 'android';
          // Instagram / Snap style sur Android : quand on a la photo de
          // l'acteur, la notification part en DONNEES SEULES et c'est l'app
          // (isolat Dart, flutter_local_notifications) qui la dessine avec la
          // photo en GRANDE ICONE ronde a la place du logo. Un bloc
          // `notification` serait dessine par le systeme, avec le logo.
          // Sans photo (ex. demande d'ami floue) : bloc `notification` normal.
          const dataOnlyAndroid =
            isCallAndroid || (t.platform === 'android' && !!imageUrl);
          const data = {
            ...Object.fromEntries(
              Object.entries(payload.data || {}).map(([k, v]) => [k, String(v)]),
            ),
            // Carry the notification type so a tap can route the app
            // to the right screen (see NotificationRouter on the client).
            ...(payload.type ? { type: String(payload.type) } : {}),
            ...(dataOnlyAndroid
              ? { title: String(payloadOut.title || ''), body: String(payloadOut.body || '') }
              : {}),
            ...(imageUrl ? { imageUrl } : {}),
          };
          const msg = {
            token: t.fcm_token,
            ...(dataOnlyAndroid
              ? {}
              : {
                  notification: {
                    title: payloadOut.title,
                    body: payloadOut.body || '',
                    ...(imageUrl ? { image: imageUrl } : {}),
                  },
                }),
            data,
            android: {
              priority: 'high',
              ...(!dataOnlyAndroid && imageUrl
                ? { notification: { imageUrl } }
                : {}),
            },
            apns: {
              payload: {
                aps: {
                  sound: 'default',
                  ...(!isCallAndroid && imageUrl
                    ? { 'mutable-content': 1 }
                    : {}),
                },
              },
              headers: { 'apns-priority': '10' },
              ...(!isCallAndroid && imageUrl
                ? { fcmOptions: { imageUrl } }
                : {}),
            },
          };
          await fcm.send(msg);
          out.ok += 1;
          out.results.push({ id: t.id, sent: t.platform });
        } else if (t.platform === 'ios_voip') {
          // iOS CallKit rides a VoIP push sent straight to APNs (FCM can't
          // send VoIP). Only calls use this transport: the ring
          // ('incoming_call') and its cancel ('call_cancel', which tells the
          // native side to end the CallKit ring — see AppDelegate.swift).
          if (payload.type !== 'incoming_call' && payload.type !== 'call_cancel') {
            out.results.push({ id: t.id, skipped: 'voip-non-call' });
            return;
          }
          if (!apnsConfigured()) {
            out.results.push({ id: t.id, skipped: 'apns-not-configured' });
            return;
          }
          const d = payload.data || {};
          const res = await sendVoipPush(t.fcm_token, {
            type: String(payload.type),
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
  maybeEmailNotification(sb, recipientUid, payloadOut).catch(() => {});

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
