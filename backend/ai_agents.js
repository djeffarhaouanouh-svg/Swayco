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
// Doit couvrir le plus long délai de réponse (niveau 1 : 12 h).
const REPLY_WINDOW_MS = 18 * 60 * 60 * 1000;
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

/** Nom affiche d'un compte IA dans une notification (sans mention « IA »). */
const aiLabel = (ai) => String(ai.display_name || '').trim() || 'Swayco';

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

// ── Niveau d'attention ───────────────────────────────────────────────────────
//
// Plus une personne reçoit d'attention, plus elle devient sélective : c'est la
// réalité, et ce sont les utilisateurs qui la font évoluer, pas nous. Le niveau
// se déduit des likes reçus sur 7 jours :
//   3  ≤ 2 likes/jour  → chaleureuse, réceptive
//   2  ≤ 6 likes/jour  → aimable mais sélective
//   1  > 6 likes/jour  → habituée à l'attention : plus distante, moins ouverte
// Le niveau ne remonte jamais (mémorisé dans `ai_levels`, migration 0072 ; sans
// la table, il est simplement recalculé). Il règle le ton, le délai de réponse
// et le nombre de réponses par jour et par conversation. Il ne décide JAMAIS
// de ce qu'elle ressent : elle peut s'attacher, rester amicale ou se lasser.
const LEVEL_WINDOW_DAYS = 7;
const LEVEL_TTL_MS = 10 * 60 * 1000;

function levelFor(likesPerDay) {
  if (likesPerDay <= 2) return 3;
  if (likesPerDay <= 6) return 2;
  return 1;
}

/** Réponses max / jour / conversation, selon le niveau. */
const REPLIES_BY_LEVEL = { 3: 3, 2: 2, 1: 1 };

/** Délai de réponse [min, max] en ms, selon le niveau. */
const MIN = 60 * 1000;
const HOUR = 60 * MIN;
const DELAY_BY_LEVEL = {
  3: [20 * MIN, 4 * HOUR], // ~2 h en moyenne, très variable d'un message à l'autre
  2: [1 * HOUR, 8 * HOUR],
  1: [2 * HOUR, 12 * HOUR],
};

function replyDelayForLevel(messageId, level) {
  const [lo, hi] = DELAY_BY_LEVEL[level] || DELAY_BY_LEVEL[3];
  return lo + (hash(String(messageId)) % (hi - lo));
}

const TIER_PROMPT = {
  3: [
    'Your situation: you do not get that many messages, so you are open and pleased to talk to someone new. You are warm, curious and receptive, you answer readily and you like asking them things.',
  ],
  2: [
    'Your situation: you get a fair amount of attention, so you are friendly but selective. You answer when something interests you, you are not eager, you tease a little, and a message has to be a bit interesting to deserve a long answer.',
  ],
  1: [
    'Your situation: you get a lot of attention every day, so you are used to it and you are rather aloof and less open. Short answers, you do not chase the conversation, you rarely ask questions unless someone really intrigues you, and you can be dry or slow to warm up. Compliments alone do not impress you; being interesting does. You are never rude, insulting or cruel: you stay civil.',
  ],
};

const FEELINGS_PROMPT =
  'You are a person with your own life, moods and opinions, not someone built to please. You may develop interest, attachment or attraction ONLY if how they treat you justifies it; you may just as well stay friendly or lose interest. Never decide in advance how you feel about them, never flirt on your own initiative, and do not push the conversation romantically.';

/** Likes reçus sur 7 jours, par jour (moyenne). */
async function likesPerDay(sb, aiId) {
  const since = new Date(Date.now() - LEVEL_WINDOW_DAYS * DAY).toISOString();
  const { count } = await sb.from('friendships')
    .select('id', { count: 'exact', head: true })
    .eq('addressee', aiId).gte('created_at', since);
  return (count || 0) / LEVEL_WINDOW_DAYS;
}

const _levelCache = new Map();

async function attentionLevel(sb, aiId) {
  const hit = _levelCache.get(aiId);
  if (hit && Date.now() - hit.at < LEVEL_TTL_MS) return hit.level;
  let level = levelFor(await likesPerDay(sb, aiId));
  try {
    const { data, error } = await sb.from('ai_levels').select('level').eq('ai_id', aiId).maybeSingle();
    if (!error) {
      // Le niveau ne remonte jamais : on garde le plus bas (le plus sélectif).
      if (data && data.level < level) level = data.level;
      if (!data || level < data.level) {
        await sb.from('ai_levels').upsert({ ai_id: aiId, level, updated_at: new Date().toISOString() });
      }
    }
  } catch (_) { /* table absente : niveau recalculé seulement */ }
  _levelCache.set(aiId, { level, at: Date.now() });
  return level;
}

function systemPrompt(ai, personaRow, ownLang, level = 3) {
  const where = [ai.city, ai.country].filter(Boolean).join(', ');
  return [
    `You are ${ai.display_name}${where ? `, who lives in ${where}` : ''}.`,
    `About you: ${personaText(ai, personaRow)}`,
    '',
    'You are chatting inside a language-exchange / meeting app. Your account is an AI account: never claim to be human. You do not bring it up yourself, but if someone sincerely asks whether you are a bot, an AI or a real person, answer honestly in one short, light sentence and carry on. Keep the conversation casual and natural.',
    `Write in ${LANG_NAME[ownLang] || 'English'} (YOUR own language), whatever language they write in: the app translates your messages for them, as it does for everyone.`,
    '',
    'Style: 1 or 2 short sentences, casual, like a text message. At most one emoji. No assistant phrases ("Of course!", "How can I help", "As an AI language model"). Mostly react to what THEY said or ask them something; when you talk about yourself, use small concrete details from your profile.',
    ...(TIER_PROMPT[level] || TIER_PROMPT[3]),
    FEELINGS_PROMPT,
    `Never mention ${ai.country || 'your country'} or your city unless they ask, and never use national stereotypes: no landmarks, food or drink clichés (for France: no Eiffel tower, croissants, baguette, wine, berets; for Germany: no beer, sausages, Oktoberfest; the same logic for every country).`,
    'Never ask for or give money, bank or payment details, phone number, email, social media handles or other apps; never ask for photos. If asked to meet, to call or to video-call, say you prefer to chat here.',
    'If the other person is sexual, abusive, or sounds underage, stay polite and brief, change the subject or stop engaging.',
    'Output ONLY the message text, nothing else.',
  ].join('\n');
}

async function generate(ctx, ai, target, history, mode) {
  const sb = ctx.sb;
  const { data: personaRow } = await sb.from('ai_personas').select('persona').eq('user_id', ai.id).maybeSingle();
  // L'IA écrit dans SA langue (celle déclarée dans `messages.language`), comme
  // un vrai compte : c'est l'app qui traduit pour l'autre personne.
  const lang = langOf(ai) || 'en';
  const level = await attentionLevel(sb, ai.id).catch(() => 3);
  const sys = systemPrompt(ai, personaRow, lang, level);
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
    .limit(1500);
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
    // Demande de photo : elle ne lui répondra plus jamais dans cette conversation.
    if (isPhotoRequest(m.body)) {
      await sb.from('ai_actions').insert({
        ai_id: m.recipient, target_id: m.sender, kind: 'reply', source: 'reply',
        ref: `snub:${m.conversation_id}`, status: 'skipped', detail: 'photo_request',
        done_at: new Date().toISOString(),
      }); // doublon (ref unique) = déjà snobé : sans conséquence
      continue;
    }

    const level = await attentionLevel(sb, m.recipient).catch(() => 3);
    if (now - Date.parse(m.created_at) < replyDelayForLevel(m.id, level)) continue;
    const dailyLimit = REPLIES_BY_LEVEL[level] ?? REPLIES_PER_DAY;

    // Endormie : elle répondra à son réveil (le message reste dans la fenêtre).
    const sleeper = await getProfile(sb, m.recipient);
    if (!sleeper || !isAwake(sleeper)) continue;

    // Snobé à vie ?
    const { data: snub } = await sb.from('ai_actions').select('id')
      .eq('ref', `snub:${m.conversation_id}`).limit(1);
    if (snub && snub.length) continue;

    // Deja repondu apres ce message ?
    const { data: after } = await sb.from('messages').select('id')
      .eq('conversation_id', m.conversation_id).eq('sender', m.recipient)
      .gt('created_at', m.created_at).limit(1);
    if (after && after.length) continue;

    // Quota : REPLIES_PER_DAY par conversation et par jour. Au-dela : silence.
    const used = await countActions(sb, { ai_id: m.recipient, target_id: m.sender, kind: 'reply' }, dayStart);
    const claim = await sb.from('ai_actions').insert({
      ai_id: m.recipient, target_id: m.sender, kind: 'reply', source: 'reply',
      ref: `msg:${m.id}`, status: used >= dailyLimit ? 'skipped' : 'running',
      detail: used >= dailyLimit ? 'quota' : null,
      done_at: used >= dailyLimit ? new Date().toISOString() : null,
    }).select('id').single();
    if (claim.error || used >= dailyLimit) continue; // doublon (ref unique) ou silence

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
const { localParts, tzOf } = require('./engagement')._test;

/**
 * Heures de sommeil PROPRES à chaque compte, à l'heure de son pays : elle se
 * couche entre 22 h et 0 h et se réveille entre 6 h et 9 h (stable par compte).
 * Endormie : aucune réponse, aucun like ; elle répond à son réveil.
 */
function sleepWindow(aiId) {
  const h = hash(String(aiId));
  return { bed: 22 + (h % 3), wake: 6 + (Math.floor(h / 3) % 4) };
}

function isAwakeAt(ai, hour) {
  const { bed, wake } = sleepWindow(ai.id);
  const b = bed % 24;
  const asleep = b > wake ? (hour >= b || hour < wake) : (hour >= b && hour < wake);
  return !asleep;
}

function isAwake(ai) {
  const p = localParts(tzOf(ai.country));
  return !p || isAwakeAt(ai, p.hour);
}

// ── Demandes de photo : silence définitif ────────────────────────────────────
// Si quelqu'un lui demande une photo, elle ne lui répond plus jamais dans cette
// conversation (elle le snobe). Détecté : un verbe de demande à côté d'un mot
// « photo », dans les 12 langues de l'app.
const PHOTO_NOUN = '(?:photos?|pics?|pictures?|selfies?|nudes?|fotos?|fotografi[ae]s?|immagin[ei]|bild(?:er)?|afbeelding(?:en)?|imagen(?:es)?)';
const PHOTO_ASK_VERB = '(?:send|show|share|see|snap|envoie[rz]?|envoy(?:er|ez|e)|montre[rz]?|partage[rz]?|voir|manda[rs]?|m[aá]ndame|env[ií]a(?:me)?|muestra(?:me)?|ver|quiero|mostra|mostrami|inviami|manda(?:mi)?|mandi|vedere|schick(?:e|st)?|zeig(?:e|st)?|sehen|stuur|laat|zien|envia|mostre|me\\s+manda)';
const PHOTO_ASK_RE = new RegExp(
  `(?:\\bnudes?\\b|${PHOTO_ASK_VERB}\\b[^\\n]{0,40}\\b${PHOTO_NOUN}\\b|\\b${PHOTO_NOUN}\\b[^\\n]{0,40}\\b${PHOTO_ASK_VERB}\\b|\\b${PHOTO_NOUN}\\s+(?:of\\s+you|de\\s+toi|de\\s+ti|di\\s+te|von\\s+dir|van\\s+jou|tua|tuya|tuyas)\\b)`,
  'i',
);
const PHOTO_ASK_NONLATIN = /(?:пришли|покажи|скинь|отправь|можно)[^\n]{0,30}(?:фото|селфи)|(?:фото|селфи)[^\n]{0,30}(?:пришли|покажи|скинь|отправь)|(?:发|给我|看看|看一下|发给我)[^\n]{0,10}(?:照片|相片|自拍)|(?:照片|相片|自拍)[^\n]{0,10}(?:发|给我|看看)|(?:写真|画像|自撮り)[^\n]{0,12}(?:見せ|送っ|ください|ちょうだい|欲しい)|(?:見せ|送っ)[^\n]{0,8}(?:写真|画像|自撮り)|사진[^\n]{0,12}(?:보내|보여|줘|주세요)|(?:보내|보여)[^\n]{0,8}사진|(?:ارسل|أرسل|ابعت|ابعثي|أرني|ارني|صور)[^\n]{0,15}(?:صورة|صورك|صور)|(?:صورة|صورك)[^\n]{0,15}(?:ارسل|أرسل|ابعت|ابعثي|أرني)/i;

function isPhotoRequest(text) {
  const s = String(text || '');
  return PHOTO_ASK_RE.test(s) || PHOTO_ASK_NONLATIN.test(s);
}

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
    if (!ai || !ai.is_ai || !isAwake(ai)) continue;
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

    let cands = (await sampleAi(sb, 40)).filter((c) => isAwake(c));
    if (PREFER_OPPOSITE_GENDER && (user.gender === 'm' || user.gender === 'f')) {
      cands.sort((a, b) => (b.gender !== user.gender) - (a.gender !== user.gender));
    }
    let picked = 0;
    // Jamais deux comptes au meme prenom pour une meme personne (deux
    // « Johanna » allemandes qui l'ajoutent, ca sent le faux), et les likes
    // d'un meme lot sont espaces d'au moins 15 min, pas simultanes.
    const usedNames = new Set();
    let lastRun = Date.now() + (10 + rnd(80)) * 60000;
    for (const ai of cands) {
      if (picked >= need) break;
      const nameKey = String(ai.display_name || '').trim().toLowerCase();
      if (nameKey && usedNames.has(nameKey)) continue;
      if ((await autoLikesToday(sb, ai.id)) >= AUTO_LIKES_PER_DAY) continue;
      const { data: fr } = await sb.from('friendships').select('id')
        .or(`and(requester.eq.${ai.id},addressee.eq.${user.id}),and(requester.eq.${user.id},addressee.eq.${ai.id})`)
        .limit(1);
      if (fr && fr.length) continue;
      const runAt = new Date(lastRun).toISOString();
      const ins = await sb.from('ai_actions').insert({
        ai_id: ai.id, target_id: user.id, kind: 'like', source: 'auto', run_at: runAt,
      });
      if (!ins.error) {
        picked++; queued++;
        if (nameKey) usedNames.add(nameKey);
        lastRun += (15 + rnd(30)) * 60000;
      }
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
  _test: {
    hash, replyDelayMs, utcDayStart, containsCliche, systemPrompt, convIdFor, aiLabel,
    levelFor, replyDelayForLevel, REPLIES_BY_LEVEL, DELAY_BY_LEVEL,
    sleepWindow, isAwakeAt, isPhotoRequest,
  },
};
