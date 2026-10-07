'use strict';

// ─────────────────────────────────────────────────────────────────────────────
// Notifications d'engagement, planifiees cote serveur (zero dependance : un
// minuteur dans le processus, comme le diffuseur « X en ligne » et les rappels
// d'appel planifie).
//
//   pending_requests  des demandes d'ami attendent depuis 24 h
//   say_hello         amis depuis 24 h, aucun message echange
//   unread_message    un message recu il y a 24 h n'a pas ete ouvert
//   boost_ending      le Boost se termine dans ~1 h
//   weekly_recap      le dimanche soir : amis, pays, demandes de la semaine
//
// Garde-fous : jamais deux fois la meme chose (table `notif_log`, migration
// 0066, on ECRIT avant d'envoyer pour qu'un echec ne boucle pas), au plus
// DAILY_CAP notifications d'engagement par personne et par jour, et seulement
// entre 9 h et 21 h dans le fuseau de la personne (deduit de son pays).
// Si `notif_log` n'existe pas encore, tout est suspendu : mieux vaut rien
// envoyer que renvoyer en boucle.
// ─────────────────────────────────────────────────────────────────────────────

const TICK_MS = 10 * 60 * 1000;
const DAILY_CAP = 2;
const DAY = 24 * 60 * 60 * 1000;

// Pays (tel que stocke dans `profiles.country`) -> fuseau principal.
const COUNTRY_TZ = {
  'France': 'Europe/Paris', 'Belgique': 'Europe/Brussels',
  'Suisse': 'Europe/Zurich', 'Canada': 'America/Toronto',
  'États-Unis': 'America/New_York', 'Royaume-Uni': 'Europe/London',
  'Espagne': 'Europe/Madrid', 'Portugal': 'Europe/Lisbon',
  'Italie': 'Europe/Rome', 'Allemagne': 'Europe/Berlin',
  'Pays-Bas': 'Europe/Amsterdam', 'Mexique': 'America/Mexico_City',
  'Argentine': 'America/Argentina/Buenos_Aires', 'Colombie': 'America/Bogota',
  'Brésil': 'America/Sao_Paulo', 'Maroc': 'Africa/Casablanca',
  'Algérie': 'Africa/Algiers', 'Tunisie': 'Africa/Tunis',
  'Sénégal': 'Africa/Dakar', "Côte d'Ivoire": 'Africa/Abidjan',
  'Égypte': 'Africa/Cairo', 'Arabie Saoudite': 'Asia/Riyadh',
  'Émirats arabes unis': 'Asia/Dubai', 'Turquie': 'Europe/Istanbul',
  'Russie': 'Europe/Moscow', 'Chine': 'Asia/Shanghai', 'Japon': 'Asia/Tokyo',
  'Corée du Sud': 'Asia/Seoul', 'Inde': 'Asia/Kolkata',
  'Australie': 'Australia/Sydney', 'Luxembourg': 'Europe/Luxembourg',
  'Islande': 'Atlantic/Reykjavik', 'Norvège': 'Europe/Oslo',
  'Suède': 'Europe/Stockholm', 'Danemark': 'Europe/Copenhagen',
  'Finlande': 'Europe/Helsinki', 'Irlande': 'Europe/Dublin',
  'Pologne': 'Europe/Warsaw', 'Ukraine': 'Europe/Kyiv', 'Grèce': 'Europe/Athens',
};

// ── Textes, localises dans la langue du DESTINATAIRE ─────────────────────────
// {name} / {n} sont remplaces. Les comptes passent en « libelle : valeur » pour
// ne dependre d'aucune regle de pluriel (ru, ar...).
const T = {
  pending_requests: {
    fr: ['Ils attendent ta réponse', 'Demandes en attente : {n}'],
    en: ["They're waiting for you", 'Pending requests: {n}'],
    es: ['Esperan tu respuesta', 'Solicitudes pendientes: {n}'],
    de: ['Sie warten auf deine Antwort', 'Offene Anfragen: {n}'],
    it: ['Aspettano la tua risposta', 'Richieste in attesa: {n}'],
    pt: ['Estão à espera da tua resposta', 'Pedidos pendentes: {n}'],
    nl: ['Ze wachten op je antwoord', 'Openstaande verzoeken: {n}'],
    ar: ['ينتظرون ردّك', 'طلبات معلّقة: {n}'],
    ru: ['Они ждут твоего ответа', 'Ожидающие заявки: {n}'],
    zh: ['他们在等你回复', '待处理的请求：{n}'],
    ja: ['返事を待っています', '保留中のリクエスト：{n}'],
    ko: ['답장을 기다리고 있어요', '대기 중인 요청: {n}'],
  },
  say_hello: {
    fr: ['Dis bonjour à {name}', 'Vous êtes amis depuis hier.'],
    en: ['Say hi to {name}', "You've been friends since yesterday."],
    es: ['Saluda a {name}', 'Sois amigos desde ayer.'],
    de: ['Sag Hallo zu {name}', 'Ihr seid seit gestern befreundet.'],
    it: ['Saluta {name}', 'Siete amici da ieri.'],
    pt: ['Diz olá a {name}', 'São amigos desde ontem.'],
    nl: ['Zeg hoi tegen {name}', 'Jullie zijn sinds gisteren vrienden.'],
    ar: ['قل مرحبًا لـ {name}', 'أنتما صديقان منذ أمس.'],
    ru: ['Поздоровайся с {name}', 'Вы друзья со вчерашнего дня.'],
    zh: ['和 {name} 打个招呼', '你们从昨天起成为朋友。'],
    ja: ['{name}さんに挨拶しよう', '昨日から友達です。'],
    ko: ['{name}님에게 인사해 보세요', '어제부터 친구예요.'],
  },
  unread_message: {
    fr: ["{name} t'a écrit", "Tu n'as pas encore répondu."],
    en: ['{name} wrote to you', "You haven't replied yet."],
    es: ['{name} te escribió', 'Aún no has respondido.'],
    de: ['{name} hat dir geschrieben', 'Du hast noch nicht geantwortet.'],
    it: ['{name} ti ha scritto', 'Non hai ancora risposto.'],
    pt: ['{name} escreveu-te', 'Ainda não respondeste.'],
    nl: ['{name} heeft je geschreven', 'Je hebt nog niet geantwoord.'],
    ar: ['{name} راسلك', 'لم تردّ بعد.'],
    ru: ['{name} написал(а) тебе', 'Ты ещё не ответил(а).'],
    zh: ['{name} 给你发了消息', '你还没有回复。'],
    ja: ['{name}さんからメッセージ', 'まだ返信していません。'],
    ko: ['{name}님이 메시지를 보냈어요', '아직 답장하지 않았어요.'],
  },
  boost_ending: {
    fr: ['Ton Boost se termine bientôt', "Plus qu'environ 1 h en tête de la liste."],
    en: ['Your Boost ends soon', 'About 1 hour left at the top of the list.'],
    es: ['Tu Boost termina pronto', 'Queda aproximadamente 1 h al principio de la lista.'],
    de: ['Dein Boost endet bald', 'Noch etwa 1 Std. an der Spitze der Liste.'],
    it: ['Il tuo Boost sta per finire', 'Manca circa 1 ora in cima alla lista.'],
    pt: ['O teu Boost termina em breve', 'Falta cerca de 1 h no topo da lista.'],
    nl: ['Je Boost eindigt binnenkort', 'Nog ongeveer 1 uur bovenaan de lijst.'],
    ar: ['ينتهي البوست قريبًا', 'تبقّت حوالي ساعة في أعلى القائمة.'],
    ru: ['Твой буст скоро закончится', 'Осталось около 1 ч в начале списка.'],
    zh: ['你的加速即将结束', '在列表顶部还剩约 1 小时。'],
    ja: ['ブーストがまもなく終了', 'リストの先頭に表示されるのはあと約1時間です。'],
    ko: ['부스트가 곧 끝나요', '목록 맨 위에 약 1시간 남았어요.'],
  },
  // [titre, libelle amis, libelle pays, libelle demandes]
  weekly_recap: {
    fr: ['Ta semaine sur Swayco', 'Nouveaux amis', 'Pays découverts', 'Demandes reçues'],
    en: ['Your week on Swayco', 'New friends', 'Countries discovered', 'Requests received'],
    es: ['Tu semana en Swayco', 'Nuevos amigos', 'Países descubiertos', 'Solicitudes recibidas'],
    de: ['Deine Woche auf Swayco', 'Neue Freunde', 'Entdeckte Länder', 'Erhaltene Anfragen'],
    it: ['La tua settimana su Swayco', 'Nuovi amici', 'Paesi scoperti', 'Richieste ricevute'],
    pt: ['A tua semana no Swayco', 'Novos amigos', 'Países descobertos', 'Pedidos recebidos'],
    nl: ['Jouw week op Swayco', 'Nieuwe vrienden', 'Ontdekte landen', 'Ontvangen verzoeken'],
    ar: ['أسبوعك على Swayco', 'أصدقاء جدد', 'بلدان مكتشفة', 'طلبات مستلمة'],
    ru: ['Твоя неделя в Swayco', 'Новые друзья', 'Открытые страны', 'Полученные заявки'],
    zh: ['你在 Swayco 的这一周', '新朋友', '探索的国家', '收到的请求'],
    ja: ['Swaycoでの1週間', '新しい友達', '発見した国', '受け取ったリクエスト'],
    ko: ['Swayco에서의 한 주', '새 친구', '발견한 나라', '받은 요청'],
  },
};

function pick(kind, lang) {
  const code = String(lang || '').toLowerCase().split(/[-_]/)[0];
  const m = T[kind];
  return m[code] || m.en;
}

function fill(s, vars) {
  return String(s).replace(/\{(\w+)\}/g, (_, k) =>
    vars && vars[k] != null ? String(vars[k]) : '');
}

// ── Heure locale ─────────────────────────────────────────────────────────────

function localParts(tz, at = new Date()) {
  try {
    const f = new Intl.DateTimeFormat('en-GB', {
      timeZone: tz, hour: 'numeric', hourCycle: 'h23', weekday: 'short',
    });
    const parts = Object.fromEntries(
      f.formatToParts(at).map((p) => [p.type, p.value]),
    );
    return { hour: Number(parts.hour), weekday: parts.weekday };
  } catch (_) {
    return null;
  }
}

function tzOf(country) {
  return COUNTRY_TZ[String(country || '').trim()] || 'Europe/Paris';
}

/** Entre 9 h et 21 h chez la personne ? */
function awake(country) {
  const p = localParts(tzOf(country));
  return !!p && p.hour >= 9 && p.hour < 21;
}

function isoWeek(date = new Date()) {
  const d = new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate()));
  const dayNum = d.getUTCDay() || 7;
  d.setUTCDate(d.getUTCDate() + 4 - dayNum);
  const yearStart = new Date(Date.UTC(d.getUTCFullYear(), 0, 1));
  const week = Math.ceil(((d - yearStart) / DAY + 1) / 7);
  return `${d.getUTCFullYear()}-W${week}`;
}

const UUID = /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;

function convIdFor(a, b) {
  const [x, y] = [String(a), String(b)].sort();
  return `dm-${x}-${y}`;
}

// ── Journal : une fois, jamais deux ──────────────────────────────────────────

async function logAvailable(sb) {
  const { error } = await sb.from('notif_log').select('id').limit(1);
  if (!error) return true;
  return false;
}

/** Ecrit la ligne AVANT d'envoyer. false = deja envoye (ou impossible). */
async function claim(sb, userId, kind, ref) {
  const { error } = await sb
    .from('notif_log')
    .insert({ user_id: userId, kind, ref: String(ref) });
  return !error;
}

async function sentLast24h(sb, userId) {
  const since = new Date(Date.now() - DAY).toISOString();
  const { count } = await sb
    .from('notif_log')
    .select('id', { count: 'exact', head: true })
    .eq('user_id', userId)
    .gte('sent_at', since);
  return count || 0;
}

async function profilesById(sb, ids) {
  const out = new Map();
  const list = [...new Set(ids.filter((i) => UUID.test(String(i))))];
  for (let i = 0; i < list.length; i += 200) {
    const { data } = await sb
      .from('profiles')
      .select('id, display_name, language, country')
      .in('id', list.slice(i, i + 200));
    for (const p of data || []) out.set(p.id, p);
  }
  return out;
}

// ── Les taches ───────────────────────────────────────────────────────────────

/** Envoie en respectant le plafond et les heures calmes. */
async function deliver(ctx, userId, profile, kind, ref, payload) {
  if (!profile || !awake(profile.country)) return false;
  if ((await sentLast24h(ctx.sb, userId)) >= DAILY_CAP) return false;
  if (!(await claim(ctx.sb, userId, kind, ref))) return false;
  try {
    await ctx.notifyUser(userId, payload);
    return true;
  } catch (e) {
    console.error(`[engage] ${kind} notify error`, e?.message || e);
    return false;
  }
}

async function pendingRequests(ctx) {
  const { sb } = ctx;
  const old = new Date(Date.now() - DAY).toISOString();
  const recent = new Date(Date.now() - 7 * DAY).toISOString();
  const { data: rows } = await sb
    .from('friendships')
    .select('addressee')
    .eq('status', 'pending')
    .lt('created_at', old)
    .gt('created_at', recent)
    .limit(2000);
  const counts = new Map();
  for (const r of rows || []) {
    counts.set(r.addressee, (counts.get(r.addressee) || 0) + 1);
  }
  if (counts.size === 0) return 0;
  const people = await profilesById(sb, [...counts.keys()]);
  const bucket = Math.floor(Date.now() / (3 * DAY)); // au plus une fois / 3 jours
  let sent = 0;
  for (const [uid, n] of counts) {
    const p = people.get(uid);
    const [title, body] = pick('pending_requests', p && p.language);
    const ok = await deliver(ctx, uid, p, 'pending_requests', `b${bucket}`, {
      title,
      body: fill(body, { n }),
      type: 'pending_requests',
      data: { count: String(n) },
    });
    if (ok) sent += 1;
  }
  return sent;
}

async function sayHello(ctx) {
  const { sb } = ctx;
  const from = new Date(Date.now() - 2 * DAY).toISOString();
  const to = new Date(Date.now() - DAY).toISOString();
  const { data: rows } = await sb
    .from('friendships')
    .select('id, requester, addressee')
    .eq('status', 'accepted')
    .gte('responded_at', from)
    .lt('responded_at', to)
    .limit(500);
  if (!rows || rows.length === 0) return 0;
  const people = await profilesById(
    sb, rows.flatMap((r) => [r.requester, r.addressee]));
  let sent = 0;
  for (const r of rows) {
    if (!UUID.test(String(r.requester)) || !UUID.test(String(r.addressee))) continue;
    const conv = convIdFor(r.requester, r.addressee);
    const { data: msgs } = await sb
      .from('messages')
      .select('id')
      .eq('conversation_id', conv)
      .limit(1);
    if (msgs && msgs.length > 0) continue; // ils se parlent deja
    for (const [me, other] of [[r.requester, r.addressee], [r.addressee, r.requester]]) {
      const p = people.get(me);
      const o = people.get(other);
      const name = (o && o.display_name ? String(o.display_name).trim() : '').split(/\s+/)[0];
      const [title, body] = pick('say_hello', p && p.language);
      const ok = await deliver(ctx, me, p, 'say_hello', r.id, {
        title: fill(title, { name }).trim(),
        body,
        type: 'say_hello',
        data: { senderId: String(other), conversationId: conv },
      });
      if (ok) sent += 1;
    }
  }
  return sent;
}

async function unreadMessages(ctx) {
  const { sb } = ctx;
  const from = new Date(Date.now() - 2 * DAY).toISOString();
  const to = new Date(Date.now() - DAY).toISOString();
  const { data: msgs, error } = await sb
    .from('messages')
    .select('id, sender, recipient, conversation_id, created_at')
    .gte('created_at', from)
    .lt('created_at', to)
    .not('recipient', 'is', null)
    .order('created_at', { ascending: false })
    .limit(800);
  if (error || !msgs || msgs.length === 0) return 0;

  // Le plus recent par destinataire.
  const latest = new Map();
  for (const m of msgs) {
    if (!UUID.test(String(m.recipient)) || m.sender === m.recipient) continue;
    if (!latest.has(m.recipient)) latest.set(m.recipient, m);
  }
  const recipients = [...latest.keys()];
  if (recipients.length === 0) return 0;

  // Deja ouvert ? (table conversation_reads, migration 0054 ; absente => on
  // ne sait pas, donc on n'envoie rien plutot que d'inonder.)
  const { data: reads, error: rErr } = await sb
    .from('conversation_reads')
    .select('conversation_id, user_id, last_read_at')
    .in('user_id', recipients)
    .in('conversation_id', [...new Set([...latest.values()].map((m) => m.conversation_id))]);
  if (rErr) return 0;
  const readAt = new Map();
  for (const r of reads || []) {
    readAt.set(`${r.user_id}|${r.conversation_id}`, Date.parse(r.last_read_at) || 0);
  }

  const people = await profilesById(
    sb, [...recipients, ...[...latest.values()].map((m) => m.sender)]);
  let sent = 0;
  for (const [uid, m] of latest) {
    const read = readAt.get(`${uid}|${m.conversation_id}`) || 0;
    if (read >= Date.parse(m.created_at)) continue; // lu
    const p = people.get(uid);
    const s = people.get(m.sender);
    const name = (s && s.display_name ? String(s.display_name).trim() : '').split(/\s+/)[0];
    const [title, body] = pick('unread_message', p && p.language);
    const ok = await deliver(ctx, uid, p, 'unread_message', `${m.conversation_id}:${m.id}`, {
      title: fill(title, { name }).trim(),
      body,
      type: 'unread_message',
      data: { senderId: String(m.sender), conversationId: m.conversation_id },
    });
    if (ok) sent += 1;
  }
  return sent;
}

async function boostEnding(ctx) {
  const { sb } = ctx;
  const from = new Date(Date.now() + 50 * 60 * 1000).toISOString();
  const to = new Date(Date.now() + 75 * 60 * 1000).toISOString();
  const { data: rows } = await sb
    .from('profiles')
    .select('id, language, country, boosted_until')
    .gte('boosted_until', from)
    .lt('boosted_until', to)
    .limit(500);
  let sent = 0;
  for (const p of rows || []) {
    const [title, body] = pick('boost_ending', p.language);
    const ok = await deliver(ctx, p.id, p, 'boost_ending', p.boosted_until, {
      title,
      body,
      type: 'boost_ending',
      data: {},
    });
    if (ok) sent += 1;
  }
  return sent;
}

async function weeklyRecap(ctx) {
  const { sb } = ctx;
  const since = new Date(Date.now() - 7 * DAY).toISOString();
  const [{ data: created }, { data: answered }] = await Promise.all([
    sb.from('friendships')
      .select('requester, addressee, status')
      .gte('created_at', since)
      .limit(3000),
    sb.from('friendships')
      .select('requester, addressee')
      .eq('status', 'accepted')
      .gte('responded_at', since)
      .limit(3000),
  ]);
  const stats = new Map(); // uid -> { friends:Set, requests:Set, partners:Set }
  const get = (u) => {
    if (!stats.has(u)) stats.set(u, { friends: new Set(), requests: new Set(), partners: new Set() });
    return stats.get(u);
  };
  for (const r of answered || []) {
    get(r.requester).friends.add(r.addressee);
    get(r.requester).partners.add(r.addressee);
    get(r.addressee).friends.add(r.requester);
    get(r.addressee).partners.add(r.requester);
  }
  for (const r of created || []) {
    get(r.addressee).requests.add(r.requester);
    get(r.addressee).partners.add(r.requester);
  }
  if (stats.size === 0) return 0;
  const people = await profilesById(
    sb, [...stats.keys(), ...[...stats.values()].flatMap((s) => [...s.partners])]);
  const week = isoWeek();
  let sent = 0;
  for (const [uid, s] of stats) {
    const p = people.get(uid);
    if (!p) continue;
    // Dimanche entre 18 h et 20 h chez la personne.
    const lp = localParts(tzOf(p.country));
    if (!lp || lp.weekday !== 'Sun' || lp.hour < 18 || lp.hour >= 20) continue;
    const countries = new Set(
      // Seulement les NOUVEAUX AMIS : un demandeur refuse n'est pas un pays
      // decouvert.
      [...s.friends]
        .map((id) => people.get(id)?.country)
        .filter((c) => c && String(c).trim()),
    );
    const [title, lFriends, lCountries, lRequests] = pick('weekly_recap', p.language);
    const parts = [];
    if (s.friends.size > 0) parts.push(`${lFriends} : ${s.friends.size}`);
    if (countries.size > 0 && s.friends.size > 0) parts.push(`${lCountries} : ${countries.size}`);
    if (s.requests.size > 0) parts.push(`${lRequests} : ${s.requests.size}`);
    if (parts.length === 0) continue; // semaine vide : on ne dit rien
    const ok = await deliver(ctx, uid, p, 'weekly_recap', week, {
      title,
      body: parts.join(' · '),
      type: 'weekly_recap',
      data: {},
    });
    if (ok) sent += 1;
  }
  return sent;
}

// ── Boucle ───────────────────────────────────────────────────────────────────

let running = false;
let disabledLogged = false;

async function runOnce(ctx) {
  if (running) return;
  running = true;
  try {
    if (!(await logAvailable(ctx.sb))) {
      if (!disabledLogged) {
        disabledLogged = true;
        console.warn('[engage] table notif_log absente (migration 0066) : notifications d\'engagement suspendues');
      }
      return;
    }
    disabledLogged = false;
    const out = {};
    for (const [name, fn] of Object.entries({
      boost_ending: boostEnding,
      pending_requests: pendingRequests,
      say_hello: sayHello,
      unread_message: unreadMessages,
      weekly_recap: weeklyRecap,
    })) {
      try {
        out[name] = await fn(ctx);
      } catch (e) {
        console.error(`[engage] ${name} error`, e?.message || e);
      }
    }
    if (Object.values(out).some((n) => n)) {
      console.log('[engage]', JSON.stringify(out));
    }
  } finally {
    running = false;
  }
}

/**
 * @param {{ supabase: () => any, notifyUser: Function }} deps
 */
function start({ supabase, notifyUser }) {
  const sb = supabase();
  if (!sb) return;
  const ctx = { sb, notifyUser };
  const timer = setInterval(() => {
    runOnce(ctx).catch((e) => console.error('[engage] error', e?.message || e));
  }, TICK_MS);
  timer.unref?.();
  console.log(`[engage] scheduler on (every ${TICK_MS / 60000} min, cap ${DAILY_CAP}/day)`);
}

module.exports = { start, runOnce, _test: { pick, fill, isoWeek, awake } };
