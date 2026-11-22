// Run: npm i embedded-postgres pg (in a scratch dir), then node this file.
// Spins up a throwaway real Postgres, applies 0002 + 0097, plays scenarios A-E,
// the auto-message exclusions and the anti-duplicate/concurrency checks.
import EmbeddedPostgres from 'embedded-postgres';
import pg from 'pg';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const ROOT = 'c:/Users/Thomas/Downloads/translate/supabase/migrations';
const dataDir = path.resolve('./data');
fs.rmSync(dataDir, { recursive: true, force: true });

const server = new EmbeddedPostgres({
  databaseDir: dataDir, user: 'postgres', password: 'pw', port: 54329, persistent: false,
  initdbFlags: ['--encoding=UTF8', '--locale=C'],
});
await server.initialise();
await server.start();
await server.createDatabase('t');

const conn = () => new pg.Client({ host: 'localhost', port: 54329, user: 'postgres', password: 'pw', database: 't' });
const admin = conn(); await admin.connect();

// --- Stubs for what Supabase provides, then the REAL schema pieces + 0097 ---
await admin.query(`
  create schema auth;
  create function auth.uid() returns uuid language sql stable as
    $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
  create role authenticated;
`);
const sql2 = fs.readFileSync(`${ROOT}/0002_profiles_friendships.sql`, 'utf8')
  // keep only the table DDL; skip realtime publication blocks (no publication here)
  .split('-- â”€â”€â”€ Realtime publication')[0];
await admin.query(sql2);
// messages: only the columns the function touches (+ the real ones 0093/0086 insert)
await admin.query(`
  create table public.messages (
    id bigserial primary key, conversation_id text not null, sender uuid not null,
    recipient uuid, sender_name text not null default '', body text not null,
    language text not null default '', created_at timestamptz default now());
`);
await admin.query(fs.readFileSync(`${ROOT}/0097_engaged_user.sql`, 'utf8'));

let pass = 0, fail = 0;
const ok = (name, cond, extra = '') => {
  if (cond) { pass++; console.log('PASS', name); } else { fail++; console.log('FAIL', name, extra); }
};
const uuid = () => crypto.randomUUID();
const mkUser = async () => { const id = uuid();
  await admin.query(`insert into profiles(id, display_name) values ($1,'u')`, [id]); return id; };
const befriend = (a, b, status = 'accepted') =>
  admin.query(`insert into friendships(requester, addressee, status) values ($1,$2,$3)`, [a, b, status]);
const say = (u, body, conv = 'dm-x') =>
  admin.query(`insert into messages(conversation_id, sender, body) values ($1,$2,$3)`, [conv, u, body]);

async function as(user, fn) { // one session per call, auth.uid() = user
  const c = conn(); await c.connect();
  try { await c.query(`select set_config('request.jwt.claim.sub', $1, false)`, [user ?? '']); return await fn(c); }
  finally { await c.end(); }
}
const claim = (u) => as(u, async c => (await c.query('select public.claim_engaged_user() r')).rows[0].r);
const confirm = (u) => as(u, c => c.query('select public.confirm_engaged_user_sent()'));

// ---- Scenarios Aâ€“E ----
{ // A: already has friends, then sends first message
  const a = await mkUser(), f = await mkUser(); await befriend(a, f);
  ok('A before message: no event', (await claim(a)) === false);
  await say(a, 'salut');
  ok('A after first message: event', (await claim(a)) === true); }
{ // B: sends a message first, then friendship accepted
  const b = await mkUser(), f = await mkUser();
  await say(b, 'hello');
  ok('B message only: no event', (await claim(b)) === false);
  await befriend(f, b, 'pending');
  ok('B pending request: still no event', (await claim(b)) === false);
  await admin.query(`update friendships set status='accepted' where addressee=$1`, [b]);
  ok('B after accept: event', (await claim(b)) === true); }
{ // C: friends, never messages
  const c = await mkUser(), f = await mkUser(); await befriend(c, f);
  ok('C friends, no message: no event', (await claim(c)) === false); }
{ // D: messages, no friends
  const d = await mkUser(); await say(d, 'anyone?'); await say(d, 'hello?');
  ok('D messages, no friend: no event', (await claim(d)) === false); }
{ // E: both conditions, keeps going -> exactly one event ever
  const e = await mkUser(), f = await mkUser(), g = await mkUser();
  await befriend(e, f); await say(e, 'a');
  ok('E first claim: event', (await claim(e)) === true);
  await confirm(e);
  await say(e, 'b'); await befriend(g, e);
  ok('E after confirm + more messages/friends: no 2nd event', (await claim(e)) === false);
  ok('E repeated: still none', (await claim(e)) === false); }

// ---- What counts as a message ----
const friendsWith = async () => { const u = await mkUser(), f = await mkUser(); await befriend(u, f); return u; };
{ const u = await friendsWith();
  for (const b of ['group_left', 'quiz|food|1', 'quiz|food|2|abc', 'quiz_done', `quiz_stop|${uuid()}`, 'ðŸ‘‹'])
    await say(u, b, 'grp-or-dm');
  ok('auto messages only (group_left/quiz/ðŸ‘‹): no event', (await claim(u)) === false); }
{ const u = await friendsWith();
  await say(u, 'quiz|x|1'); await say(u, 'ðŸ‘‹');
  await say(u, 'Bonjour toi', 'grp-' + uuid());
  ok('real GROUP message counts (after auto ones ignored)', (await claim(u)) === true); }
{ const u = await friendsWith(); await say(u, 'ðŸ‘‹ salut, Ã§a va ?');
  ok('real text that merely contains ðŸ‘‹ counts', (await claim(u)) === true); }
{ const u = await friendsWith(); await say(u, 'quizz Ã§a te dit ?');
  ok('real text starting with "quiz" word (no pipe) counts', (await claim(u)) === true); }
{ const u = await mkUser(), f = await mkUser(); await befriend(u, f, 'pending'); await say(u, 'hi');
  ok('pending friendship does not count', (await claim(u)) === false); }
{ const u = await mkUser(), f = await mkUser(); await befriend(f, u); await say(u, 'hi');
  ok('accepted friendship where I am the ADDRESSEE counts', (await claim(u)) === true); }
{ const u = await friendsWith(); await say(u, 'x');
  ok('unauthenticated (no uid): false', (await claim(null)) === false);
  ok('unauthenticated did not consume the claim', (await claim(u)) === true); }

// ---- Anti-duplicate ----
{ const u = await friendsWith(); await say(u, 'x');
  const results = await Promise.all(Array.from({ length: 25 }, () => claim(u)));
  ok(`25 CONCURRENT claims -> exactly one true (got ${results.filter(Boolean).length})`,
     results.filter(Boolean).length === 1); }
{ const u = await friendsWith(); await say(u, 'x');
  ok('claim #1 true', (await claim(u)) === true);
  ok('claim within lease: false (no dup)', (await claim(u)) === false);
  // app killed before confirm -> lease expires -> retried, not lost
  await admin.query(`update profiles set engaged_claimed_at = now() - interval '11 minutes' where id=$1`, [u]);
  ok('lease expired (app died before confirm): re-claimed once', (await claim(u)) === true);
  ok('and only once again', (await claim(u)) === false);
  await confirm(u);
  await admin.query(`update profiles set engaged_claimed_at = now() - interval '2 hours' where id=$1`, [u]);
  ok('after confirm: never again, even if lease would be long expired', (await claim(u)) === false);
  const row = (await admin.query(`select engaged_sent_at from profiles where id=$1`, [u])).rows[0];
  ok('engaged_sent_at set', row.engaged_sent_at !== null);
  await confirm(u); ok('confirm is idempotent', true); }
{ const u = await friendsWith(); await say(u, 'x');
  // two devices racing right after a confirm + new claim attempts
  const r = await Promise.all([claim(u), claim(u), confirm(u).then(() => claim(u)), claim(u)]);
  ok('race with confirm: at most one true', r.filter(Boolean).length <= 1, JSON.stringify(r)); }
{ // privacy: one user cannot claim/confirm for someone else (function uses auth.uid())
  const victim = await friendsWith(); await say(victim, 'x'); const other = await mkUser();
  ok('other user cannot claim on behalf of victim', (await claim(other)) === false);
  await confirm(other);
  const row = (await admin.query(`select engaged_sent_at from profiles where id=$1`, [victim])).rows[0];
  ok("other user's confirm leaves victim untouched", row.engaged_sent_at === null);
  ok('victim still claims normally', (await claim(victim)) === true); }
// idempotent re-run of the migration
await admin.query(fs.readFileSync(`${ROOT}/0097_engaged_user.sql`, 'utf8'));
ok('migration re-applies cleanly (idempotent)', true);

console.log(`\n${pass} passed, ${fail} failed`);
await admin.end(); await server.stop();
process.exit(fail ? 1 : 0);

