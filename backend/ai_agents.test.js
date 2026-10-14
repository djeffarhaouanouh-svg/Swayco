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
  assert.match(p, /Style for THIS message: one quick reaction/);
  assert.match(p, /context always comes first/);
  assert.match(p, /Answering with no question at all is the norm/);
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
  assert.match(p3.join('\n'), /warm: you answer readily/);
  assert.match(p3.join('\n'), /a little more likely than others to ask/);
  assert.match(p2.join('\n'), /do not relaunch the conversation/i);
  assert.match(p1.join('\n'), /1 to 5 words/);
  assert.match(p1.join('\n'), /almost never ask a question spontaneously/);
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


test('writing style: short, texting register, no chatbot or literary tone', () => {
  for (const level of [1, 2, 3]) {
    const p = t.systemPrompt(AI, null, 'es', level);
    assert.match(p, /WRITING STYLE \(the most important rule\)/);
    assert.match(p, /ONE short reaction, often 2 to 8 words, usually 12 words at most/);
    assert.match(p, /ONE idea per message/);
    assert.match(p, /Never chain them/);
    assert.match(p, /NOT to keep the conversation going/);
    assert.match(p, /Answering with no question at all is the norm/);
    assert.match(p, /never add a question just so the chat does not stop/);
    assert.match(p, /NEVER: philosophical remarks/);
    assert.match(p, /Vary your openers/);
    assert.match(p, /Snapchat or a dating app/);
    assert.match(p, /no anecdotes invented to enrich a reply/);
    assert.doesNotMatch(p, /uf q fuerte/); // le modèle recopiait l'exemple
  }
  // Le style court est avant les consignes de niveau (il domine).
  const p = t.systemPrompt(AI, null, 'es', 1);
  assert.ok(p.indexOf('WRITING STYLE') < p.indexOf('Your situation'));
});

test('personas: instructions that push long, relaunching replies are removed on read', () => {
  const raw = "Lucía, 22, lives in Mendoza, Argentine. Interests: Tennis. Lucía bakes when she is stressed. Texting style: calm and curious, replies with a small story. Here for: Pratiquer une langue. Talks about Lucía's own life with small concrete details, and mostly asks about the other person.";
  const out = t.cleanPersona(raw);
  assert.doesNotMatch(out, /mostly asks about the other person/);
  assert.doesNotMatch(out, /Talks about/);
  assert.doesNotMatch(out, /small story/);
  assert.match(out, /Lucía bakes when she is stressed/); // les faits restent
  assert.match(out, /calm and curious/);
  assert.match(t.cleanPersona('Texting style: warm and teasing, asks a lot of questions.'), /warm and teasing\./);
  // Le prompt final n'en contient plus.
  const p = t.systemPrompt(AI, { persona: raw }, 'es', 3);
  assert.doesNotMatch(p, /mostly asks about the other person/);
});

test('tidyReply: max 2 sentences, no relaunch question unless the style is question', () => {
  assert.equal(t.tidyReply('jaja sí', 'react'), 'jaja sí');
  assert.equal(t.tidyReply('jaja sí. ¿Y qué tal te fue hoy en el trabajo?', 'react'), 'jaja sí.'); // longue question de relance : retirée
  assert.equal(t.tidyReply('Vivo en Cartagena. ¿Y tú?', 'react'), 'Vivo en Cartagena. ¿Y tú?'); // petit « et toi ? » : gardé
  assert.equal(t.tidyReply('Je vis à Osaka. Et toi ?', 'react'), 'Je vis à Osaka. Et toi ?');
  assert.equal(t.tidyReply('jaja sí. ¿Y tú juegas?', 'question'), 'jaja sí. ¿Y tú juegas?');
  assert.equal(t.tidyReply('uno. dos. tres. cuatro.', 'react'), 'uno. dos.');
  assert.equal(t.tidyReply('¿en serio?', 'react'), '¿en serio?'); // une seule phrase : intacte
});


test('the prompt tells the AI the local time of her country (one line, nothing else changes)', () => {
  const clock = t.localClock('Japon', new Date('2026-10-13T19:42:00Z')); // 04:42 à Osaka
  assert.match(clock, /Wednesday 04:42/);
  const withClock = t.systemPrompt(AI, null, 'ja', 3, { clock }).split('\n');
  const without = t.systemPrompt(AI, null, 'ja', 3).split('\n');
  assert.equal(withClock.length, without.length + 1);
  assert.deepEqual(withClock.filter((l) => !l.startsWith('It is ')), without);
  assert.match(withClock.join('\n'), /It is Wednesday 04:42 where you live right now/);
  assert.match(withClock.join('\n'), /not at work, at school or at lunch/);
});

test('the AI knows the bio shown on her card (once, only when a persona exists)', () => {
  const withBio = { ...AI, bio: 'Gym lunes y miércoles; el resto del tiempo, sofá.' };
  const p = t.systemPrompt(withBio, { persona: 'Carolina, 25, lives in Cartagena.' }, 'es', 3);
  assert.match(p, /Your profile bio, shown on your card: « Gym lunes y miércoles; el resto del tiempo, sofá\. »/);
  assert.match(p, /never quote it word for word/);
  // Pas de persona : le texte de secours contient déjà la bio, pas de doublon.
  const noPersona = t.systemPrompt(withBio, null, 'es', 3);
  assert.equal((noPersona.match(/Gym lunes/g) || []).length, 1);
  // Sans bio : rien ne change.
  assert.doesNotMatch(t.systemPrompt(AI, { persona: 'x' }, 'es', 3), /profile bio/);
});

test('insults are detected (silence for good); interjections, jokes and normal talk are not', () => {
  const yes = [
    'T\'es qu\'une salope', 'espèce de connard', 'ferme ta gueule', 'ta gueule', 'you are a bitch', 'fuck you', 'shut the fuck up',
    'eres una puta', 'hijo de puta', 'cállate', 'sua vadia', 'vai se foder', 'sei una puttana', 'vaffanculo', 'du bist ein arschloch',
    'jij bent een klootzak', 'ты сука', '你这个婊子', 'くたばれ', '씨발', 'يا كلب',
  ];
  const no = [
    'putain trop bien ce match', 'putain', 'la puta madre qué golazo', 'ça va ?', 'hola, qué tal', 'tu fais quoi ce soir ?',
    'PD: te llamo mañana', 'I love my dog', 'bonne nuit', 'merci beaucoup', 'tu es belle', 'j\'adore ta photo',
  ];
  for (const s of yes) assert.equal(t.isInsult(s), true, s);
  for (const s of no) assert.equal(t.isInsult(s), false, s);
});

// ── Accueil : 2 IA le premier jour, puis 1 par jour, 0 le 7e jour ───────────

test('welcome: 2 the first day, then +1 a day, 7 in all, nothing on day 7, nothing outside', () => {
  const D = 24 * 3600 * 1000;
  const t0 = Date.parse('2026-10-14T10:00:00Z');
  const want = (hoursAfter) => t.welcomeTarget(t0, t0 + hoursAfter * 3600 * 1000);
  assert.equal(want(0), 2); // le jour de la photo : 2
  assert.equal(want(23), 2);
  assert.equal(want(24), 3);
  assert.equal(want(2 * 24), 4);
  assert.equal(want(3 * 24), 5);
  assert.equal(want(4 * 24), 6);
  assert.equal(want(5 * 24), 7); // 6e jour : le 7e like
  assert.equal(want(6 * 24), 7); // 7e jour : rien de plus
  assert.equal(want(7 * 24 - 1), 7);
  assert.equal(want(7 * 24), 0); // fenêtre finie
  assert.equal(want(-3), 0);
  assert.equal(t.welcomeTarget(t0 - 30 * D, t0), 0);
  // Nombre de nouveaux likes par jour : 2, 1, 1, 1, 1, 1, 0 = 7.
  const perDay = [];
  let prev = 0;
  for (let d = 0; d < 7; d++) { const w = want(d * 24 + 1); perDay.push(w - prev); prev = w; }
  assert.deepEqual(perDay, [2, 1, 1, 1, 1, 1, 0]);
  assert.equal(perDay.reduce((a, b) => a + b, 0), t.WELCOME_LIKES_TOTAL);
  assert.equal(t.WELCOME_LIKES_TOTAL, 7);
});

test('welcome: the photo date comes from the file name, else from sign-up', () => {
  assert.equal(t.photoPostedAt({ discover_photo_url: 'https://x/avatars/discover/u/1785157421938.png' }), 1785157421938);
  assert.equal(t.photoPostedAt({
    discover_photo_url: 'https://x/discover/u/1785157421938.png',
    photos: ['https://x/discover/u/1785157421938.png', 'https://x/discover/u/1785165012346.png?t=1'],
  }), 1785165012346); // la plus récente
  assert.equal(t.photoPostedAt({ discover_photo_url: 'https://x/p.png', created_at: '2026-10-01T00:00:00Z' }), Date.parse('2026-10-01T00:00:00Z'));
});

test('welcome: 7 AIs split Latin America / Asia 4-3 or 3-4; the first two differ; stable per person', () => {
  assert.deepEqual([...t.LATAM].sort(), ['Argentine', 'Brésil', 'Colombie', 'Mexique']);
  assert.ok(t.ASIA.has('Japon') && t.ASIA.has('Corée du Sud') && t.ASIA.has('Philippines') && t.ASIA.has('Inde'));
  assert.equal(t.continentOf('Colombie'), 'latam');
  assert.equal(t.continentOf('Japon'), 'asia');
  assert.equal(t.continentOf('France'), '');
  let latamMajor = 0, asiaMajor = 0, firstLatam = 0;
  for (let i = 0; i < 400; i++) {
    const seq = t.welcomeSequence(`user-${i}`);
    assert.equal(seq.length, 7);
    const l = seq.filter((c) => c === 'latam').length;
    assert.ok(l === 3 || l === 4, `user-${i}: ${seq.join(',')}`);
    assert.equal(seq.length - l, 7 - l);
    assert.notEqual(seq[0], seq[1]); // les deux du premier jour : un de chaque
    assert.deepEqual(t.welcomeSequence(`user-${i}`), seq); // stable : même personne, même suite
    if (l === 4) latamMajor++; else asiaMajor++;
    if (seq[0] === 'latam') firstLatam++;
  }
  // Les deux répartitions et les deux ordres existent, à peu près à égalité.
  assert.ok(latamMajor > 120 && asiaMajor > 120, `${latamMajor}/${asiaMajor}`);
  assert.ok(firstLatam > 120 && firstLatam < 280, `${firstLatam}`);
});


test('the prompt asks for a tiny "and you?" after get-to-know-you questions', () => {
  const p = t.systemPrompt(AI, null, 'ja', 3, { style: 'react' });
  assert.match(p, /get-to-know-you question/);
  assert.match(p, /tiny "and you\?" in your language/);
  assert.match(p, /ALWAYS answer it in a few words AND end with a tiny "and you\?"/);
});


// ── Acceptation automatique : 1 par personne et par jour, selon le niveau ───

test('auto-accept: the chance depends on the level and is fixed per like', () => {
  assert.deepEqual(t.ACCEPT_CHANCE, { 3: 90, 2: 50, 1: 15 });
  assert.equal(t.AUTO_ACCEPT_PER_USER_PER_DAY, 1);
  const N = 30000;
  const share = {};
  for (const level of [3, 2, 1]) {
    let ok = 0;
    for (let i = 0; i < N; i++) if (t.acceptRoll(`row-${i}`, level)) ok++;
    share[level] = ok / N;
    assert.ok(Math.abs(share[level] - t.ACCEPT_CHANCE[level] / 100) < 0.02, `L${level}: ${share[level]}`);
    // Stable : le même like donne toujours la même réponse (pas de nouveau tirage).
    assert.equal(t.acceptRoll('row-7', level), t.acceptRoll('row-7', level));
  }
  assert.ok(share[3] > share[2] && share[2] > share[1]);
  // Un like refusé à un niveau élevé l'est aussi à un niveau plus sélectif (même tirage, seuil plus bas).
  for (let i = 0; i < 500; i++) {
    if (t.acceptRoll(`row-${i}`, 1)) assert.equal(t.acceptRoll(`row-${i}`, 2) && t.acceptRoll(`row-${i}`, 3), true);
  }
});
