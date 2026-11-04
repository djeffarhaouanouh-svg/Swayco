'use strict';

// Run with: node --test backend/voice_transcribe.test.js

const test = require('node:test');
const assert = require('node:assert/strict');

const { transcribeVoiceMessage, ownFolderPrefix, createVoiceTranscriber } = require('./voice_transcribe');

const UID = '3f2b8c1e-5d4a-4e7b-9a10-0c6d2e8f4b21';
const MID = '9a1b2c3d-4e5f-4a6b-8c7d-0e1f2a3b4c5d';
const SB_URL = 'https://proj.supabase.co';
const URL_OK = `${SB_URL}/storage/v1/object/public/voice-messages/${UID}/123.m4a`;

/** Supabase stand-in : un message, un profil, et on retient les updates. */
function fakeSb({ msg, profileLang = 'fr', lookupError = null } = {}) {
  const updates = [];
  const sb = {
    from(table) {
      const q = {
        _table: table,
        _update: null,
        select: () => q,
        eq: () => q,
        update: (v) => { q._update = v; return q; },
        maybeSingle: async () => {
          if (table === 'messages') return { data: msg, error: lookupError };
          return { data: { language: profileLang }, error: null };
        },
        then: (res) => {
          if (q._update) updates.push(q._update);
          return Promise.resolve({ error: null }).then(res);
        },
      };
      return q;
    },
  };
  return { sb, updates };
}

function fakeFetch({ audioOk = true, sttText = 'Bonjour, ça va ?', sttOk = true } = {}) {
  const calls = [];
  const impl = async (url, init) => {
    calls.push(String(url));
    if (String(url).includes('openai.com')) {
      return {
        ok: sttOk,
        status: sttOk ? 200 : 500,
        text: async () => JSON.stringify({ text: sttText }),
      };
    }
    return {
      ok: audioOk,
      status: audioOk ? 200 : 404,
      arrayBuffer: async () => new Uint8Array([1, 2, 3, 4]).buffer,
    };
  };
  return { impl, calls };
}

const base = (sb, fetchImpl, extra = {}) => ({
  sb, uid: UID, messageId: MID, supabaseUrl: SB_URL,
  openaiKey: 'k', fetchImpl, ...extra,
});

const mine = (over = {}) => ({ id: MID, sender: UID, audio_url: URL_OK, body: '', ...over });

test('transcribes my voice note and writes body + language', async () => {
  const { sb, updates } = fakeSb({ msg: mine() });
  const f = fakeFetch();
  const out = await transcribeVoiceMessage(base(sb, f.impl, { hintLang: 'fr-FR' }));
  assert.equal(out.status, 200);
  assert.deepEqual(updates, [{ body: 'Bonjour, ça va ?', language: 'fr' }]);
  assert.equal(f.calls.length, 2); // le fichier, puis la transcription
});

test('names the file after its real format (webm from a browser, m4a from a phone)', async () => {
  const names = [];
  const impl = async (url, init) => {
    if (String(url).includes('openai.com')) {
      names.push(init.body.get('file').name);
      return { ok: true, status: 200, text: async () => JSON.stringify({ text: 'salut' }) };
    }
    return { ok: true, status: 200, arrayBuffer: async () => new Uint8Array([1, 2]).buffer };
  };
  for (const ext of ['webm', 'm4a']) {
    const { sb } = fakeSb({ msg: mine({ audio_url: `${SB_URL}/storage/v1/object/public/voice-messages/${UID}/1.${ext}` }) });
    await transcribeVoiceMessage(base(sb, impl));
  }
  assert.deepEqual(names, ['voice.webm', 'voice.m4a']);
});

test('falls back to the profile language when the app gives no hint', async () => {
  const { sb, updates } = fakeSb({ msg: mine(), profileLang: 'ja' });
  await transcribeVoiceMessage(base(sb, fakeFetch().impl));
  assert.equal(updates[0].language, 'ja');
});

test('only the sender can transcribe', async () => {
  const { sb, updates } = fakeSb({ msg: mine({ sender: 'someone-else' }) });
  const out = await transcribeVoiceMessage(base(sb, fakeFetch().impl));
  assert.equal(out.status, 403);
  assert.equal(updates.length, 0);
});

test('refuses an audio url outside the sender\'s own folder (no free fetch)', async () => {
  for (const audio_url of [
    'http://169.254.169.254/latest/meta-data',
    `${SB_URL}/storage/v1/object/public/voice-messages/other-user/1.m4a`,
    `${SB_URL}/storage/v1/object/public/avatars/${UID}/1.m4a`,
    '',
  ]) {
    const { sb } = fakeSb({ msg: mine({ audio_url }) });
    const f = fakeFetch();
    const out = await transcribeVoiceMessage(base(sb, f.impl));
    assert.equal(out.status, 400, audio_url);
    assert.equal(f.calls.length, 0, `fetched ${audio_url}`);
  }
});

test('already transcribed: nothing is done twice', async () => {
  const { sb, updates } = fakeSb({ msg: mine({ body: 'déjà là' }) });
  const f = fakeFetch();
  const out = await transcribeVoiceMessage(base(sb, f.impl));
  assert.deepEqual(out.body, { ok: true, already: true });
  assert.equal(f.calls.length, 0);
  assert.equal(updates.length, 0);
});

test('silence or a stock phrase without letters: body stays empty', async () => {
  const { sb, updates } = fakeSb({ msg: mine() });
  const out = await transcribeVoiceMessage(
    base(sb, fakeFetch({ sttText: ' ... ' }).impl),
  );
  assert.equal(out.status, 200);
  assert.equal(out.body.empty, true);
  assert.equal(updates.length, 0);
});

test('bad ids, unknown messages, missing config', async () => {
  const { sb } = fakeSb({ msg: null });
  assert.equal((await transcribeVoiceMessage({ ...base(sb, fakeFetch().impl), messageId: 'x' })).status, 400);
  assert.equal((await transcribeVoiceMessage(base(sb, fakeFetch().impl))).status, 404);
  assert.equal((await transcribeVoiceMessage({ ...base(sb, fakeFetch().impl), openaiKey: '' })).status, 503);
  assert.equal((await transcribeVoiceMessage({ ...base(null, fakeFetch().impl) })).status, 503);
});

test('upstream failures are 502, never a write', async () => {
  const a = fakeSb({ msg: mine() });
  assert.equal(
    (await transcribeVoiceMessage(base(a.sb, fakeFetch({ audioOk: false }).impl))).status,
    502,
  );
  const b = fakeSb({ msg: mine() });
  assert.equal(
    (await transcribeVoiceMessage(base(b.sb, fakeFetch({ sttOk: false }).impl))).status,
    502,
  );
  assert.equal(a.updates.length + b.updates.length, 0);
});

test('ownFolderPrefix ignores trailing slashes on the project url', () => {
  assert.equal(
    ownFolderPrefix('https://p.supabase.co//', UID),
    `https://p.supabase.co/storage/v1/object/public/voice-messages/${UID}/`,
  );
});

// ── Real ids are integers ────────────────────────────────────────────────────
test('numeric message ids (436, 441…) are accepted - the real ones', async () => {
  const { sb, updates } = fakeSb({ msg: mine({ id: 436 }) });
  const out = await transcribeVoiceMessage({ ...base(sb, fakeFetch().impl), messageId: '436' });
  assert.equal(out.status, 200);
  assert.equal(updates.length, 1);
  for (const bad of ['', 'abc', '12x', '-5', '1 or 1=1', '9'.repeat(25)]) {
    assert.equal((await transcribeVoiceMessage({ ...base(sb, fakeFetch().impl), messageId: bad })).status, 400, bad);
  }
});

// ── Server-side auto transcription ───────────────────────────────────────────
/** Supabase stand-in for the tick: a list of pending messages + per-id lookup. */
function tickSb(rows) {
  const updates = [];
  const sb = {
    from(table) {
      const q = {
        _update: null,
        _id: null,
        select: () => q,
        neq: () => q, eq: (c, v) => { if (c === 'id') q._id = v; return q; },
        gte: () => q, lte: () => q, order: () => q, limit: () => q,
        update: (v) => { q._update = v; return q; },
        maybeSingle: async () => {
          if (table === 'profiles') return { data: { language: 'en' }, error: null };
          const m = rows.find((r) => String(r.id) === String(q._id));
          return { data: m || null, error: null };
        },
        then: (res) => {
          if (q._update) { updates.push(q._update); return Promise.resolve({ error: null }).then(res); }
          return Promise.resolve({ data: rows.map((r) => ({ id: r.id, sender: r.sender })), error: null }).then(res);
        },
      };
      return q;
    },
  };
  return { sb, updates };
}
const AIID = '8027667b-51dc-4758-9595-f8eac620891d';
const aiMsg = (id) => ({
  id, sender: AIID, body: '',
  audio_url: `${SB_URL}/storage/v1/object/public/voice-messages/${AIID}/${id}.wav`,
});

test('auto: a pending voice (even from an AI account) is transcribed with no JWT', async () => {
  const { sb, updates } = tickSb([aiMsg(441)]);
  const f = fakeFetch({ sttText: 'Hi! I just landed in Madrid.' });
  const tr = createVoiceTranscriber({ sb, supabaseUrl: SB_URL, openaiKey: 'k', fetchImpl: f.impl });
  assert.equal(await tr.tick(), 1);
  assert.deepEqual(updates, [{ body: 'Hi! I just landed in Madrid.', language: 'en' }]);
});

test('auto: a message is tried at most twice (silence would otherwise cost every round)', async () => {
  const { sb, updates } = tickSb([aiMsg(500)]);
  const f = fakeFetch({ sttText: ' ... ' }); // silence: body stays empty
  const tr = createVoiceTranscriber({ sb, supabaseUrl: SB_URL, openaiKey: 'k', fetchImpl: f.impl });
  for (let i = 0; i < 6; i++) await tr.tick();
  const stt = f.calls.filter((u) => u.includes('openai.com')).length;
  assert.equal(stt, 2);
  assert.equal(updates.length, 0);
});

test('auto: nothing happens without Supabase or the OpenAI key', async () => {
  const { sb } = tickSb([aiMsg(1)]);
  const f = fakeFetch();
  assert.equal(await createVoiceTranscriber({ sb: null, supabaseUrl: SB_URL, openaiKey: 'k', fetchImpl: f.impl }).tick(), 0);
  assert.equal(await createVoiceTranscriber({ sb, supabaseUrl: SB_URL, openaiKey: '', fetchImpl: f.impl }).tick(), 0);
  assert.equal(f.calls.length, 0);
});

test('auto: a failing transcription never throws out of the loop', async () => {
  const { sb } = tickSb([aiMsg(7), aiMsg(8)]);
  const f = fakeFetch({ sttOk: false });
  const tr = createVoiceTranscriber({ sb, supabaseUrl: SB_URL, openaiKey: 'k', fetchImpl: f.impl });
  await assert.doesNotReject(() => tr.tick());
});

test('auto: asks only for recent voices that the app has had time to handle', async () => {
  const seen = [];
  const sb = { from: () => { const q = { select: () => q, neq: (c, v) => (seen.push(['neq', c, v]), q), eq: (c, v) => (seen.push(['eq', c, v]), q), gte: (c, v) => (seen.push(['gte', v]), q), lte: (c, v) => (seen.push(['lte', v]), q), order: () => q, limit: () => q, then: (r) => Promise.resolve({ data: [], error: null }).then(r) }; return q; } };
  const NOW = Date.parse('2026-11-04T10:00:00Z');
  await createVoiceTranscriber({ sb, supabaseUrl: SB_URL, openaiKey: 'k', fetchImpl: fakeFetch().impl, now: () => NOW }).tick();
  assert.deepEqual(seen, [
    ['neq', 'audio_url', ''],
    ['eq', 'body', ''],
    ['gte', '2026-11-04T09:45:00.000Z'], // 15 min back
    ['lte', '2026-11-04T09:59:35.000Z'], // 25 s grace for the sender's own app
  ]);
});

// ── Providers: OpenAI first, Grok as the fallback ────────────────────────────
function twoProviders({ grokOk = true, openaiOk = true, provider = '' } = {}) {
  const urls = [];
  const impl = async (url, init) => {
    urls.push(String(url));
    if (String(url).includes('api.x.ai')) {
      const names = [...init.body.keys()];
      return { ok: grokOk, status: grokOk ? 200 : 402, text: async () => JSON.stringify({ text: 'texte grok', _fields: names }) };
    }
    if (String(url).includes('openai.com')) {
      return { ok: openaiOk, status: openaiOk ? 200 : 401, text: async () => JSON.stringify({ text: 'texte openai' }) };
    }
    return { ok: true, status: 200, arrayBuffer: async () => new Uint8Array([1, 2, 3]).buffer };
  };
  const run = async (extra = {}) => {
    const { sb, updates } = fakeSb({ msg: mine() });
    const out = await transcribeVoiceMessage({ ...base(sb, impl), grokKey: 'g', provider, ...extra });
    return { out, updates, urls };
  };
  return { run };
}

test('providers: OpenAI is tried first and Grok is not called when it works', async () => {
  const { out, updates, urls } = await twoProviders().run();
  assert.equal(out.status, 200);
  assert.equal(updates[0].body, 'texte openai');
  assert.equal(urls.filter((u) => u.includes('api.x.ai')).length, 0);
});

test('providers: Grok gets ONLY the file field (anything else is rejected by xAI)', async () => {
  let fields;
  const impl = async (url, init) => {
    if (String(url).includes('api.x.ai')) { fields = [...init.body.keys()]; return { ok: true, status: 200, text: async () => JSON.stringify({ text: 'x y' }) }; }
    return { ok: true, status: 200, arrayBuffer: async () => new Uint8Array([1]).buffer };
  };
  const { sb } = fakeSb({ msg: mine() });
  await transcribeVoiceMessage({ ...base(sb, impl), grokKey: 'g' });
  assert.deepEqual(fields, ['file']);
});

test('providers: OpenAI fails (no credit) -> Grok takes over', async () => {
  const { out, updates } = await twoProviders({ openaiOk: false }).run();
  assert.equal(out.status, 200);
  assert.equal(updates[0].body, 'texte grok');
});

test('providers: both fail -> 502, nothing written', async () => {
  const { out, updates } = await twoProviders({ grokOk: false, openaiOk: false }).run();
  assert.equal(out.status, 502);
  assert.equal(updates.length, 0);
});

test('providers: VOICE_STT_PROVIDER=grok puts Grok first', async () => {
  const { updates, urls } = await twoProviders({ provider: 'grok' }).run();
  assert.equal(updates[0].body, 'texte grok');
  assert.equal(urls.filter((u) => u.includes('openai.com')).length, 0);
});

test('providers: only one key (either) is enough', async () => {
  assert.equal((await twoProviders().run({ openaiKey: '' })).out.status, 200);
  assert.equal((await twoProviders().run({ grokKey: '' })).out.status, 200);
});

// ── The url check must not depend on the exact shape of SUPABASE_URL ─────────
test('url check: Railway SUPABASE_URL in another shape still accepts the real voice', async () => {
  for (const configured of ['', 'https://PROJ.supabase.co/', 'https://proj.supabase.co/rest/v1', 'http://proj.supabase.co', 'proj.supabase.co']) {
    const { sb, updates } = fakeSb({ msg: mine() });
    const out = await transcribeVoiceMessage({ ...base(sb, fakeFetch().impl), supabaseUrl: configured });
    assert.equal(out.status, 200, `SUPABASE_URL=${JSON.stringify(configured)}`);
    assert.equal(updates.length, 1);
  }
});

test('url check: still refuses foreign hosts, http, other buckets and other people\'s folders', async () => {
  const bad = [
    `https://evil.example.com/storage/v1/object/public/voice-messages/${UID}/1.m4a`,
    `https://proj.supabase.co.evil.com/storage/v1/object/public/voice-messages/${UID}/1.m4a`,
    `http://proj.supabase.co/storage/v1/object/public/voice-messages/${UID}/1.m4a`,
    `https://proj.supabase.co/storage/v1/object/public/avatars/${UID}/1.m4a`,
    `https://proj.supabase.co/storage/v1/object/public/voice-messages/someone-else/1.m4a`,
    `https://proj.supabase.co/storage/v1/object/public/voice-messages/${UID}evil/1.m4a`,
    'not a url',
  ];
  for (const audio_url of bad) {
    const { sb } = fakeSb({ msg: mine({ audio_url }) });
    const f = fakeFetch();
    const out = await transcribeVoiceMessage(base(sb, f.impl));
    assert.equal(out.status, 400, audio_url);
    assert.equal(f.calls.length, 0, `fetched ${audio_url}`);
  }
});