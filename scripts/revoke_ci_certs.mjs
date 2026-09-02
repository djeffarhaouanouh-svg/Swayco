// Revoke the throwaway "Created via API" certificates that
// `xcodebuild -allowProvisioningUpdates` mints on every CI run. Their private
// key dies with the ephemeral runner, so they are pure dead weight — and left
// alone they pile up until the account hits Apple's "maximum number of
// certificates" limit and every archive fails.
//
// Run this BEFORE the archive step; the archive re-creates exactly one it can
// actually use. Human certs ("Lenny Hardoroc" ...) and Apple-managed certs are
// left untouched.
//
//   node scripts/revoke_ci_certs.mjs <AuthKey_XXX.p8 path> <ASC_KEY_ID> <ASC_ISSUER_ID>
//
// Never fails the build — cleanup problems are logged and swallowed.

import { readFileSync } from 'node:fs';
import crypto from 'node:crypto';

const [, , KEY_PATH, KEY_ID, ISSUER_ID] = process.argv;
if (!KEY_PATH || !KEY_ID || !ISSUER_ID) {
  console.error('usage: node scripts/revoke_ci_certs.mjs <AuthKey.p8> <KEY_ID> <ISSUER_ID>');
  process.exit(0); // don't break the build over a bad invocation
}

const b64url = (b) =>
  Buffer.from(b).toString('base64').replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');

function makeJwt() {
  const p8 = readFileSync(KEY_PATH, 'utf8');
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' }));
  const payload = b64url(
    JSON.stringify({ iss: ISSUER_ID, iat: now, exp: now + 600, aud: 'appstoreconnect-v1' }),
  );
  const input = `${header}.${payload}`;
  const sig = crypto.sign('sha256', Buffer.from(input), { key: p8, dsaEncoding: 'ieee-p1363' });
  return `${input}.${b64url(sig)}`;
}

const API = 'https://api.appstoreconnect.apple.com/v1';

async function main() {
  const jwt = makeJwt();
  const headers = { Authorization: `Bearer ${jwt}` };

  const certs = [];
  let url = `${API}/certificates?limit=200`;
  while (url) {
    const r = await fetch(url, { headers });
    if (!r.ok) {
      console.error(`list certificates failed: ${r.status} ${await r.text()}`);
      return;
    }
    const j = await r.json();
    certs.push(...(j.data ?? []));
    url = j.links?.next ?? null;
  }
  console.log(`${certs.length} certificates on the account`);

  // The CI junk: display name exactly "Created via API", and NOT an
  // Apple-managed cert (those can't be revoked and aren't the problem).
  const junk = certs.filter((c) => {
    const a = c.attributes ?? {};
    const name = a.displayName || a.name || '';
    const type = a.certificateType || '';
    return name === 'Created via API' && !/MANAGED/i.test(type);
  });
  console.log(`${junk.length} throwaway "Created via API" certs to revoke`);

  let ok = 0;
  for (const c of junk) {
    const r = await fetch(`${API}/certificates/${c.id}`, { method: 'DELETE', headers });
    if (r.status === 204) {
      ok++;
      console.log(`  revoked ${c.id}  ${c.attributes?.certificateType}  exp ${c.attributes?.expirationDate}`);
    } else {
      console.error(`  failed ${c.id}: ${r.status} ${await r.text()}`);
    }
  }
  console.log(`revoked ${ok}/${junk.length}`);
}

try {
  await main();
} catch (e) {
  console.error(`cert cleanup errored (ignored): ${e?.message || e}`);
}
process.exit(0);
