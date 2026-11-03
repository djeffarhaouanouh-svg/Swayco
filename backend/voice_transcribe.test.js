'use strict';

// Run with: node --test backend/voice_transcribe.test.js

const test = require('node:test');
const assert = require('node:assert/strict');

const { transcribeVoiceMessage, ownFolderPrefix } = require('./voice_transcribe');

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
