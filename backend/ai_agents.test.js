'use strict';

// Run with: node --test backend/ai_agents.test.js

const test = require('node:test');
const assert = require('node:assert/strict');

const { _test: t } = require('./ai_agents');

const AI = { display_name: 'Carolina', country: 'Colombie', city: 'Cartagena', age: 25 };
const HOUR = 3600 * 1000;

// ── Niveaux ──────────────────────────────────────────────────────────────────

test('levelFor: few likes → warm (3), some → selective (2), many → aloof (1)', () => {
  assert.equal(t.levelFor(0), 3);
  assert.equal(t.levelFor(2), 3);
  assert.equal(t.levelFor(3), 2);
  assert.equal(t.levelFor(6), 2);
  assert.equal(t.levelFor(7), 1);
  assert.equal(t.levelFor(10), 1);
});

test('levels move in BOTH directions, only when 7 d AND 30 d agree', () => {
  // Pic de popularité sur 7 j seulement : pas de changement.
  assert.equal(t.nextLevel(3, 10, 1), 3);
  // Popularité durable : elle passe à 1.
  assert.equal(t.nextLevel(3, 10, 9), 1);
  // Elle redescend quand 7 j ET 30 j sont retombés…
  assert.equal(t.nextLevel(1, 1, 1), 3);
  assert.equal(t.nextLevel(1, 3, 3), 2);
  // …mais pas si seule la dernière semaine est calme.
  assert.equal(t.nextLevel(1, 1, 9), 1);
  // Pas de mémoire (table absente) : niveau brut.
  assert.equal(t.nextLevel(null, 10, 0), 1);
});

test('hysteresis: no flip-flop around a threshold', () => {
  // Autour du seuil 2/jour : un niveau 3 ne passe à 2 qu'au-delà de 2,5 ;
  // un niveau 2 ne repasse à 3 qu'en dessous de 1,5.
  assert.equal(t.levelWithHysteresis(2.3, 3), 3);
  assert.equal(t.levelWithHysteresis(2.6, 3), 2);
  assert.equal(t.levelWithHysteresis(1.7, 2), 2);
  assert.equal(t.levelWithHysteresis(1.4, 2), 3);
  // Autour du seuil 6/jour.
  assert.equal(t.levelWithHysteresis(7, 2), 2);
  assert.equal(t.levelWithHysteresis(7.6, 2), 1);
  assert.equal(t.levelWithHysteresis(5, 1), 1);
  assert.equal(t.levelWithHysteresis(4.4, 1), 2);
  // Une série quotidienne qui oscille autour de 2 ne change jamais le niveau.
  let lvl = 3;
  for (const r of [1.9, 2.4, 1.8, 2.3, 2.0, 2.4, 1.7]) lvl = t.nextLevel(lvl, r, r);
  assert.equal(lvl, 3);
});

// ── Délais, fenêtre, sommeil ────────────────────────────────────────────────

test('reply delays: stable, varied, ordered by level, and inside the reply window', () => {
  const stats = {};
  for (const level of [3, 2, 1]) {
    const ds = Array.from({ length: 4000 }, (_, i) => t.replyDelayForLevel(`msg-${i}`, level));
    stats[level] = { avg: ds.reduce((a, b) => a + b, 0) / ds.length, min: Math.min(...ds), max: Math.max(...ds), ds };
    assert.equal(t.replyDelayForLevel('msg-7', level), t.replyDelayForLevel('msg-7', level)); // stable
  }
  // Plus d'attention → plus lent en moyenne.
  assert.ok(stats[3].avg < stats[2].avg && stats[2].avg < stats[1].avg);
  // Moyennes plausibles (≈ 1h30, 3h, 4h40).
  assert.ok(stats[3].avg > 1 * HOUR && stats[3].avg < 2.2 * HOUR, `L3 ${stats[3].avg / HOUR}`);
  assert.ok(stats[2].avg > 2.2 * HOUR && stats[2].avg < 4 * HOUR, `L2 ${stats[2].avg / HOUR}`);
  assert.ok(stats[1].avg > 3.5 * HOUR && stats[1].avg < 6 * HOUR, `L1 ${stats[1].avg / HOUR}`);
  // Pas toutes absentes : une part répond en moins de 30 min à chaque niveau.
  for (const level of [3, 2, 1]) {
    const quick = stats[level].ds.filter((d) => d <= 30 * 60 * 1000).length / stats[level].ds.length;
    assert.ok(quick >= 0.05, `L${level} quick ${quick}`);
  }
  // Le plus long délai + son attente de réveil reste dans la fenêtre : endormie,
  // elle répond à son réveil (≤ 10 h), jamais au-delà de MAX(délai, 10 h).
  assert.equal(t.MAX_DELAY_MS, 10 * HOUR);
  assert.ok(t.MAX_DELAY_MS + 0 < t.REPLY_WINDOW_MS);
  assert.ok(t.REPLY_WINDOW_MS >= 24 * HOUR);
  for (const level of [3, 2, 1]) assert.ok(stats[level].max <= t.MAX_DELAY_MS && stats[level].min >= 2 * 60 * 1000);
  assert.ok(t.REPLIES_BY_LEVEL[3] > t.REPLIES_BY_LEVEL[2] && t.REPLIES_BY_LEVEL[2] > t.REPLIES_BY_LEVEL[1]);
});

test('a reply never becomes impossible: delay + sleep always fit the window', () => {
  // Pire cas : le message arrive à une heure quelconque, le délai tombe en
  // pleine nuit, elle attend son réveil. On simule heure par heure.
  for (let i = 0; i < 400; i++) {
    const ai = { id: `ai-${i}` };
    const { wake } = t.sleepWindow(ai.id);
    for (let startHour = 0; startHour < 24; startHour++) {
      for (const level of [3, 2, 1]) {
        const delay = t.replyDelayForLevel(`m-${i}-${startHour}`, level);
        let wait = Math.ceil(delay / HOUR);
        // On avance heure par heure jusqu'à ce qu'elle soit réveillée.
        let hour = (startHour + wait) % 24;
        let extra = 0;
        while (!t.isAwakeAt(ai, hour) && extra < 24) { hour = (hour + 1) % 24; extra++; }
        assert.ok(wait + extra <= t.REPLY_WINDOW_MS / HOUR, `ai=${i} start=${startHour} L${level}: ${wait + extra} h`);
      }
    }
    assert.ok(wake >= 7 && wake <= 10);
  }
});

test('each AI sleeps at its own hours, and only at night', () => {
  const wins = new Set();
  for (let i = 0; i < 300; i++) {
    const w = t.sleepWindow(`ai-${i}`);
    wins.add(`${w.bed}-${w.wake}`);
    assert.ok([23, 24, 25, 26].includes(w.bed), `bed ${w.bed}`);
    assert.ok(w.wake >= 7 && w.wake <= 10, `wake ${w.wake}`);
    for (const h of [10, 12, 14, 17, 20, 21, 22]) {
      assert.equal(t.isAwakeAt({ id: `ai-${i}` }, h), h >= w.wake, `h=${h} wake=${w.wake}`);
    }
    for (const h of [3, 4, 5, 6]) assert.equal(t.isAwakeAt({ id: `ai-${i}` }, h), false);
  }
  assert.ok(wins.size >= 6, `only ${wins.size} distinct windows`);
});

// ── Styles de réponse ────────────────────────────────────────────────────────

test('style weights add up to 100 and follow the requested table', () => {
  const expected = {
    3: { react: 25, anecdote: 25, question: 30, tease: 10, short: 10 },
    2: { react: 35, anecdote: 20, question: 20, tease: 15, short: 10 },
    1: { react: 50, anecdote: 15, question: 10, tease: 15, short: 10 },
  };
  assert.deepEqual(t.STYLE_WEIGHTS, expected);
  for (const l of [1, 2, 3]) {
    assert.equal(Object.values(t.STYLE_WEIGHTS[l]).reduce((a, b) => a + b, 0), 100);
  }
});

test('same messages, different levels → different style mix (measured)', () => {
  const N = 20000;
  const share = {};
  for (const level of [3, 2, 1]) {
    const c = { react: 0, anecdote: 0, question: 0, tease: 0, short: 0 };
    for (let i = 0; i < N; i++) c[t.pickStyle(level, `m-${i}`)]++;
    share[level] = Object.fromEntries(Object.entries(c).map(([k, v]) => [k, v / N]));
    // Proche du tableau (±3 points).
    for (const [k, w] of Object.entries(t.STYLE_WEIGHTS[level])) {
      assert.ok(Math.abs(share[level][k] - w / 100) < 0.03, `L${level} ${k}: ${share[level][k]}`);
    }
  }
  // Le niveau 3 pose bien plus de questions que le niveau 1, qui réagit plus.
  assert.ok(share[3].question > share[2].question && share[2].question > share[1].question);
  assert.ok(share[1].react > share[2].react && share[2].react > share[3].react);
  // Stable pour un même message.
  assert.equal(t.pickStyle(2, 'msg-42'), t.pickStyle(2, 'msg-42'));
});

test('the prompt carries the chosen style and lets context win', () => {
  const p = t.systemPrompt(AI, null, 'es', 3, { style: 'react' });
  assert.match(p, /Style for THIS message: just react/);
  assert.match(p, /context always comes first/);
  assert.match(p, /Do NOT ask a question in every message/);
  // Plus de « pose-lui toujours une question ».
  assert.doesNotMatch(p, /or ask them something/);
});

// ── Prompts ──────────────────────────────────────────────────────────────────

test('levels give concrete, different behaviours; same structure otherwise', () => {
  const p3 = t.systemPrompt(AI, null, 'es', 3).split('\n');
  const p2 = t.systemPrompt(AI, null, 'es', 2).split('\n');
  const p1 = t.systemPrompt(AI, null, 'es', 1).split('\n');
  assert.equal(p3.length, p1.length);
  assert.equal(p2.length, p1.length);
  assert.equal(p3.filter((l, i) => l !== p1[i]).length, 1);
  assert.match(p3.join('\n'), /warm and chatty/);
  assert.match(p3.join('\n'), /ask them about themselves more readily/);
  assert.match(p2.join('\n'), /do not keep the conversation going systematically/i);
  assert.match(p1.join('\n'), /usually short/);
  assert.match(p1.join('\n'), /rarely ask questions spontaneously/);
  assert.match(p1.join('\n'), /can open up/);
});

test('feelings: affection and teasing allowed, but never forced or pre-decided', () => {
  for (const level of [1, 2, 3]) {
    const p = t.systemPrompt(AI, null, 'es', level);
    assert.match(p, /affectionate, playful and complicit/);
    assert.match(p, /Do not force a romance/);
    assert.match(p, /never decide in advance/i);
    assert.match(p, /Never push the conversation toward sexual topics/);
    assert.doesNotMatch(p, /girlfriend/i);
    assert.doesNotMatch(p, /never flirt/i);
  }
  assert.match(t.systemPrompt(AI, null, 'es', 1), /never rude/i);
});

test('the prompt keeps the honest AI disclosure and the safety rules', () => {
  for (const level of [1, 2, 3]) {
    const p = t.systemPrompt(AI, null, 'es', level);
    assert.match(p, /never claim to be human/i);
    assert.match(p, /answer honestly/i);
    assert.doesNotMatch(p, /always answer "No\."/);
    assert.doesNotMatch(p, /Never admit to being an AI/i);
    assert.match(p, /sexual, abusive, or sounds underage/);
    assert.match(p, /never ask for photos/i);
  }
});

test('the AI writes in its own language', () => {
  assert.match(t.systemPrompt(AI, null, 'es', 3), /Write in Spanish \(YOUR own language\)/);
  assert.match(t.systemPrompt(AI, null, 'ja', 3), /Write in Japanese/);
});

// ── Demandes de photo ────────────────────────────────────────────────────────

test('photo requests are detected in the app languages, ordinary talk is not', () => {
  const yes = [
    'send me a pic', 'can you send a photo of you?', 'show me a selfie', 'got any nudes',
    'tu peux m\'envoyer une photo ?', 'envoie une photo de toi', 'quiero ver una foto tuya',
    'mándame una foto', 'manda foto', 'mi mandi una foto?', 'schick mir ein Foto', 'zeig mir ein Bild von dir',
    'stuur een foto', 'me manda uma foto', 'пришли фото', 'покажи селфи', '发张照片给我', '写真を送ってください',
    '사진 보내줘', 'ارسل صورتك',
  ];
  const no = [
    'I love taking photos of the sea', 'nice photography', 'hello how are you', 'I work as a photographer',
    'what do you do in São Paulo?', 'j\'adore la photographie', 'me gusta la fotografía', 'hola, qué tal',
  ];
  for (const s of yes) assert.equal(t.isPhotoRequest(s), true, s);
  for (const s of no) assert.equal(t.isPhotoRequest(s), false, s);
});

