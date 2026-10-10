'use strict';

// ─────────────────────────────────────────────────────────────────────────────
// Comptes IA (profiles.is_ai, migration 0064) : ils vivent cote serveur.
//
//   file d'actions  le panneau admin (ou le mode autonome) ecrit dans
//                   `ai_actions` (migration 0068) ; ce module les execute a
//                   l'heure prevue : liker quelqu'un, lui ecrire.
//   repondeur       un humain ecrit a un compte IA -> il repond, apres un delai
//                   humain (5-30 s). Au plus REPLIES_PER_DAY reponses par jour
//                   et par conversation ; au-dela : SILENCE, aucun message.
//   autonome        accepte les likes recus, souhaite la bienvenue aux
//                   nouveaux inscrits, avec AUTO_LIKES_PER_DAY ajouts par jour
//                   et par compte, aux heures ou le compte est « reveille ».
//
// Honnetete : un compte IA ne se fait jamais passer pour une personne. Le
// badge « IA » est dans l'app, ET le nom de l'expediteur des notifications
// porte « (IA) » (un push ne peut pas afficher de pastille).
//
// Tout est DESACTIVE tant que AI_AGENTS_ENABLED n'est pas « 1 ». Le mode
// autonome demande en plus AI_AUTONOMOUS=1. Si `ai_actions` n'existe pas
// encore (migration 0068), tout est suspendu.
//
// Chaque execution reverifie que le compte agissant est bien `is_ai` : cette
// file ne peut jamais faire agir un vrai utilisateur.
// ─────────────────────────────────────────────────────────────────────────────

const DAY = 24 * 60 * 60 * 1000;
const QUEUE_TICK_MS = 15 * 1000;
const AUTO_TICK_MS = 10 * 60 * 1000;

const REPLIES_PER_DAY = 2; // par conversation, jour UTC
const AUTO_LIKES_PER_DAY = 2; // par compte IA, jour UTC
const WELCOME_LIKES_PER_NEW_USER = 2;
const REPLY_WINDOW_MS = 20 * 60 * 1000;
const PREFER_OPPOSITE_GENDER = process.env.AI_PREFER_OPPOSITE_GENDER !== '0';

const UUID = /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;

const DEEPSEEK_KEY = process.env.FIX_KEY?.trim();
const DEEPSEEK_BASE = (process.env.FIX_BASE?.trim() || 'https://api.deepseek.com')
  .replace(/\/+$/, '');
const DEEPSEEK_MODEL = process.env.FIX_MODEL?.trim() || 'deepseek-v4-flash';

// ── Textes localises (memes libelles que lib/services/app_strings.dart) ──────
const LIKE_BODY = {
  fr: 'veut être ami', en: 'wants to be friends', es: 'quiere ser tu amigo',
  de: 'möchte mit dir befreundet sein', it: 'vuole essere tuo amico',
  pt: 'quer ser teu amigo', nl: 'wil bevriend zijn', ar: 'يريد أن يكون صديقك',
  ru: 'хочет дружить', zh: '想加你为好友', ja: '友だちになりたいそうです',
  ko: '친구가 되고 싶어 해요',
};
const MATCH_TITLE = {
  fr: 'Découvre un pays !', en: 'Discover a country!', es: '¡Descubre un país!',
  de: 'Entdecke ein Land!', it: 'Scopri un paese!', pt: 'Descobre um país!',
  nl: 'Ontdek een land!', ar: 'اكتشف بلدًا!', ru: 'Открой для себя страну!',
  zh: '探索一个国家！', ja: '新しい国を発見！', ko: '새로운 나라를 만나보세요!',
};
const MATCH_BODY = {
  fr: 'Toi et {name} vous êtes amis. Lance la conversation !',
  en: 'You and {name} are friends. Start the conversation!',
  es: 'Tú y {name} sois amigos. ¡Empieza la conversación!',
  de: 'Du und {name} seid jetzt befreundet. Starte das Gespräch!',
  it: 'Tu e {name} siete amici. Inizia la conversazione!',
  pt: 'Tu e {name} são amigos. Começa a conversa!',
  nl: 'Jij en {name} zijn vrienden. Begin het gesprek!',
  ar: 'أنت و{name} أصبحتما صديقين. ابدأ المحادثة!',
  ru: 'Вы с {name} теперь друзья. Начните разговор!',
  zh: '你和 {name} 成为朋友了，开始聊天吧！',
  ja: 'あなたと{name}は友達になりました。会話を始めましょう！',
  ko: '당신과 {name}님은 이제 친구예요. 대화를 시작해보세요!',
};
const LANG_NAME = {
  fr: 'French', en: 'English', es: 'Spanish', de: 'German', it: 'Italian',
  pt: 'Portuguese', nl: 'Dutch', ar: 'Arabic', ru: 'Russian', zh: 'Chinese',
  ja: 'Japanese', ko: 'Korean',
};

const langOf = (p) => String((p && p.language) || '').toLowerCase().split(/[-_]/)[0];
const loc = (table, lang) => table[lang] || table.en;

/** Nom affiche d'un compte IA dans une notification : toujours « (IA) ». */
const aiLabel = (ai) => `${String(ai.display_name || '').trim() || 'Swayco'} (IA)`;

// ── Utilitaires ──────────────────────────────────────────────────────────────

function hash(s) {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}

/** Delai « humain » stable pour un message : 5 a 30 s (pas de re-tirage a chaque tick). */
function replyDelayMs(messageId) {
  return 5000 + (hash(String(messageId)) % 25000);
}

function utcDayStart(now = new Date()) {
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()))
    .toISOString();
}

const convIdFor = (a, b) => {
  const [x, y] = [String(a), String(b)].sort();
  return `dm-${x}-${y}`;
};

const chunks = (arr, n) => {
  const out = [];
  for (let i = 0; i < arr.length; i += n) out.push(arr.slice(i, i + n));
  return out;
};

const rnd = (n) => Math.floor(Math.random() * n);

// Les clichés nationaux qu'on interdit au modele, et qu'on controle en sortie.
const CLICHE = /(tour eiffel|eiffel tower|croissant|baguette|\bb[ée]ret\b|\bvin rouge\b|oktoberfest|bratwurst|\bwurst\b|sauerkraut|pizza et pasta|spaghetti|sushi et|kimchi et|\bsamba\b)/i;
const containsCliche = (text, userText = '') =>
  CLICHE.test(text) && !CLICHE.test(userText);

// ── Acces donnees ────────────────────────────────────────────────────────────

const PROFILE_COLS =
  'id, display_name, language, country, city, gender, age, job, bio, interests, is_ai, created_at, discover_photo_url';

async function getProfile(sb, id) {
  if (!UUID.test(String(id))) return null;
  const { data } = await sb.from('profiles').select(PROFILE_COLS).eq('id', id).maybeSingle();
  return data || null;
}

async function aiIdsAmong(sb, ids) {
  const out = new Set();
  const list = [...new Set(ids.filter((i) => UUID.test(String(i))))];
  for (const part of chunks(list, 100)) {
    const { data } = await sb.from('profiles').select('id').eq('is_ai', true).in('id', part);
    for (const r of data || []) out.add(r.id);
  }
  return out;
}

async function isBlocked(sb, a, b) {
  const { data } = await sb
    .from('blocked_users')
    .select('blocker')
    .or(`and(blocker.eq.${a},blocked.eq.${b}),and(blocker.eq.${b},blocked.eq.${a})`)
    .limit(1);
  return !!(data && data.length);
}

async function countActions(sb, filter, sinceIso) {
  let q = sb.from('ai_actions').select('id', { count: 'exact', head: true })
    .in('status', ['pending', 'running', 'done'])
    .gte('created_at', sinceIso);
  for (const [k, v] of Object.entries(filter)) q = q.eq(k, v);
  const { count } = await q;
  return count || 0;
}

async function finish(sb, id, status, detail) {
  await sb.from('ai_actions')
    .update({ status, detail: detail ? String(detail).slice(0, 300) : null, done_at: new Date().toISOString() })
    .eq('id', id);
}

// ── LLM ──────────────────────────────────────────────────────────────────────

async function chat(messages, { maxTokens = 120, temperature = 0.9 } = {}) {
  if (!DEEPSEEK_KEY) throw new Error('FIX_KEY (DeepSeek) manquante');
  const res = await fetch(`${DEEPSEEK_BASE}/chat/completions`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${DEEPSEEK_KEY}` },
    body: JSON.stringify({
      model: DEEPSEEK_MODEL,
      messages,
      temperature,
      max_tokens: maxTokens,
      ...(DEEPSEEK_BASE.includes('deepseek') ? { thinking: { type: 'disabled' } } : {}),
    }),
    signal: AbortSignal.timeout(25000),
  });
  if (!res.ok) throw new Error(`LLM ${res.status}`);
  const j = await res.json();
  const text = j?.choices?.[0]?.message?.content;
  return String(text || '').trim().replace(/^["“«]+|["”»]+$/g, '').trim();
}

function personaText(ai, personaRow) {
  if (personaRow && personaRow.persona) return String(personaRow.persona).trim();
  const bits = [
    ai.age ? `${ai.age} ans` : '',
    ai.job ? `métier/secteur : ${ai.job}` : '',
    Array.isArray(ai.interests) && ai.interests.length ? `aime : ${ai.interests.join(', ')}` : '',
    ai.bio ? `sa bio : « ${ai.bio} »` : '',
  ].filter(Boolean);
  return bits.join(' ; ') || 'une personne ordinaire, curieuse des autres';
}

function systemPrompt(ai, personaRow, targetLang) {
  const where = [ai.city, ai.country].filter(Boolean).join(', ');
  return [
    `You are ${ai.display_name}${where ? `, who lives in ${where}` : ''}.`,
    `About you: ${personaText(ai, personaRow)}`,
    '',
    'You are chatting inside a language-exchange / meeting app. Your account is an AI account and the app labels it "AI" next to your name: never claim to be human. If someone asks whether you are a bot / an AI / real, answer honestly in one short light sentence.',
    `Write in ${LANG_NAME[targetLang] || 'English'} (the other person's language), whatever language they write in.`,
    '',
    'Style: 1 or 2 short sentences, casual, like a text message. At most one emoji. No assistant phrases ("Of course!", "How can I help", "As an AI language model"). Mostly react to what THEY said or ask them something; when you talk about yourself, use small concrete details from your profile.',
    `Never mention ${ai.country || 'your country'} or your city unless they ask, and never use national stereotypes: no landmarks, food or drink clichés (for France: no Eiffel tower, croissants, baguette, wine, berets; for Germany: no beer, sausages, Oktoberfest; the same logic for every country).`,
    'Never ask for or give money, bank or payment details, phone number, email, social media handles or other apps; never ask for photos. If asked to meet, to call or to video-call, say you prefer to chat here.',
    'If the other person is sexual, abusive, or sounds underage, stay polite and brief, change the subject or stop engaging.',
    'Output ONLY the message text, nothing else.',
  ].join('\n');
}

async function generate(ctx, ai, target, history, mode) {
  const sb = ctx.sb;
  const { data: personaRow } = await sb.from('ai_personas').select('persona').eq('user_id', ai.id).maybeSingle();
  const lang = langOf(target) || 'en';
  const sys = systemPrompt(ai, personaRow, lang);
  const lastUser = history.length ? history[history.length - 1].body : '';
  const base = [{ role: 'system', content: sys }];

  let turn;
  if (mode === 'opener') {
    const facts = [
      target.display_name && `name: ${target.display_name}`,
      target.bio && `bio: ${target.bio}`,
      Array.isArray(target.interests) && target.interests.length && `interests: ${target.interests.join(', ')}`,
      target.job && `job: ${target.job}`,
    ].filter(Boolean).join(' ; ');
    turn = [{ role: 'user', content: `Write the first message to someone you just discovered (${facts || 'no details'}). Mention one concrete thing from their profile if there is one, otherwise ask a simple open question. Do not introduce yourself in a formal way.` }];
  } else {
    turn = history.map((m) => ({ role: m.sender === ai.id ? 'assistant' : 'user', content: String(m.body || '') }));
  }

  let text = await chat([...base, ...turn]);
  if (containsCliche(text, lastUser)) {
    text = await chat([
      ...base, ...turn,
      { role: 'system', content: 'Your draft used a national cliché. Rewrite it without any.' },
    ]);
    if (containsCliche(text, lastUser)) return '';
  }
  return text.slice(0, 500);
}

// ── Actions ──────────────────────────────────────────────────────────────────

async function pushLike(ctx, ai, target) {
  const lang = langOf(target);
  await ctx.notifyUser(target.id, {
    title: aiLabel(ai),
    body: loc(LIKE_BODY, lang),
    type: 'friend_request',
    data: { requesterId: String(ai.id) },
  });
}

async function pushMatch(ctx, ai, target) {
  const lang = langOf(target);
  await ctx.notifyUser(target.id, {
    title: loc(MATCH_TITLE, lang),
    body: loc(MATCH_BODY, lang).replace('{name}', aiLabel(ai)),
    type: 'match',
    data: { peerId: String(ai.id) },
  });
}

/** Un « like » : ligne friendships en attente, ou match si l'autre avait deja like. */
async function doLike(ctx, ai, target) {
  const { sb } = ctx;
  if (await isBlocked(sb, ai.id, target.id)) return { status: 'skipped', detail: 'blocked' };
  const { data: rows } = await sb
    .from('friendships')
    .select('id, requester, addressee, status')
    .or(`and(requester.eq.${ai.id},addressee.eq.${target.id}),and(requester.eq.${target.id},addressee.eq.${ai.id})`)
    .limit(2);
  const mine = (rows || []).find((r) => r.requester === ai.id);
  const theirs = (rows || []).find((r) => r.requester === target.id);
  if (mine) return { status: 'skipped', detail: 'already_liked' };
  if (theirs) {
    if (theirs.status !== 'pending') return { status: 'skipped', detail: `theirs_${theirs.status}` };
    const { error } = await sb.from('friendships')
      .update({ status: 'accepted', responded_at: new Date().toISOString() })
      .eq('id', theirs.id).eq('status', 'pending');
    if (error) throw new Error(error.message);
    await pushMatch(ctx, ai, target).catch(() => {});
    return { status: 'done', detail: 'match' };
  }
  const { error } = await sb.from('friendships')
    .insert({ requester: ai.id, addressee: target.id, status: 'pending' });
  if (error) throw new Error(error.message);
  await pushLike(ctx, ai, target).catch(() => {});
  return { status: 'done', detail: 'like' };
}

async function sendMessage(ctx, ai, target, body) {
  const { sb } = ctx;
  const conv = convIdFor(ai.id, target.id);
  const { error } = await sb.from('messages').insert({
    conversation_id: conv,
    sender: ai.id,
    recipient: target.id,
    sender_name: ai.display_name || '',
    body,
    language: ai.language || '',
  });
  if (error) throw new Error(error.message);
  await ctx.notifyUser(target.id, {
    title: aiLabel(ai),
    body,
    type: 'message',
    data: { senderId: String(ai.id), conversationId: conv },
  }).catch((e) => console.error('[ai] push error', e?.message || e));
}

// ── File d'actions ───────────────────────────────────────────────────────────

async function execute(ctx, a) {
  const { sb } = ctx;
  const ai = await getProfile(sb, a.ai_id);
  if (!ai || ai.is_ai !== true) return { status: 'failed', detail: 'not_an_ai_account' };
  const target = await getProfile(sb, a.target_id);
  if (!target) return { status: 'failed', detail: 'target_missing' };
  if (target.is_ai) return { status: 'skipped', detail: 'target_is_ai' };

  if (a.kind === 'like') return doLike(ctx, ai, target);

  if (a.kind === 'message') {
    if (await isBlocked(sb, ai.id, target.id)) return { status: 'skipped', detail: 'blocked' };
    let body = String(a.body || '').trim();
    if (!body) body = await generate(ctx, ai, target, [], 'opener');
    if (!body) return { status: 'failed', detail: 'empty_generation' };
    await sendMessage(ctx, ai, target, body);
    return { status: 'done', detail: a.body ? 'manual_text' : 'generated' };
  }
  return { status: 'failed', detail: `kind_${a.kind}` };
}

let queueRunning = false;
async function processQueue(ctx) {
  const { sb } = ctx;
  const { data: due } = await sb.from('ai_actions').select('*')
    .eq('status', 'pending').lte('run_at', new Date().toISOString())
    .in('kind', ['like', 'message'])
    .order('run_at', { ascending: true }).limit(20);
  let n = 0;
  for (const a of due || []) {
    // Prise atomique : un seul processus execute l'action.
    const { data: won } = await sb.from('ai_actions')
      .update({ status: 'running' }).eq('id', a.id).eq('status', 'pending').select('id');
    if (!won || won.length === 0) continue;
    try {
      const r = await execute(ctx, a);
      await finish(sb, a.id, r.status, r.detail);
      n++;
    } catch (e) {
      await finish(sb, a.id, 'failed', e?.message || String(e));
    }
  }
  return n;
}

// ── Repondeur ────────────────────────────────────────────────────────────────

let replying = false;
async function processReplies(ctx) {
  const { sb } = ctx;
  const now = Date.now();
  const { data: recent } = await sb.from('messages')
    .select('id, conversation_id, sender, recipient, body, created_at')
    .gte('created_at', new Date(now - REPLY_WINDOW_MS).toISOString())
    .lt('created_at', new Date(now - 5000).toISOString())
    .not('recipient', 'is', null)
    .order('created_at', { ascending: false })
    .limit(400);
  if (!recent || recent.length === 0) return 0;

  const aiSet = await aiIdsAmong(sb, recent.map((m) => m.recipient));
  if (aiSet.size === 0) return 0;

  // Le DERNIER message humain de chaque conversation avec un compte IA.
  const latest = new Map();
  for (const m of recent) {
    if (!aiSet.has(m.recipient) || aiSet.has(m.sender)) continue;
    if (!UUID.test(String(m.sender)) || m.sender === m.recipient) continue;
    if (!latest.has(m.conversation_id)) latest.set(m.conversation_id, m);
  }

  const dayStart = utcDayStart();
  let sent = 0;
  for (const m of latest.values()) {
    if (now - Date.parse(m.created_at) < replyDelayMs(m.id)) continue;

    // Deja repondu apres ce message ?
    const { data: after } = await sb.from('messages').select('id')
      .eq('conversation_id', m.conversation_id).eq('sender', m.recipient)
      .gt('created_at', m.created_at).limit(1);
    if (after && after.length) continue;

    // Quota : REPLIES_PER_DAY par conversation et par jour. Au-dela : silence.
    const used = await countActions(sb, { ai_id: m.recipient, target_id: m.sender, kind: 'reply' }, dayStart);
    const claim = await sb.from('ai_actions').insert({
      ai_id: m.recipient, target_id: m.sender, kind: 'reply', source: 'reply',
      ref: `msg:${m.id}`, status: used >= REPLIES_PER_DAY ? 'skipped' : 'running',
      detail: used >= REPLIES_PER_DAY ? 'quota' : null,
      done_at: used >= REPLIES_PER_DAY ? new Date().toISOString() : null,
    }).select('id').single();
    if (claim.error || used >= REPLIES_PER_DAY) continue; // doublon (ref unique) ou silence

    const claimId = claim.data.id;
    try {
      const ai = await getProfile(sb, m.recipient);
      const target = await getProfile(sb, m.sender);
      if (!ai || ai.is_ai !== true || !target) { await finish(sb, claimId, 'failed', 'profile_missing'); continue; }
      if (await isBlocked(sb, ai.id, target.id)) { await finish(sb, claimId, 'skipped', 'blocked'); continue; }
      const { data: hist } = await sb.from('messages').select('sender, body, created_at')
        .eq('conversation_id', m.conversation_id).order('created_at', { ascending: false }).limit(14);
      const history = (hist || []).reverse();
      const text = await generate(ctx, ai, target, history, 'reply');
      if (!text) { await finish(sb, claimId, 'failed', 'empty_generation'); continue; }
      await sendMessage(ctx, ai, target, text);
      await finish(sb, claimId, 'done', null);
      sent++;
    } catch (e) {
      await finish(sb, claimId, 'failed', e?.message || String(e));
    }
  }
  return sent;
}

// ── Mode autonome ────────────────────────────────────────────────────────────

let autoRunning = false;
const { awake } = require('./engagement')._test;

async function sampleAi(sb, n) {
  const { count } = await sb.from('profiles').select('id', { count: 'exact', head: true }).eq('is_ai', true);
  if (!count) return [];
  const off = rnd(Math.max(count - n, 1));
  const { data } = await sb.from('profiles').select(PROFILE_COLS).eq('is_ai', true)
    .order('id', { ascending: true }).range(off, off + n - 1);
  return data || [];
}

const autoLikesToday = (sb, aiId) =>
  countActions(sb, { ai_id: aiId, kind: 'like', source: 'auto' }, utcDayStart());

/** Un humain a like un compte IA : il lui rend son like (= match), un peu plus tard. */
async function autoAcceptLikes(ctx) {
  const { sb } = ctx;
  const { data: rows } = await sb.from('friendships')
    .select('id, requester, addressee, created_at')
    .eq('status', 'pending')
    .gte('created_at', new Date(Date.now() - DAY).toISOString())
    .order('created_at', { ascending: false }).limit(500);
  if (!rows || rows.length === 0) return 0;
  const aiSet = await aiIdsAmong(sb, rows.flatMap((r) => [r.addressee, r.requester]));
  let done = 0;
  for (const r of rows) {
    if (!aiSet.has(r.addressee) || aiSet.has(r.requester)) continue;
    // Entre 2 min et 1 h apres le like, stable pour cette ligne.
    if (Date.now() - Date.parse(r.created_at) < 120000 + (hash(r.id) % (58 * 60000))) continue;
    const ai = await getProfile(sb, r.addressee);
    if (!ai || !ai.is_ai || !awake(ai.country)) continue;
    if ((await autoLikesToday(sb, ai.id)) >= AUTO_LIKES_PER_DAY) continue;
    const claim = await sb.from('ai_actions').insert({
      ai_id: ai.id, target_id: r.requester, kind: 'like', source: 'auto',
      ref: `fr:${r.id}`, status: 'running',
    }).select('id').single();
    if (claim.error) continue; // deja traite
    try {
      const target = await getProfile(sb, r.requester);
      if (!target) { await finish(sb, claim.data.id, 'failed', 'target_missing'); continue; }
      const res = await doLike(ctx, ai, target);
      await finish(sb, claim.data.id, res.status, res.detail);
      if (res.status === 'done') done++;
    } catch (e) {
      await finish(sb, claim.data.id, 'failed', e?.message || String(e));
    }
  }
  return done;
}

/** Les inscrits des dernières 24 h recoivent au plus WELCOME_LIKES_PER_NEW_USER likes d'IA. */
async function autoWelcome(ctx) {
  const { sb } = ctx;
  const { data: fresh } = await sb.from('profiles').select(PROFILE_COLS)
    .eq('is_ai', false)
    .gte('created_at', new Date(Date.now() - DAY).toISOString())
    .not('discover_photo_url', 'is', null).neq('discover_photo_url', '')
    .order('created_at', { ascending: false }).limit(100);
  if (!fresh || fresh.length === 0) return 0;
  let queued = 0;
  for (const user of fresh) {
    const have = await countActions(sb, { target_id: user.id, kind: 'like', source: 'auto' },
      new Date(Date.now() - 2 * DAY).toISOString());
    const need = WELCOME_LIKES_PER_NEW_USER - have;
    if (need <= 0) continue;

    let cands = (await sampleAi(sb, 40)).filter((c) => awake(c.country));
    if (PREFER_OPPOSITE_GENDER && (user.gender === 'm' || user.gender === 'f')) {
      cands.sort((a, b) => (b.gender !== user.gender) - (a.gender !== user.gender));
    }
    let picked = 0;
    for (const ai of cands) {
      if (picked >= need) break;
      if ((await autoLikesToday(sb, ai.id)) >= AUTO_LIKES_PER_DAY) continue;
      const { data: fr } = await sb.from('friendships').select('id')
        .or(`and(requester.eq.${ai.id},addressee.eq.${user.id}),and(requester.eq.${user.id},addressee.eq.${ai.id})`)
        .limit(1);
      if (fr && fr.length) continue;
      const runAt = new Date(Date.now() + (10 + rnd(80)) * 60000).toISOString();
      const ins = await sb.from('ai_actions').insert({
        ai_id: ai.id, target_id: user.id, kind: 'like', source: 'auto', run_at: runAt,
      });
      if (!ins.error) { picked++; queued++; }
    }
  }
  return queued;
}

// ── Boucles ──────────────────────────────────────────────────────────────────

async function tableAvailable(sb) {
  const { error } = await sb.from('ai_actions').select('id').limit(1);
  return !error;
}

function start({ supabase, notifyUser }) {
  if (process.env.AI_AGENTS_ENABLED !== '1') {
    console.log('[ai] desactive (AI_AGENTS_ENABLED != 1)');
    return;
  }
  const sb = supabase();
  if (!sb) return;
  const ctx = { sb, notifyUser };
  let warned = false;
  const guard = async (name, fn) => {
    try {
      if (!(await tableAvailable(sb))) {
        if (!warned) { warned = true; console.warn('[ai] table ai_actions absente (migration 0068) : suspendu'); }
        return;
      }
      warned = false;
      const n = await fn(ctx);
      if (n) console.log(`[ai] ${name}: ${n}`);
    } catch (e) {
      console.error(`[ai] ${name} error`, e?.message || e);
    }
  };

  const q = setInterval(async () => {
    if (queueRunning || replying) return;
    queueRunning = replying = true;
    try {
      await guard('queue', processQueue);
      await guard('replies', processReplies);
    } finally { queueRunning = replying = false; }
  }, QUEUE_TICK_MS);
  q.unref?.();

  const autonomous = process.env.AI_AUTONOMOUS === '1';
  if (autonomous) {
    const t = setInterval(async () => {
      if (autoRunning) return;
      autoRunning = true;
      try {
        await guard('auto_accept', autoAcceptLikes);
        await guard('auto_welcome', autoWelcome);
      } finally { autoRunning = false; }
    }, AUTO_TICK_MS);
    t.unref?.();
  }
  console.log(`[ai] actif (file + repondeur${autonomous ? ' + autonome' : ''}, ${REPLIES_PER_DAY} reponses/jour/conversation)`);
}

module.exports = {
  start,
  _test: { hash, replyDelayMs, utcDayStart, containsCliche, systemPrompt, convIdFor, aiLabel },
};
