'use strict';

// Run with: node --test backend/revenuecat.test.js
// Uses Node's built-in test runner (node:test) — no new dependency added.

const test = require('node:test');
const assert = require('node:assert/strict');

process.env.REVENUECAT_WEBHOOK_AUTH = 'Bearer test-secret';
const revenueCat = require('./revenuecat');

const PRO_USER = '11111111-1111-1111-1111-111111111111';

/** Records every .from(table).update(patch).eq(col, val) call. */
function fakeDb({ updateError = null, rpcError = null, rpcResult = 'until' } = {}) {
  const calls = { updates: [], rpcs: [] };
  return {
    calls,
    from(table) {
      return {
        update(patch) {
          return {
            eq(col, val) {
              calls.updates.push({ table, patch, col, val });
              return Promise.resolve({ error: updateError });
            },
          };
        },
      };
    },
    rpc(name, params) {
      calls.rpcs.push({ name, params });
      return Promise.resolve({ data: rpcResult, error: rpcError });
    },
  };
}

function proEvent(overrides = {}) {
  return {
    event: {
      id: 'evt_1',
      type: 'INITIAL_PURCHASE',
      app_user_id: PRO_USER,
      entitlement_ids: ['pro'],
      product_id: 'pro_monthly',
      environment: 'PRODUCTION',
      expiration_at_ms: 1_800_000_000_000,
      ...overrides,
    },
  };
}

test('INITIAL_PURCHASE grants pro with the event expiry', async () => {
  const db = fakeDb();
  const status = await revenueCat.handleEvent(proEvent(), db);
  assert.equal(status, 'pro_synced');
  assert.equal(db.calls.updates.length, 1);
  const { table, patch, col, val } = db.calls.updates[0];
  assert.equal(table, 'profiles');
  assert.equal(col, 'id');
  assert.equal(val, PRO_USER);
  assert.deepEqual(patch, {
    is_pro: true,
    subscription_tier: 'plus',
    pro_expires_at: new Date(1_800_000_000_000).toISOString(),
  });
});

test('RENEWAL re-applies the same shape as INITIAL_PURCHASE', async () => {
  const db = fakeDb();
  const status = await revenueCat.handleEvent(
    proEvent({ type: 'RENEWAL', id: 'evt_2', expiration_at_ms: 1_900_000_000_000 }),
    db,
  );
  assert.equal(status, 'pro_synced');
  assert.deepEqual(db.calls.updates[0].patch, {
    is_pro: true,
    subscription_tier: 'plus',
    pro_expires_at: new Date(1_900_000_000_000).toISOString(),
  });
});

test('EXPIRATION clears is_pro and subscription_tier only', async () => {
  const db = fakeDb();
  const status = await revenueCat.handleEvent(
    proEvent({ type: 'EXPIRATION', id: 'evt_3' }),
    db,
  );
  assert.equal(status, 'pro_synced');
  assert.deepEqual(db.calls.updates[0].patch, {
    is_pro: false,
    subscription_tier: 'free',
  });
});

test('event without entitlement info is ignored, no write', async () => {
  const db = fakeDb();
  const event = proEvent();
  delete event.event.entitlement_ids;
  const status = await revenueCat.handleEvent(event, db);
  assert.equal(status, 'ignored_no_entitlement');
  assert.equal(db.calls.updates.length, 0);
});

test('entitlement present but not "pro" is ignored, no write', async () => {
  const db = fakeDb();
  const status = await revenueCat.handleEvent(
    proEvent({ entitlement_ids: ['some_other_entitlement'] }),
    db,
  );
  assert.equal(status, 'ignored_entitlement');
  assert.equal(db.calls.updates.length, 0);
});

test('unresolvable user (no UUID anywhere) is reported, no write', async () => {
  const db = fakeDb();
  const status = await revenueCat.handleEvent(
    proEvent({ app_user_id: '$RCAnonymousID:abc123', original_app_user_id: null, aliases: [] }),
    db,
  );
  assert.equal(status, 'unresolved');
  assert.equal(db.calls.updates.length, 0);
});

test('SANDBOX events are processed exactly like PRODUCTION', async () => {
  const db = fakeDb();
  const status = await revenueCat.handleEvent(
    proEvent({ environment: 'SANDBOX', id: 'evt_sandbox' }),
    db,
  );
  assert.equal(status, 'pro_synced');
  assert.equal(db.calls.updates.length, 1);
});

test('SANDBOX is tagged distinctly from PRODUCTION in the logs', async () => {
  const lines = [];
  const original = console.log;
  console.log = (msg) => lines.push(String(msg));
  try {
    await revenueCat.handleEvent(proEvent({ environment: 'SANDBOX', id: 'evt_tag' }), fakeDb());
    await revenueCat.handleEvent(proEvent({ environment: 'PRODUCTION', id: 'evt_tag2' }), fakeDb());
  } finally {
    console.log = original;
  }
  assert.ok(lines.some((l) => l.includes('[SANDBOX]')));
  assert.ok(lines.some((l) => l.includes('[PRODUCTION]')));
});

test('duplicate event redelivery is idempotent (same end state both times)', async () => {
  const db = fakeDb();
  const event = proEvent({ id: 'evt_dup' });
  const first = await revenueCat.handleEvent(event, db);
  const second = await revenueCat.handleEvent(event, db);
  assert.equal(first, 'pro_synced');
  assert.equal(second, 'pro_synced');
  assert.equal(db.calls.updates.length, 2);
  assert.deepEqual(db.calls.updates[0].patch, db.calls.updates[1].patch);
});

test('a Stripe-only web subscriber is untouched by an unrelated pro event target', async () => {
  // Sanity check that the patch never touches unrelated columns (e.g.
  // stripe_subscription_id) — only the three documented fields.
  const db = fakeDb();
  await revenueCat.handleEvent(proEvent({ type: 'EXPIRATION', id: 'evt_scope' }), db);
  assert.deepEqual(Object.keys(db.calls.updates[0].patch).sort(), [
    'is_pro',
    'subscription_tier',
  ]);
});

// ── Boost regression — unchanged behaviour after the refactor ─────────────

function boostEvent(overrides = {}) {
  return {
    event: {
      id: 'boost_evt_1',
      type: 'NON_RENEWING_PURCHASE',
      app_user_id: PRO_USER,
      product_id: 'Boost_1',
      transaction_id: 'txn_1',
      environment: 'PRODUCTION',
      ...overrides,
    },
  };
}

test('boost: still credited via grant_boost on NON_RENEWING_PURCHASE', async () => {
  const db = fakeDb({ rpcResult: '2026-01-01T00:00:00.000Z' });
  const status = await revenueCat.handleEvent(boostEvent(), db);
  assert.equal(status, 'boosted');
  assert.equal(db.calls.rpcs.length, 1);
  assert.equal(db.calls.rpcs[0].name, 'grant_boost');
  assert.equal(db.calls.rpcs[0].params.p_user_id, PRO_USER);
  assert.equal(db.calls.rpcs[0].params.p_transaction_id, 'txn_1');
  assert.equal(db.calls.rpcs[0].params.p_product_id, 'Boost_1');
  assert.equal(db.calls.rpcs[0].params.p_hours, 24);
  // Boost never touches the profiles table directly.
  assert.equal(db.calls.updates.length, 0);
});

test('boost: android product id boost_1 still matches', async () => {
  const db = fakeDb();
  const status = await revenueCat.handleEvent(
    boostEvent({ product_id: 'boost_1', id: 'boost_evt_2', transaction_id: 'txn_2' }),
    db,
  );
  assert.equal(status, 'boosted');
});

test('boost: unrelated product id is ignored', async () => {
  const db = fakeDb();
  const status = await revenueCat.handleEvent(
    boostEvent({ product_id: 'pro_monthly', id: 'boost_evt_3' }),
    db,
  );
  assert.equal(status, 'ignored_product');
  assert.equal(db.calls.rpcs.length, 0);
});

test('unknown event type is ignored', async () => {
  const db = fakeDb();
  const status = await revenueCat.handleEvent(
    { event: { id: 'x', type: 'PRODUCT_CHANGE', app_user_id: PRO_USER } },
    db,
  );
  assert.equal(status, 'ignored');
});

// ── isAuthorized ────────────────────────────────────────────────────────

test('isAuthorized accepts the exact configured secret and rejects others', () => {
  assert.equal(
    revenueCat.isAuthorized({ headers: { authorization: 'Bearer test-secret' } }),
    true,
  );
  assert.equal(
    revenueCat.isAuthorized({ headers: { authorization: 'Bearer wrong' } }),
    false,
  );
  assert.equal(revenueCat.isAuthorized({ headers: {} }), false);
});
