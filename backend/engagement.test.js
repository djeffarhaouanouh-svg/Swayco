'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { _test } = require('./engagement');

/** Faux Supabase : chaque table rend ses lignes, les filtres sont ignores. */
function fakeSupabase(tables) {
  return {
    from(name) {
      let upserted = null;
      const q = {
        select: () => q,
        eq: () => q,
        in: () => q,
        gte: () => q,
        limit: () => q,
        upsert: (row) => { upserted = row; return q; },
        then(resolve) {
          if (upserted) return resolve({ data: [{ id: 1 }], error: null });
          const t = tables[name];
          if (!t) return resolve({ data: null, error: { message: 'missing' } });
          // Le plafond du jour lit un compte dans notif_log.
          return resolve({ data: t, count: 0, error: null });
        },
      };
      return q;
    },
  };
}

// Midi UTC : jour en France comme au tick de la tache.
const NOON = Date.UTC(2026, 10, 28, 12, 0, 0);

test('profileViews : une notification avec le nombre de visiteurs', async (t) => {
  t.mock.timers.enable({ apis: ['Date'], now: NOON });
  const sent = [];
  const sb = fakeSupabase({
    profile_view_settings: [{ user_id: '11111111-1111-1111-1111-111111111111' }],
    profile_views: [
      { viewed_id: '11111111-1111-1111-1111-111111111111', viewer_id: 'a' },
      { viewed_id: '11111111-1111-1111-1111-111111111111', viewer_id: 'a' },
      { viewed_id: '11111111-1111-1111-1111-111111111111', viewer_id: 'b' },
    ],
    notif_log: [],
    profiles: [{
      id: '11111111-1111-1111-1111-111111111111',
      language: 'fr-FR', country: 'France',
    }],
  });
  const n = await _test.profileViews({
    sb, notifyUser: async (uid, payload) => sent.push(payload),
  });
  assert.strictEqual(n, 1);
  assert.strictEqual(sent[0].type, 'profile_views');
  assert.strictEqual(sent[0].body, 'Nouvelles visites : 2');
});

test('profileViews : rien si deja prevenu dans les 24 h', async (t) => {
  t.mock.timers.enable({ apis: ['Date'], now: NOON });
  const uid = '11111111-1111-1111-1111-111111111111';
  const sb = fakeSupabase({
    profile_view_settings: [{ user_id: uid }],
    profile_views: [{ viewed_id: uid, viewer_id: 'a' }],
    notif_log: [{ user_id: uid }],
    profiles: [{ id: uid, language: 'fr', country: 'France' }],
  });
  const n = await _test.profileViews({
    sb, notifyUser: async () => assert.fail('ne doit rien envoyer'),
  });
  assert.strictEqual(n, 0);
});

test('profileViews : table des reglages absente => rien', async () => {
  const n = await _test.profileViews({
    sb: fakeSupabase({}), notifyUser: async () => assert.fail('non'),
  });
  assert.strictEqual(n, 0);
});
