'use strict';

// Run with: node --test backend/ai_agents.test.js

const test = require('node:test');
const assert = require('node:assert/strict');

const { _test: t } = require('./ai_agents');

const AI = { display_name: 'Carolina', country: 'Colombie', city: 'Cartagena', age: 25 };

test('levelFor: few likes → warm (3), some → selective (2), many → aloof (1)', () => {
  assert.equal(t.levelFor(0), 3);
  assert.equal(t.levelFor(1), 3);
  assert.equal(t.levelFor(2), 3);
  assert.equal(t.levelFor(3), 2);
  assert.equal(t.levelFor(6), 2);
  assert.equal(t.levelFor(7), 1);
  assert.equal(t.levelFor(10), 1);
});

test('the more attention, the slower and the fewer replies', () => {
  assert.ok(t.REPLIES_BY_LEVEL[3] > t.REPLIES_BY_LEVEL[2]);
  assert.ok(t.REPLIES_BY_LEVEL[2] > t.REPLIES_BY_LEVEL[1]);
  for (let i = 0; i < 200; i++) {
    const id = `msg-${i}`;
    const d3 = t.replyDelayForLevel(id, 3);
    const d2 = t.replyDelayForLevel(id, 2);
    const d1 = t.replyDelayForLevel(id, 1);
    assert.ok(d3 >= t.DELAY_BY_LEVEL[3][0] && d3 < t.DELAY_BY_LEVEL[3][1]);
    assert.ok(d2 >= t.DELAY_BY_LEVEL[2][0] && d2 < t.DELAY_BY_LEVEL[2][1]);
    assert.ok(d1 >= t.DELAY_BY_LEVEL[1][0] && d1 < t.DELAY_BY_LEVEL[1][1]);
    assert.equal(t.replyDelayForLevel(id, 1), d1); // stable, no re-roll per tick
  }
  // Longest delay stays inside the reply window (18 h).
  assert.ok(t.DELAY_BY_LEVEL[1][1] < 18 * 60 * 60 * 1000);
});

test('level 3 answers in hours, not seconds: ~2 h on average, and it varies', () => {
  const HOUR = 3600 * 1000;
  const ds = Array.from({ length: 2000 }, (_, i) => t.replyDelayForLevel(`m-${i}`, 3));
  const avg = ds.reduce((a, b) => a + b, 0) / ds.length;
  assert.ok(avg > 1.5 * HOUR && avg < 2.7 * HOUR, `avg ${(avg / HOUR).toFixed(2)} h`);
  assert.ok(Math.min(...ds) >= 20 * 60 * 1000);
  assert.ok(Math.max(...ds) <= 4 * HOUR);
  assert.ok(new Set(ds.map((d) => Math.floor(d / (15 * 60 * 1000)))).size > 8); // spread out
});

test('same structure at every level, only the situation paragraph changes', () => {
  const p3 = t.systemPrompt(AI, null, 'es', 3).split('\n');
  const p1 = t.systemPrompt(AI, null, 'es', 1).split('\n');
  assert.equal(p3.length, p1.length);
  const differing = p3.filter((l, i) => l !== p1[i]);
  assert.equal(differing.length, 1);
  assert.match(p1.join('\n'), /aloof/);
  assert.match(p3.join('\n'), /warm/);
});

test('no level pre-decides feelings, and none allows rudeness', () => {
  for (const level of [1, 2, 3]) {
    const p = t.systemPrompt(AI, null, 'es', level);
    assert.match(p, /ONLY if how they treat you justifies it/);
    assert.match(p, /Never decide in advance/);
    assert.doesNotMatch(p, /girlfriend/i);
  }
  assert.match(t.systemPrompt(AI, null, 'es', 1), /never rude/i);
});

test('the prompt never tells the model to deny being an AI', () => {
  for (const level of [1, 2, 3]) {
    const p = t.systemPrompt(AI, null, 'es', level);
    assert.match(p, /never claim to be human/i);
    assert.match(p, /answer honestly/i);
    assert.doesNotMatch(p, /always answer "No\."/);
    assert.doesNotMatch(p, /Never admit to being an AI/i);
  }
});

test('the AI writes in its own language', () => {
  assert.match(t.systemPrompt(AI, null, 'es', 3), /Write in Spanish \(YOUR own language\)/);
  assert.match(t.systemPrompt(AI, null, 'ja', 3), /Write in Japanese/);
});

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

test('each AI sleeps at its own hours, and only at night', () => {
  const wins = new Set();
  for (let i = 0; i < 300; i++) {
    const w = t.sleepWindow(`ai-${i}`);
    wins.add(`${w.bed}-${w.wake}`);
    assert.ok([22, 23, 24].includes(w.bed), `bed ${w.bed}`);
    assert.ok(w.wake >= 6 && w.wake <= 9, `wake ${w.wake}`);
    assert.equal(t.sleepWindow(`ai-${i}`).bed, w.bed); // stable
    for (const h of [12, 14, 17]) assert.equal(t.isAwakeAt({ id: `ai-${i}` }, h), true);
    for (const h of [1, 2, 3, 4, 5]) assert.equal(t.isAwakeAt({ id: `ai-${i}` }, h), false);
  }
  assert.ok(wins.size >= 6, `only ${wins.size} distinct windows`);
});
