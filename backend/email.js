'use strict';

// Re-engagement emails via Resend. When a user RECEIVES an interaction
// (message / call / like / friend request / invite / scheduled call) while
// OFFLINE, and we haven't emailed them recently, send a localised
// "you've got something new" email so they come back — the same pattern Mym /
// Tinder use. Push stays the primary channel; email is the fallback for users
// who aren't in the app.
//
// Config (all optional — sending no-ops without the key):
//   RESEND_API_KEY     Resend API key. Required to actually send.
//   EMAIL_FROM         "Swayco <notifications@swayco.fr>" (verified domain).
//   PUBLIC_BASE_URL    Base for the unsubscribe link (default www.swayco.fr).
//   EMAIL_APP_URL      Where the CTA button points (default www.swayco.fr).
//   EMAIL_OFFLINE_MS   Only email users idle longer than this (default 3 min).
//   EMAIL_THROTTLE_MS  At most one email per user per window (default 30 min).

const RESEND_API_KEY = process.env.RESEND_API_KEY?.trim();
const EMAIL_FROM =
  process.env.EMAIL_FROM?.trim() || 'Swayco <notifications@swayco.fr>';
const PUBLIC_BASE_URL = (
  process.env.PUBLIC_BASE_URL?.trim() || 'https://www.swayco.fr'
).replace(/\/$/, '');
const APP_URL = process.env.EMAIL_APP_URL?.trim() || 'https://www.swayco.fr';
const OFFLINE_MS = Number(process.env.EMAIL_OFFLINE_MS || 3 * 60 * 1000);
const THROTTLE_MS = Number(process.env.EMAIL_THROTTLE_MS || 30 * 60 * 1000);

// Only "someone interacted with you" events trigger an email — never the
// time-sensitive reminder or the marketing broadcast.
const EMAIL_TYPES = new Set([
  'message',
  'incoming_call',
  'like',
  'friend_request',
  'call_invite',
  'call_scheduled',
  'reaction',
]);

// Email chrome, localised into the RECIPIENT's language. The headline + line
// are reused from the (already-localised) push title/body, so only the wrapper
// strings live here. Falls back to English.
const EMAIL_I18N = {
  fr: { subject: 'Vous avez du nouveau sur Swayco', cta: 'Ouvrir Swayco', unsub: 'Se désabonner', footer: 'Vous recevez cet e-mail car vous avez un compte Swayco.' },
  en: { subject: 'You have something new on Swayco', cta: 'Open Swayco', unsub: 'Unsubscribe', footer: 'You receive this email because you have a Swayco account.' },
  es: { subject: 'Tienes algo nuevo en Swayco', cta: 'Abrir Swayco', unsub: 'Darse de baja', footer: 'Recibes este correo porque tienes una cuenta de Swayco.' },
  de: { subject: 'Es gibt Neues auf Swayco', cta: 'Swayco öffnen', unsub: 'Abmelden', footer: 'Du erhältst diese E-Mail, weil du ein Swayco-Konto hast.' },
  it: { subject: 'Hai qualcosa di nuovo su Swayco', cta: 'Apri Swayco', unsub: 'Annulla iscrizione', footer: 'Ricevi questa email perché hai un account Swayco.' },
  pt: { subject: 'Tens algo novo no Swayco', cta: 'Abrir Swayco', unsub: 'Cancelar subscrição', footer: 'Recebes este email porque tens uma conta Swayco.' },
  nl: { subject: 'Er is iets nieuws op Swayco', cta: 'Swayco openen', unsub: 'Afmelden', footer: 'Je ontvangt deze e-mail omdat je een Swayco-account hebt.' },
  ar: { subject: 'لديك جديد على Swayco', cta: 'افتح Swayco', unsub: 'إلغاء الاشتراك', footer: 'تتلقى هذا البريد لأن لديك حساب على Swayco.' },
  ru: { subject: 'У вас новое событие в Swayco', cta: 'Открыть Swayco', unsub: 'Отписаться', footer: 'Вы получили это письмо, потому что у вас есть аккаунт Swayco.' },
  zh: { subject: '你在 Swayco 上有新消息', cta: '打开 Swayco', unsub: '取消订阅', footer: '你收到这封邮件是因为你拥有 Swayco 账户。' },
  ja: { subject: 'Swayco に新しいお知らせがあります', cta: 'Swayco を開く', unsub: '配信停止', footer: 'Swayco のアカウントをお持ちのため、このメールをお送りしています。' },
  ko: { subject: 'Swayco에 새로운 소식이 있어요', cta: 'Swayco 열기', unsub: '수신 거부', footer: 'Swayco 계정이 있어 이 이메일을 받았습니다.' },
};

function i18n(lang) {
  const code = String(lang || '').toLowerCase().split(/[-_]/)[0];
  return EMAIL_I18N[code] || EMAIL_I18N.en;
}

function escapeHtml(s) {
  return String(s || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function renderHtml(lang, title, body, unsubUrl) {
  const t = i18n(lang);
  const dir = String(lang || '').toLowerCase().startsWith('ar') ? 'rtl' : 'ltr';
  const preview = body.length > 140 ? `${body.slice(0, 139)}…` : body;
  return `<!doctype html><html dir="${dir}"><body style="margin:0;background:#0e0e0e;">
  <div style="font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;max-width:480px;margin:0 auto;padding:32px 24px;color:#ffffff;">
    <div style="font-size:22px;font-weight:800;margin-bottom:24px;">swayco<span style="color:#00BCD4;">.ai</span></div>
    <div style="font-size:19px;font-weight:700;margin-bottom:6px;">${escapeHtml(title)}</div>
    <div style="font-size:15px;color:#bbbbbb;margin-bottom:24px;">${escapeHtml(preview)}</div>
    <a href="${APP_URL}" style="display:inline-block;background:#00BCD4;color:#ffffff;font-weight:700;padding:13px 22px;border-radius:12px;text-decoration:none;">${escapeHtml(t.cta)}</a>
    <div style="font-size:12px;color:#777777;margin-top:32px;line-height:1.5;">${escapeHtml(t.footer)}<br><a href="${unsubUrl}" style="color:#777777;">${escapeHtml(t.unsub)}</a></div>
  </div></body></html>`;
}

async function sendEmail({ to, subject, html }) {
  if (!RESEND_API_KEY) return { ok: false, error: 'resend-not-configured' };
  if (!to) return { ok: false, error: 'no-recipient' };
  try {
    const r = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${RESEND_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ from: EMAIL_FROM, to, subject, html }),
    });
    if (!r.ok) {
      const txt = await r.text().catch(() => '');
      return { ok: false, error: `resend-${r.status}: ${txt.slice(0, 200)}` };
    }
    return { ok: true };
  } catch (e) {
    return { ok: false, error: e?.message || String(e) };
  }
}

// Decide whether to email [uid] about [payload], and do it. Best-effort —
// swallows every error so it can never affect the push path. [sb] is the
// caller's service-role Supabase client (reused, no second connection).
async function maybeEmailNotification(sb, uid, payload) {
  try {
    if (!RESEND_API_KEY) return;
    if (!sb || !uid || !payload || !EMAIL_TYPES.has(payload.type)) return;

    const { data: prof } = await sb
      .from('profiles')
      .select(
        'language, last_seen, email_notifications, last_email_at, email_unsub_token',
      )
      .eq('id', uid)
      .maybeSingle();
    if (!prof || prof.email_notifications === false) return;

    const now = Date.now();
    const lastSeen = prof.last_seen ? Date.parse(prof.last_seen) : 0;
    if (lastSeen && now - lastSeen < OFFLINE_MS) return; // in-app → push is enough
    const lastEmail = prof.last_email_at ? Date.parse(prof.last_email_at) : 0;
    if (lastEmail && now - lastEmail < THROTTLE_MS) return; // emailed recently

    const { data: u } = await sb.auth.admin.getUserById(uid);
    const to = u?.user?.email;
    if (!to) return;

    const t = i18n(prof.language);
    const unsubUrl = `${PUBLIC_BASE_URL}/email/unsubscribe?u=${encodeURIComponent(
      uid,
    )}&t=${encodeURIComponent(prof.email_unsub_token || '')}`;
    const html = renderHtml(
      prof.language,
      payload.title || t.subject,
      payload.body || '',
      unsubUrl,
    );
    const res = await sendEmail({ to, subject: t.subject, html });
    if (res.ok) {
      await sb
        .from('profiles')
        .update({ last_email_at: new Date().toISOString() })
        .eq('id', uid);
      console.log(`[email] sent uid=${uid} type=${payload.type}`);
    } else {
      console.error(`[email] failed uid=${uid}: ${res.error}`);
    }
  } catch (e) {
    console.error('[email] maybeEmailNotification error', e?.message || e);
  }
}

module.exports = { sendEmail, maybeEmailNotification };
