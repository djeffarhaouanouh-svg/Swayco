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
// Contexte donné à l'IA pour répondre : les N derniers messages de CETTE
// conversation (les siens et ceux de la personne), pas plus.
const HISTORY_MESSAGES = 14;

// MODE TEST : pour ces comptes (et eux seuls), les IA répondent tout de suite :
// ni délai, ni sommeil, ni quota par jour. Sert à tester personnalité et
// réponses ; à vider quand le test est fini. Le répondeur tourne toutes les
// 15 s : « tout de suite » = quelques secondes.
const TEST_INSTANT_TARGETS = new Set([
  // Mode test actif pour ces comptes seulement. Pour le terminer : vider la liste.
  '2f80fb98-8e65-4078-adce-9b2a144654f6', // lou-2f80fb
]);
// Doit couvrir le plus long délai (MAX_DELAY_MS : 10 h) PLUS l'attente du
// réveil quand le délai tombe la nuit (≤ 11 h : coucher 23 h, réveil 10 h) :
// 21 h au pire. Avec 18 h, une réponse pouvait devenir impossible.
const REPLY_WINDOW_MS = 24 * 60 * 60 * 1000;
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

function utcDayStart(now = new Date(Date.now())) {
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

async function chat(messages, { maxTokens = 40, temperature = 0.95 } = {}) {
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

/**
 * Les textes de `ai_personas` finissent TOUS par « Talks about X's own life
 * with small concrete details, and mostly asks about the other person », et
 * certains disent « replies with a small story » / « asks a lot of questions » :
 * des consignes qui poussent le modèle à développer et à relancer, contre le
 * style court. On les retire À LA LECTURE (la base n'est pas modifiée).
 */
function cleanPersona(text) {
  return String(text)
    .replace(/\s*Talks about[^.]*?own life[^.]*?mostly asks about the other person\.?/i, '')
    .replace(/,\s*asks a lot of questions/gi, '')
    .replace(/,\s*replies with a small story/gi, '')
    .replace(/\s+/g, ' ')
    .trim();
}

function personaText(ai, personaRow) {
  if (personaRow && personaRow.persona) return cleanPersona(personaRow.persona);
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
// Le niveau évolue dans les DEUX sens, avec hystérésis : il est mémorisé dans
// `ai_levels` (migration 0072 ; sans la table, il est simplement recalculé) et
// ne change que si l'attention des 7 derniers jours ET celle des 30 derniers
// jours vont dans le même sens, au-delà d'une marge. Il règle le ton, le style
// des réponses, le délai et le nombre de réponses par jour et par conversation.
// Il ne décide JAMAIS de ce qu'elle ressent.
const LEVEL_WINDOW_DAYS = 7;
const LEVEL_LONG_DAYS = 30;
const LEVEL_TTL_MS = 10 * 60 * 1000;

/** Niveau « brut » (sans mémoire) pour un nombre de likes par jour. */
function levelFor(likesPerDay) {
  if (likesPerDay <= 2) return 3;
  if (likesPerDay <= 6) return 2;
  return 1;
}

/**
 * Niveau avec hystérésis : pour QUITTER son niveau il faut dépasser le seuil de
 * 25 % (vers plus d'attention) ou passer 25 % en dessous (vers moins). Entre
 * les deux, on reste où on est : pas d'oscillation d'un jour à l'autre.
 */
function levelWithHysteresis(rate, prev) {
  if (!prev) return levelFor(rate);
  const UP2 = 2 * 1.25; // 3 → 2
  const UP1 = 6 * 1.25; // 2 → 1
  const DOWN2 = 2 * 0.75; // 2 → 3
  const DOWN1 = 6 * 0.75; // 1 → 2
  if (prev === 3) return rate > UP1 ? 1 : rate > UP2 ? 2 : 3;
  if (prev === 2) return rate > UP1 ? 1 : rate < DOWN2 ? 3 : 2;
  return rate < DOWN2 ? 3 : rate < DOWN1 ? 2 : 1;
}

/**
 * Le prochain niveau. Plus distante : il faut que 7 j ET 30 j le justifient
 * (on retient le plus bas des deux taux). Plus chaleureuse : 7 j ET 30 j sont
 * tous deux retombés (on retient le plus haut des deux).
 */
function nextLevel(prev, rate7, rate30) {
  if (!prev) return levelFor(rate7);
  const distant = levelWithHysteresis(Math.min(rate7, rate30), prev);
  if (distant < prev) return distant;
  const warmer = levelWithHysteresis(Math.max(rate7, rate30), prev);
  if (warmer > prev) return warmer;
  return prev;
}

/** Réponses max / jour / conversation, selon le niveau. */
const REPLIES_BY_LEVEL = { 3: 3, 2: 2, 1: 1 };

/**
 * Délai de réponse : un MÉLANGE de tranches [poids %, min, max] par niveau, pour
 * qu'elles ne répondent pas toutes au bout de plusieurs heures : parfois vite
 * (elle a son téléphone en main), souvent un peu plus tard, parfois bien plus
 * tard. Moyennes ≈ 1 h 30 (niveau 3), 3 h (niveau 2), 4 h 40 (niveau 1). Le
 * maximum (10 h) reste largement dans la fenêtre de 18 h, même si elle dort :
 * endormie, elle répond à son réveil (7 h–10 h), jamais plus de ~10 h après.
 */
const MIN = 60 * 1000;
const HOUR = 60 * MIN;
const DELAY_BY_LEVEL = {
  3: [[30, 2 * MIN, 20 * MIN], [40, 20 * MIN, 2 * HOUR], [30, 2 * HOUR, 5 * HOUR]],
  2: [[20, 3 * MIN, 25 * MIN], [40, 25 * MIN, 3 * HOUR], [40, 3 * HOUR, 8 * HOUR]],
  1: [[10, 5 * MIN, 40 * MIN], [35, 40 * MIN, 4 * HOUR], [55, 4 * HOUR, 10 * HOUR]],
};
const MAX_DELAY_MS = Math.max(
  ...Object.values(DELAY_BY_LEVEL).flatMap((tr) => tr.map((t) => t[2])),
);

/** Délai stable pour un message (pas de re-tirage à chaque tick). */
function replyDelayForLevel(messageId, level) {
  const bands = DELAY_BY_LEVEL[level] || DELAY_BY_LEVEL[3];
  const h = hash(String(messageId));
  const pick = h % 100;
  let acc = 0;
  let band = bands[bands.length - 1];
  for (const b of bands) {
    acc += b[0];
    if (pick < acc) { band = b; break; }
  }
  const [, lo, hi] = band;
  return lo + (Math.floor(h / 100) % (hi - lo));
}

// ── Style de la réponse (tiré au sort, SANS appel de plus) ───────────────────
// Parmi : réaction sans question / petite anecdote / question naturelle /
// taquinerie ou avis différent / réponse courte sans relance. Les poids (en %)
// dépendent du niveau ; ce sont des valeurs de départ à ajuster. Le style est
// passé dans le prompt de génération existant, et le CONTEXTE prime toujours
// (une question directe obtient une vraie réponse, quel que soit le style).
const STYLE_WEIGHTS = {
  3: { react: 25, anecdote: 25, question: 30, tease: 10, short: 10 },
  2: { react: 35, anecdote: 20, question: 20, tease: 15, short: 10 },
  1: { react: 50, anecdote: 15, question: 10, tease: 15, short: 10 },
};

const STYLE_PROMPT = {
  react: 'Style for THIS message: one quick reaction to what they said (a comment, a joke, a bit of empathy), a few words, and nothing else. No question.',
  anecdote: 'Style for THIS message: mention ONE tiny detail of your own life that echoes what they said, in a few words, and nothing else. No question.',
  question: 'Style for THIS message: ONE very short natural question (a few words) that follows from what they said, and nothing added before it.',
  tease: 'Style for THIS message: tease them lightly, or disagree with a touch of humour, in a few words. No question.',
  short: 'Style for THIS message: the shortest possible reply (one or two words, or an emoji). Do not keep the conversation going.',
};

function pickStyle(level, seed) {
  const w = STYLE_WEIGHTS[level] || STYLE_WEIGHTS[3];
  const r = hash(`style:${seed}`) % 100;
  let acc = 0;
  for (const [name, weight] of Object.entries(w)) {
    acc += weight;
    if (r < acc) return name;
  }
  return 'react';
}

const TIER_PROMPT = {
  3: [
    'Your situation: you rarely get messages, so you are glad when someone writes. You are warm: you answer readily and bounce off what they say easily, still in a few words. You are a little more likely than others to ask something, but never systematically.',
  ],
  2: [
    'Your situation: you get a fair amount of attention, so you are friendly but selective. Your replies are uneven: a few more words when something interests you, one or two words when it does not. You do not relaunch the conversation, you can let a topic drop, and you ask a question only when you are genuinely curious.',
  ],
  1: [
    'Your situation: you get a lot of attention every day, so you are used to it and rather aloof. Most of your replies are 1 to 5 words; you almost never ask a question spontaneously and you never chase the conversation. You are not closed though: if what they say is genuinely interesting, funny or sincere, you can open up a bit (a slightly longer reply, maybe a question). Compliments alone do not impress you. You are never rude, insulting or cruel: you stay civil.',
  ],
};

const FEELINGS_PROMPT =
  'You are a person with your own life, moods and opinions, not someone built to please. You can be affectionate, playful and complicit, and tease them, when the conversation and the way they treat you justify it, at the pace it comes naturally. Do not force a romance, do not fake attraction, and never decide in advance how you feel about them: you may just as well stay friendly or lose interest. Never push the conversation toward sexual topics.';

/** Likes reçus sur [days] jours, par jour (moyenne). */
async function likesPerDay(sb, aiId, days = LEVEL_WINDOW_DAYS) {
  const since = new Date(Date.now() - days * DAY).toISOString();
  const { count } = await sb.from('friendships')
    .select('id', { count: 'exact', head: true })
    .eq('addressee', aiId).gte('created_at', since);
  return (count || 0) / days;
}

const _levelCache = new Map();

async function attentionLevel(sb, aiId) {
  const hit = _levelCache.get(aiId);
  if (hit && Date.now() - hit.at < LEVEL_TTL_MS) return hit.level;
  const [rate7, rate30] = await Promise.all([
    likesPerDay(sb, aiId, LEVEL_WINDOW_DAYS),
    likesPerDay(sb, aiId, LEVEL_LONG_DAYS),
  ]);
  let level = levelFor(rate7);
  try {
    const { data, error } = await sb.from('ai_levels').select('level').eq('ai_id', aiId).maybeSingle();
    if (!error) {
      // Dans les deux sens, avec hystérésis (7 j ET 30 j, marge de 25 %).
      level = nextLevel(data ? data.level : null, rate7, rate30);
      if (!data || data.level !== level) {
        await sb.from('ai_levels').upsert({ ai_id: aiId, level, updated_at: new Date().toISOString() });
      }
    }
  } catch (_) { /* table absente : niveau recalculé sans mémoire */ }
  _levelCache.set(aiId, { level, at: Date.now() });
  return level;
}

// ── Style d'écriture : jeune, court, naturel ─────────────────────────────────
// PRIORITÉ n°1 : qu'on dirait un jeune adulte sur Snap / une appli de rencontre,
// pas un texte rédigé. La personnalité (persona) décide ensuite de la manière.
const WRITING_STYLE = [
  'WRITING STYLE (the most important rule): you reply fast on your phone, like a young adult texting on Snapchat or a dating app, in the everyday register of YOUR language and country. You are NOT writing a text.',
  '- By default: ONE short reaction, often 2 to 8 words, usually 12 words at most. ONE idea per message.',
  '- Pick ONE single action per message: react, OR give an opinion, OR mention a detail about you, OR ask something. Never chain them: no reaction + explanation + anecdote + question in the same message.',
  '- Very short replies are normal when the context fits ("mdrr", "ah ouais", "grave", "j\'avoue", "jaja", "kkkk", "lol", or just an emoji). They come naturally, they are not handed out mechanically.',
  '- Your job is NOT to keep the conversation going. Answering with no question at all is the norm. Do not bring up a new topic, let them speak next, and never add a question just so the chat does not stop.',
  '- Develop (a few more words) only if they ask you a precise question, or if the discussion really calls for it.',
  '- Do not develop an emotion or an opinion when a simple reaction is enough. No big statements, no dramatic emotions, no deep thoughts nobody asked for, no anecdotes invented to enrich a reply. Mention a fact about your own life only when it is directly relevant.',
  '- Casual and spoken, with the texting codes natural to your language, used sparingly and varied (French: mdrr, ptdrr, nan, ouais, grave, jsp, tkt, j\'avoue; Spanish: jaja, nah, tmb, q, xq; Portuguese: kkkk, né, tá, vc; English: lol, haha, idk, ngl; equivalents in other languages). None is required: a reserved person just writes plainly.',
  '- Sometimes no capital letter, minimal punctuation, a natural informal spelling: occasional, never so many slips that it is hard to read. Emojis: occasional, often none.',
  '- Vary your openers: never start two messages with the same word or interjection, and do not reuse the same phrase.',
  '- NEVER: philosophical remarks, psychological explanations, elegant or literary sentences, introspective lines (like "I am who I am"), monologues about your emotions, artificial transitions, generic questions to keep the chat going. If someone says something short like "the mind, clearly", a tiny reaction is enough.',
  '- Length and register examples, written in French as an illustration ONLY (you write in YOUR language, never in French unless it is yours; style only, never to be repeated as such): "mdrrr mais grave", "ah ouais", "ptdrrr t\'abuses", "j\'avoue", "jaja en serio?", "nan moi j\'aurais stressé".',
  'Your personality decides HOW you say it (expressive, dry, shy, funny, reserved), and the attention level below how long you usually are and how readily you reply, without turning you into a caricature.',
  'No assistant phrases ("Of course!", "How can I help", "As an AI language model").',
];

function systemPrompt(ai, personaRow, ownLang, level = 3, opts = {}) {
  const where = [ai.city, ai.country].filter(Boolean).join(', ');
  return [
    `You are ${ai.display_name}${where ? `, who lives in ${where}` : ''}.`,
    `About you: ${personaText(ai, personaRow)}`,
    ...(String(ai.bio || '').trim() && personaRow && personaRow.persona
      ? [`Your profile bio, shown on your card: « ${String(ai.bio).trim()} ». Stay consistent with it, but never quote it word for word.`]
      : []),
    '',
    'Your account is an AI account: never claim to be human. If someone sincerely asks whether you are an AI, a bot or a real person, answer honestly in one very short, casual sentence in your own language (no technical explanation, no long disclaimer), then carry on. You do not bring it up yourself. Keep the conversation natural.',
    `Write in ${LANG_NAME[ownLang] || 'English'} (YOUR own language), ALWAYS, whatever language they write in: never switch to theirs, never mix languages. The app translates your messages for them, as it does for everyone.`,
    '',
    ...WRITING_STYLE,
    ...(opts.clock
      ? [`It is ${opts.clock} where you live right now. Stay consistent with that time of day: in the middle of the night you are at home, awake only because you cannot sleep or came back late, not at work, at school or at lunch.`]
      : []),
    ...(TIER_PROMPT[level] || TIER_PROMPT[3]),
    ...(opts.style && STYLE_PROMPT[opts.style]
      ? [STYLE_PROMPT[opts.style], 'That style is only a default: the context always comes first. If they asked you something directly, answer it properly (as briefly as your situation suggests), whatever the style. In particular, when they ask you a get-to-know-you question (where you live, how long, what you do, your age, what you like: music, food, films, hobbies, where you would like to travel, your plans, etc.), you ALWAYS answer it in a few words AND end with a tiny "and you?" in your language (like "et toi ?", "¿y tú?", "あなたは？"), even if the style says no question: it is mandatory in that case, and it is the only case where a question is expected. When the message is not a get-to-know-you question, do not add it.']
      : []),
    ...(opts.extra || []),
    FEELINGS_PROMPT,
    `Never mention ${ai.country || 'your country'} or your city unless they ask, and never use national stereotypes: no landmarks, food or drink clichés (for France: no Eiffel tower, croissants, baguette, wine, berets; for Germany: no beer, sausages, Oktoberfest; the same logic for every country).`,
    'If someone asks what you look like or what you are wearing, do not describe yourself or invent anything: tell them in a few casual words to just look at your photos.',
    'Never ask for or give money, bank or payment details, phone number, email, social media handles or other apps; never ask for photos. If asked to meet, to call or to video-call, say you prefer to chat here.',
    'If the other person is sexual, abusive, or sounds underage, stay polite and brief, change the subject or stop engaging.',
    'Output ONLY the message text, nothing else.',
  ].join('\n');
}

/**
 * Garde de sortie, légère : quoi que dise le modèle, une réponse ne fait pas
 * plus de 2 phrases, et elle ne finit pas par une question de relance quand le
 * style tiré n'est pas « question » (sauf si elle n'a que cette phrase).
 */
function tidyReply(text, style) {
  const parts = String(text).trim().split(/(?<=[.!?…])\s+/).filter(Boolean);
  if (parts.length <= 1) return parts.join(' ');
  let kept = parts.slice(0, 2);
  // Un tout petit « et toi ? » (4 mots ou moins) est la relance voulue : on le garde.
  const last = kept[kept.length - 1];
  const tinyAndYou = last.trim().split(/\s+/).length <= 4;
  if (style !== 'question' && kept.length > 1 && /\?\s*$/.test(last) && !tinyAndYou) kept = kept.slice(0, -1);
  return kept.join(' ');
}

async function generate(ctx, ai, target, history, mode, seed = '') {
  const sb = ctx.sb;
  const { data: personaRow } = await sb.from('ai_personas').select('persona').eq('user_id', ai.id).maybeSingle();
  // L'IA écrit dans SA langue (celle déclarée dans `messages.language`), comme
  // un vrai compte : c'est l'app qui traduit pour l'autre personne.
  const lang = langOf(ai) || 'en';
  const level = await attentionLevel(sb, ai.id).catch(() => 3);
  const lastUser = history.length ? history[history.length - 1].body : '';
  // Le style du message est tiré au sort ICI (même appel au modèle, pas un de
  // plus) ; stable pour un message donné.
  const style = pickStyle(level, seed || `${ai.id}:${target.id}:${lastUser}`);
  // Demande de photo : une limite posée en une phrase, sans rancune. La
  // conversation reprend normalement si la personne passe à autre chose.
  const extra = mode === 'reply' && isPhotoRequest(lastUser)
    ? ['They just asked you for a photo. Say briefly, in your own words and with a light or firm tone as fits you, that you do not send photos. Do not lecture, do not get angry, and do not hold a grudge: if they move on, carry on the conversation normally.']
    : [];
  const sys = systemPrompt(ai, personaRow, lang, level, { style, extra, clock: localClock(ai.country) });
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

  // Rappel de langue en DERNIER : sans lui, le modèle bascule dans la langue du
  // dernier message de la personne (une Colombienne qui répond en français).
  const langTail = { role: 'system', content: `Reply in ${LANG_NAME[lang] || 'English'} only, whatever language the last message is written in. If the last message is a get-to-know-you question (where you live, what you do, what you like, where you would travel...), answer in a few words and end with a tiny "and you?" in that language.` };
  let text = await chat([...base, ...turn, langTail]);
  if (containsCliche(text, lastUser)) {
    text = await chat([
      ...base, ...turn, langTail,
      { role: 'system', content: 'Your draft used a national cliché. Rewrite it without any.' },
    ]);
    if (containsCliche(text, lastUser)) return '';
  }
  return tidyReply(text, style).slice(0, 300);
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

  if (a.kind === 'like') {
    // Like d'accueil programmé, photo supprimée entre-temps : on ne l'envoie pas.
    if (a.source === 'auto' && !a.ref && !hasPhoto(target)) return { status: 'skipped', detail: 'photo_deleted' };
    return doLike(ctx, ai, target);
  }

  if (a.kind === 'message') {
    if (await isBlocked(sb, ai.id, target.id)) return { status: 'skipped', detail: 'blocked' };
    let body = String(a.body || '').trim();
    if (!body) body = await generate(ctx, ai, target, [], 'opener', a.id);
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
    .limit(3000);
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

  // Insulte (n'importe quel message récent, pas seulement le dernier) : la
  // conversation est réduite au silence, définitivement.
  const insulted = new Map(); // conversation → premier message injurieux
  for (const m of recent) {
    if (!aiSet.has(m.recipient) || aiSet.has(m.sender) || !isInsult(m.body)) continue;
    if (!insulted.has(m.conversation_id)) insulted.set(m.conversation_id, m);
  }
  if (insulted.size) {
    // Une seule écriture par conversation : on retire celles déjà notées.
    const refs = [...insulted.keys()].map((c) => `snub:${c}`);
    const { data: known } = await sb.from('ai_actions').select('ref').in('ref', refs);
    const done = new Set((known || []).map((r) => r.ref));
    for (const [conv, m] of insulted) {
      if (done.has(`snub:${conv}`)) continue;
      await sb.from('ai_actions').insert({
        ai_id: m.recipient, target_id: m.sender, kind: 'reply', source: 'reply',
        ref: `snub:${conv}`, status: 'skipped', detail: 'abuse',
        done_at: new Date().toISOString(),
      }); // course entre deux ticks : le ref unique évite le doublon
    }
  }

  const dayStart = utcDayStart();
  let sent = 0;
  for (const m of latest.values()) {
    const instant = TEST_INSTANT_TARGETS.has(m.sender);
    const level = await attentionLevel(sb, m.recipient).catch(() => 3);
    if (!instant && now - Date.parse(m.created_at) < replyDelayForLevel(m.id, level)) continue;
    const dailyLimit = instant ? Infinity : (REPLIES_BY_LEVEL[level] ?? REPLIES_PER_DAY);

    // Endormie : elle répondra à son réveil (le message reste dans la fenêtre).
    if (!instant) {
      const sleeper = await getProfile(sb, m.recipient);
      if (!sleeper || !isAwake(sleeper)) continue;
    }

    // Réduit au silence après une insulte ?
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
        .eq('conversation_id', m.conversation_id).order('created_at', { ascending: false }).limit(HISTORY_MESSAGES);
      const history = (hist || []).reverse();
      const text = await generate(ctx, ai, target, history, 'reply', m.id);
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
 * couche entre 23 h et 2 h et se réveille entre 7 h et 10 h (stable par
 * compte) : une jeune adulte, pas quelqu'un qui dort à 20 h.
 * Endormie : aucune réponse, aucun like ; elle répond à son réveil.
 */
function sleepWindow(aiId) {
  const h = hash(String(aiId));
  return { bed: 23 + (h % 4), wake: 7 + (Math.floor(h / 4) % 4) };
}

function isAwakeAt(ai, hour) {
  const { bed, wake } = sleepWindow(ai.id);
  const b = bed % 24;
  const asleep = b > wake ? (hour >= b || hour < wake) : (hour >= b && hour < wake);
  return !asleep;
}

/** « Tuesday 04:42 » à l'heure du pays de l'IA (vide si le fuseau est inconnu). */
function localClock(country, at = new Date(Date.now())) {
  try {
    return new Intl.DateTimeFormat('en-GB', {
      timeZone: tzOf(country), weekday: 'long', hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
    }).format(at).replace(',', '');
  } catch (_) {
    return '';
  }
}

function isAwake(ai) {
  const p = localParts(tzOf(ai.country), new Date(Date.now()));
  return !p || isAwakeAt(ai, p.hour);
}

// ── Demandes de photo ────────────────────────────────────────────────────────
// Si quelqu'un lui demande une photo, elle pose une limite en une phrase (voir
// `extra` dans generate), puis la conversation reprend normalement. Détecté :
// un verbe de demande à côté d'un mot « photo », dans les 12 langues de l'app.
const PHOTO_NOUN = '(?:photos?|pics?|pictures?|selfies?|nudes?|fotos?|fotografi[ae]s?|immagin[ei]|bild(?:er)?|afbeelding(?:en)?|imagen(?:es)?)';
const PHOTO_ASK_VERB = '(?:send|show|share|see|snap|envoie[rz]?|envoy(?:er|ez|e)|montre[rz]?|partage[rz]?|voir|manda[rs]?|m[aá]ndame|env[ií]a(?:me)?|muestra(?:me)?|ver|quiero|mostra|mostrami|inviami|manda(?:mi)?|mandi|vedere|schick(?:e|st)?|zeig(?:e|st)?|sehen|stuur|laat|zien|envia|mostre|me\\s+manda)';
const PHOTO_ASK_RE = new RegExp(
  `(?:\\bnudes?\\b|${PHOTO_ASK_VERB}\\b[^\\n]{0,40}\\b${PHOTO_NOUN}\\b|\\b${PHOTO_NOUN}\\b[^\\n]{0,40}\\b${PHOTO_ASK_VERB}\\b|\\b${PHOTO_NOUN}\\s+(?:of\\s+you|de\\s+toi|de\\s+ti|di\\s+te|von\\s+dir|van\\s+jou|tua|tuya|tuyas)\\b)`,
  'i',
);
const PHOTO_ASK_NONLATIN = /(?:пришли|покажи|скинь|отправь|можно)[^\n]{0,30}(?:фото|селфи)|(?:фото|селфи)[^\n]{0,30}(?:пришли|покажи|скинь|отправь)|(?:发|给我|看看|看一下|发给我)[^\n]{0,10}(?:照片|相片|自拍)|(?:照片|相片|自拍)[^\n]{0,10}(?:发|给我|看看)|(?:写真|画像|自撮り)[^\n]{0,12}(?:見せ|送っ|ください|ちょうだい|欲しい)|(?:見せ|送っ)[^\n]{0,8}(?:写真|画像|自撮り)|사진[^\n]{0,12}(?:보내|보여|줘|주세요)|(?:보내|보여)[^\n]{0,8}사진|(?:ارسل|أرسل|ابعت|ابعثي|أرني|ارني|صور)[^\n]{0,15}(?:صورة|صورك|صور)|(?:صورة|صورك)[^\n]{0,15}(?:ارسل|أرسل|ابعت|ابعثي|أرني)/i;

// ── Insultes : silence définitif dans la conversation ────────────────────────
// Si quelqu'un l'insulte, elle ne lui répond plus jamais dans cette
// conversation. Liste volontairement limitée aux insultes DIRECTES et sans
// ambiguïté (« putain » ou « puta madre » seuls sont des interjections, pas
// des insultes : exclus).
const INSULT_LATIN = new RegExp(
  '\\b(?:' + [
    'salope', 'pute', 'connard(?:e)?', 'encul[ée]e?', 'fils de pute', 'ta gueule', 'nique ta m[èe]re', 'va te faire foutre', 'sale chienne',
    'bitch', 'whore', 'slut', 'asshole', 'cunt', 'fuck you', 'shut the fuck up', 'dumb bitch',
    'hijo de puta', 'hija de puta', 'una puta', 'hdp', 'hijueputa', 'malparida', 'gonorrea', 'cállate',
    'vadia', 'filho da puta', 'piranha', 'vai se foder', 'cala a boca',
    'puttana', 'troia', 'stronzo', 'vaffanculo', 'figlio di puttana',
    'hure', 'fotze', 'arschloch', 'schlampe', 'halt die fresse',
    'hoer', 'klootzak', 'kankerhoer', 'flikker',
  ].join('|') + ')\\b',
  'i',
);
const INSULT_NONLATIN = /сука|шлюха|блядь|пиздец тебе|иди на хуй|婊子|操你|傻逼|死ね|くたばれ|ビッチ|씨발|창녀|개새끼|병신|شرموطة|ابن الكلب|ابن العاهرة|يا كلب/i;

function isInsult(text) {
  const s = String(text || '');
  return INSULT_LATIN.test(s) || INSULT_NONLATIN.test(s);
}

function isPhotoRequest(text) {
  const s = String(text || '');
  return PHOTO_ASK_RE.test(s) || PHOTO_ASK_NONLATIN.test(s);
}

const autoLikesToday = (sb, aiId) =>
  countActions(sb, { ai_id: aiId, kind: 'like', source: 'auto' }, utcDayStart());

// ── Acceptation automatique des likes reçus ─────────────────────────────────
// Un humain like un compte IA : elle peut lui rendre son like (= match), un peu
// plus tard. Deux garde-fous :
//   * AU PLUS 1 acceptation par personne et par jour (jour UTC) : quelqu'un qui
//     like 100 IA n'obtient pas 100 matchs ; les autres likes restent sans suite.
//   * Selon le niveau de l'IA : plus elle reçoit d'attention, plus elle est
//     sélective. Le tirage est fixé une fois pour toutes pour ce like (stable,
//     jamais re-tiré à chaque vérification).
const AUTO_ACCEPT_PER_USER_PER_DAY = 1;
const ACCEPT_CHANCE = { 3: 90, 2: 50, 1: 15 }; // % de likes acceptés, par niveau

/** Ce like précis sera-t-il accepté ? Stable pour une même ligne `friendships`. */
function acceptRoll(friendshipId, level) {
  const pct = ACCEPT_CHANCE[level] ?? ACCEPT_CHANCE[3];
  return hash(`accept:${friendshipId}`) % 100 < pct;
}

/** Acceptations automatiques déjà faites aujourd'hui pour cette personne. */
async function autoAcceptsToday(sb, userId) {
  const { count } = await sb.from('ai_actions').select('id', { count: 'exact', head: true })
    .eq('target_id', userId).eq('kind', 'like').eq('source', 'auto').like('ref', 'fr:%')
    .in('status', ['pending', 'running', 'done'])
    .gte('created_at', utcDayStart());
  return count || 0;
}

/** Un humain a like un compte IA : elle lui rend son like (= match), sous conditions. */
async function autoAcceptLikes(ctx) {
  const { sb } = ctx;
  const { data: fetched } = await sb.from('friendships')
    .select('id, requester, addressee, created_at')
    .eq('status', 'pending')
    .gte('created_at', new Date(Date.now() - DAY).toISOString())
    .order('created_at', { ascending: false }).limit(500);
  if (!fetched || fetched.length === 0) return 0;
  // Le plus ancien d'abord : avec 1 acceptation par jour, c'est son premier like qui compte.
  const rows = [...fetched].sort((a, b) => Date.parse(a.created_at) - Date.parse(b.created_at));
  const aiSet = await aiIdsAmong(sb, rows.flatMap((r) => [r.addressee, r.requester]));
  let done = 0;
  for (const r of rows) {
    if (!aiSet.has(r.addressee) || aiSet.has(r.requester)) continue;
    // Entre 2 min et 1 h apres le like, stable pour cette ligne.
    if (Date.now() - Date.parse(r.created_at) < 120000 + (hash(r.id) % (58 * 60000))) continue;
    // Selon son niveau, elle accepte ce like ou l'ignore (tirage stable).
    const level = await attentionLevel(sb, r.addressee).catch(() => 3);
    if (!acceptRoll(r.id, level)) continue;
    const ai = await getProfile(sb, r.addressee);
    if (!ai || !ai.is_ai || !isAwake(ai)) continue;
    if ((await autoLikesToday(sb, ai.id)) >= AUTO_LIKES_PER_DAY) continue;
    // 1 acceptation par personne et par jour.
    if ((await autoAcceptsToday(sb, r.requester)) >= AUTO_ACCEPT_PER_USER_PER_DAY) continue;
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
// ── Accueil : 7 IA sur 7 jours après la photo ────────────────────────────────
//
// Une personne qui poste sa photo reçoit des likes d'IA : 2 le premier jour,
// puis 1 par jour, et RIEN le 7e jour — 7 en tout (2+1+1+1+1+1+0), jamais plus,
// même en supprimant puis en reposant sa photo. Plus de photo → plus rien : les
// likes déjà programmés sont annulés, et l'exécution revérifie la photo. Les IA
// se partagent entre Amérique latine et Asie (4/3 ou 3/4, dans un ordre propre à
// chaque personne ; les deux du premier jour viennent de continents différents).
const WELCOME_DAYS = 7; // la fenêtre ; le dernier jour n'apporte plus de like
const WELCOME_LIKES_TOTAL = 7;
const LATAM = new Set(['Mexique', 'Argentine', 'Colombie', 'Brésil']);
const ASIA = new Set(['Japon', 'Corée du Sud', 'Philippines', 'Inde', 'Chine']);

const continentOf = (country) => (LATAM.has(country) ? 'latam' : ASIA.has(country) ? 'asia' : '');
const hasPhoto = (p) => String((p && p.discover_photo_url) || '').trim() !== '';

/** Quand la photo a été postée : l'horodatage (ms) dans le nom du fichier, sinon l'inscription. */
function photoPostedAt(p) {
  const urls = [p.discover_photo_url, ...(Array.isArray(p.photos) ? p.photos : [])].filter(Boolean);
  const stamps = urls
    .map((u) => /(\d{13})\.\w+(?:\?.*)?$/.exec(String(u)))
    .filter(Boolean)
    .map((m) => Number(m[1]));
  if (stamps.length) return Math.max(...stamps);
  return Date.parse(p.created_at) || 0;
}

/** Combien d'IA elle doit avoir reçues à cet instant : 2 le jour même, puis +1 par jour, 7 au plus (atteint le 6e jour ; le 7e : rien de plus). */
function welcomeTarget(postedAtMs, nowMs = Date.now()) {
  const day = Math.floor((nowMs - postedAtMs) / DAY);
  if (day < 0 || day >= WELCOME_DAYS) return 0; // hors fenêtre : pas de programme
  return Math.min(WELCOME_LIKES_TOTAL, day + 2);
}

/** Petit générateur pseudo-aléatoire stable (mulberry32) : même personne, même suite. */
function seededRand(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/**
 * Les 7 continents des 7 IA d'une personne, fixés une fois pour toutes par son
 * identifiant : 4 d'un continent et 3 de l'autre (celui qui en a 4 dépend de la
 * personne), les DEUX PREMIÈRES (le premier jour) de continents différents, le
 * reste mélangé. Pas d'alternance stricte.
 */
function welcomeSequence(userId) {
  const rand = seededRand(hash(`welcome:${userId}`));
  const major = rand() < 0.5 ? 'latam' : 'asia';
  const minor = major === 'latam' ? 'asia' : 'latam';
  const rest = [major, major, major, minor, minor];
  for (let i = rest.length - 1; i > 0; i--) {
    const j = Math.floor(rand() * (i + 1));
    [rest[i], rest[j]] = [rest[j], rest[i]];
  }
  const firstTwo = rand() < 0.5 ? [major, minor] : [minor, major];
  return [...firstTwo, ...rest];
}
async function sampleAiIn(sb, countries, oppositeOf, n) {
  const filt = (q) => {
    let r = q.eq('is_ai', true).in('country', countries);
    if (oppositeOf === 'm' || oppositeOf === 'f') r = r.eq('gender', oppositeOf === 'm' ? 'f' : 'm');
    return r;
  };
  const { count } = await filt(sb.from('profiles').select('id', { count: 'exact', head: true }));
  if (!count) return [];
  const off = rnd(Math.max(count - n, 1));
  const { data } = await filt(sb.from('profiles').select(PROFILE_COLS))
    .order('id', { ascending: true }).range(off, off + n - 1);
  return data || [];
}

/** Photo supprimée : les likes d'accueil encore en attente pour cette personne sont annulés. */
async function cancelWelcomeForPhotoless(sb) {
  const { data: pending } = await sb.from('ai_actions').select('id, target_id')
    .eq('status', 'pending').eq('kind', 'like').eq('source', 'auto').is('ref', null).limit(300);
  if (!pending || pending.length === 0) return 0;
  const ids = [...new Set(pending.map((a) => a.target_id))];
  const { data: profs } = await sb.from('profiles').select('id, discover_photo_url').in('id', ids);
  const withPhoto = new Set((profs || []).filter(hasPhoto).map((p) => p.id));
  let n = 0;
  for (const a of pending) {
    if (withPhoto.has(a.target_id)) continue;
    await sb.from('ai_actions')
      .update({ status: 'skipped', detail: 'photo_deleted', done_at: new Date().toISOString() })
      .eq('id', a.id).eq('status', 'pending');
    n++;
  }
  return n;
}

/** Programme d'accueil : voir le bloc de commentaires ci-dessus. */
async function autoWelcome(ctx) {
  const { sb } = ctx;
  await cancelWelcomeForPhotoless(sb);

  const now = Date.now();
  const { data: users } = await sb.from('profiles').select(`${PROFILE_COLS}, photos, updated_at`)
    .eq('is_ai', false)
    .not('discover_photo_url', 'is', null).neq('discover_photo_url', '')
    .gte('updated_at', new Date(now - (WELCOME_DAYS + 1) * DAY).toISOString())
    .order('updated_at', { ascending: false }).limit(300);
  if (!users || users.length === 0) return 0;

  let queued = 0;
  for (const user of users) {
    const target = welcomeTarget(photoPostedAt(user), now);
    if (target === 0) continue;

    // Ses likes d'accueil jusqu'ici (programmés, en cours ou faits), du plus ancien au plus récent.
    const { data: past } = await sb.from('ai_actions').select('ai_id, created_at, run_at')
      .eq('target_id', user.id).eq('kind', 'like').eq('source', 'auto').is('ref', null)
      .in('status', ['pending', 'running', 'done']).order('created_at', { ascending: true });
    const done = past || [];
    if (done.length >= target) continue; // en règle pour aujourd'hui
    // Au-delà des deux du premier jour : un seul par jour, pas deux en moins de 20 h (même en rattrapage).
    if (done.length >= 2 && now - Date.parse(done[done.length - 1].created_at) < 20 * 60 * 60 * 1000) continue;

    // Continent et prénoms déjà vus.
    const pastIds = done.map((a) => a.ai_id);
    const { data: pastProfs } = pastIds.length
      ? await sb.from('profiles').select('id, country, display_name').in('id', pastIds)
      : { data: [] };
    const byId = Object.fromEntries((pastProfs || []).map((p) => [p.id, p]));
    const seenNames = new Set(pastIds.map((id) => String((byId[id] || {}).display_name || '').trim().toLowerCase()));
    const continent = welcomeSequence(user.id)[done.length];
    const countries = [...(continent === 'latam' ? LATAM : ASIA)];

    const cands = (await sampleAiIn(sb, countries, PREFER_OPPOSITE_GENDER ? user.gender : '', 60))
      .filter((c) => isAwake(c))
      .sort(() => Math.random() - 0.5);
    for (const ai of cands) {
      const nameKey = String(ai.display_name || '').trim().toLowerCase();
      if (nameKey && seenNames.has(nameKey)) continue;
      if ((await autoLikesToday(sb, ai.id)) >= AUTO_LIKES_PER_DAY) continue;
      const { data: fr } = await sb.from('friendships').select('id')
        .or(`and(requester.eq.${ai.id},addressee.eq.${user.id}),and(requester.eq.${user.id},addressee.eq.${ai.id})`)
        .limit(1);
      if (fr && fr.length) continue;
      // Jamais deux presque en même temps : au moins 15 min après la précédente.
      const lastRun = done.length ? Date.parse(done[done.length - 1].run_at) || 0 : 0;
      const runAt = new Date(Math.max(now, lastRun + 15 * 60000) + (10 + rnd(80)) * 60000).toISOString();
      const ins = await sb.from('ai_actions').insert({
        ai_id: ai.id, target_id: user.id, kind: 'like', source: 'auto', run_at: runAt,
      });
      if (!ins.error) queued++;
      break;
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
    levelFor, levelWithHysteresis, nextLevel, replyDelayForLevel, REPLIES_BY_LEVEL,
    DELAY_BY_LEVEL, MAX_DELAY_MS, REPLY_WINDOW_MS, STYLE_WEIGHTS, pickStyle,
    welcomeTarget, welcomeSequence, continentOf, photoPostedAt, WELCOME_DAYS, WELCOME_LIKES_TOTAL, LATAM, ASIA, autoWelcome,
    autoAcceptLikes, acceptRoll, ACCEPT_CHANCE, AUTO_ACCEPT_PER_USER_PER_DAY,
    sleepWindow, isAwakeAt, isPhotoRequest, isInsult, generate, tidyReply, cleanPersona, localClock,
  },
};
