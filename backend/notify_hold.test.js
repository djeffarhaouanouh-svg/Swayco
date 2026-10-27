'use strict';

// Run with: node --test backend/notify_hold.test.js

const test = require('node:test');
const assert = require('node:assert/strict');

const { scheduleNotify, _test } = require('./notify');

const ID = '3f2b8c1e-5d4a-4e7b-9a10-0c6d2e8f4b21';
const PAYLOAD = { title: 'Léa', body: 'veut te matcher', type: 'friend_request' };

/** A Supabase stand-in whose friendships row is whatever [row] says. */
function fakeSupabase(row, error = null) {
  const asked = [];
  const sb = {
    from(table) {
      asked.push(table);
      const q = {
        select: () => q,
        eq: () => q,
        maybeSingle: async () => ({ data: row, error }),
      };
      return q;
    },
  };
  return { sb, asked };
}

/** Runs everything held so far, as if the delay had elapsed. */
function harness(row, error) {
  const timers = [];
  const sent = [];
  const { sb, asked } = fakeSupabase(row, error);
  const deps = {
    supabase: () => sb,
    notifyUser: async (uid, payload) => { sent.push([uid, payload]); },
    setTimeout: (fn, ms) => { timers.push({ fn, ms }); return undefined; },
  };
  return { deps, timers, sent, asked };
}

test('a like still pending after the delay: the push goes out', async () => {
  const h = harness({ status: 'pending' });
  assert.equal(scheduleNotify('u1', PAYLOAD, { delaySeconds: 180, friendshipId: ID }, h.deps), true);
  assert.equal(h.timers[0].ms, 180000);
  assert.equal(h.sent.length, 0); // nothing before the delay
  await h.timers[0].fn();
  assert.deepEqual(h.sent, [['u1', PAYLOAD]]);
});

test('a like withdrawn meanwhile (row gone): no push', async () => {
  const h = harness(null);
  scheduleNotify('u1', PAYLOAD, { delaySeconds: 180, friendshipId: ID }, h.deps);
  await h.timers[0].fn();
  assert.equal(h.sent.length, 0);
});

test('a like already answered (accepted / rejected): no push', async () => {
  for (const status of ['accepted', 'rejected']) {
    const h = harness({ status });
    scheduleNotify('u1', PAYLOAD, { delaySeconds: 180, friendshipId: ID }, h.deps);
    await h.timers[0].fn();
    assert.equal(h.sent.length, 0, status);
  }
});

test('a failed lookup still sends: better a late push than none', async () => {
  const h = harness(null, { message: 'db down' });
  scheduleNotify('u1', PAYLOAD, { delaySeconds: 180, friendshipId: ID }, h.deps);
  await h.timers[0].fn();
  assert.equal(h.sent.length, 1);
});

test('nothing is held without a delay or with a bad friendship id', () => {
  const h = harness({ status: 'pending' });
  assert.equal(scheduleNotify('u1', PAYLOAD, { delaySeconds: 0, friendshipId: ID }, h.deps), false);
  assert.equal(scheduleNotify('u1', PAYLOAD, { delaySeconds: 'x', friendshipId: ID }, h.deps), false);
  assert.equal(scheduleNotify('u1', PAYLOAD, { delaySeconds: 180, friendshipId: 'nope' }, h.deps), false);
  assert.equal(scheduleNotify('u1', PAYLOAD, { delaySeconds: 180 }, h.deps), false);
  assert.equal(h.timers.length, 0);
});

test('nothing is held when Supabase is not configured', () => {
  const h = harness({ status: 'pending' });
  h.deps.supabase = () => null;
  assert.equal(scheduleNotify('u1', PAYLOAD, { delaySeconds: 180, friendshipId: ID }, h.deps), false);
});

test('the delay is capped at 10 minutes', () => {
  const h = harness({ status: 'pending' });
  scheduleNotify('u1', PAYLOAD, { delaySeconds: 99999, friendshipId: ID }, h.deps);
  assert.equal(h.timers[0].ms, 600000);
});

test('the held counter goes back down once the push has been decided', async () => {
  const before = _test.heldCount();
  const h = harness({ status: 'pending' });
  scheduleNotify('u1', PAYLOAD, { delaySeconds: 180, friendshipId: ID }, h.deps);
  assert.equal(_test.heldCount(), before + 1);
  await h.timers[0].fn();
  assert.equal(_test.heldCount(), before);
});

test('a send that throws is swallowed, not an unhandled rejection', async () => {
  const h = harness({ status: 'pending' });
  h.deps.notifyUser = async () => { throw new Error('fcm down'); };
  scheduleNotify('u1', PAYLOAD, { delaySeconds: 180, friendshipId: ID }, h.deps);
  await assert.doesNotReject(() => h.timers[0].fn());
});
