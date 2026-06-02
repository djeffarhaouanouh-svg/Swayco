// One-shot: enable the Apple provider on Supabase via the Management API.
//
// Apple's "secret" is NOT the raw .p8 — it's an ES256-signed JWT built from
// the .p8 + Team ID + Key ID + Service ID. This script generates that JWT,
// then PATCHes /v1/projects/{ref}/config/auth to flip Apple on.
//
// For the NATIVE iOS flow (signInWithIdToken), the id_token's audience is the
// app BUNDLE ID, so the bundle id MUST be in the allowed client-id list. The
// Service ID covers the web/OAuth redirect path. We register both.
//
// Usage (PowerShell):
//   $env:SUPABASE_ACCESS_TOKEN="sbp_xxx"; node scripts/enable-apple.js
//
// The access token is read from the environment and never written to disk.

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const PROJECT_REF = 'rhxenzcdnfvpgjjefztx';
const TEAM_ID = 'VXYW3LN267';
const KEY_ID = 'ML4Q9NMY68';
const SERVICE_ID = 'com.translate.livekit.livekitTranslate.signin';
const BUNDLE_ID = 'com.translate.livekit.livekitTranslate';
const P8_PATH = path.join(__dirname, '..', 'AuthKey_ML4Q9NMY68.p8');

const accessToken = process.env.SUPABASE_ACCESS_TOKEN;
if (!accessToken || !accessToken.startsWith('sbp_')) {
  console.error('✗ SUPABASE_ACCESS_TOKEN manquant ou invalide (doit commencer par sbp_).');
  console.error('  Génère-le sur https://supabase.com/dashboard/account/tokens');
  process.exit(1);
}

// ── 1. Build the ES256 client-secret JWT ──────────────────────────────────
function base64url(input) {
  return Buffer.from(input)
    .toString('base64')
    .replace(/=/g, '')
    .replace(/\+/g, '-')
    .replace(/\//g, '_');
}

const privateKey = fs.readFileSync(P8_PATH, 'utf8');
const now = Math.floor(Date.now() / 1000);
const exp = now + 60 * 60 * 24 * 180; // 180 days — Apple's max is 6 months.

const header = { alg: 'ES256', kid: KEY_ID };
const payload = {
  iss: TEAM_ID,
  iat: now,
  exp,
  aud: 'https://appleid.apple.com',
  sub: SERVICE_ID,
};

const signingInput = `${base64url(JSON.stringify(header))}.${base64url(JSON.stringify(payload))}`;
const signer = crypto.createSign('SHA256');
signer.update(signingInput);
// ES256 needs the raw r||s signature (IEEE P1363), not DER — dsaEncoding.
const signature = signer.sign(
  { key: privateKey, dsaEncoding: 'ieee-p1363' },
  'base64',
);
const clientSecret = `${signingInput}.${base64url(Buffer.from(signature, 'base64'))}`;

console.log('✓ JWT client-secret généré (exp dans 180 jours).');

// ── 2. PATCH the auth config ──────────────────────────────────────────────
const body = {
  external_apple_enabled: true,
  // Primary client id = the web Services ID; the native bundle id goes in the
  // additional list so id_tokens minted for the app are accepted too.
  external_apple_client_id: SERVICE_ID,
  external_apple_additional_client_ids: BUNDLE_ID,
  external_apple_secret: clientSecret,
};

async function main() {
  const res = await fetch(
    `https://api.supabase.com/v1/projects/${PROJECT_REF}/config/auth`,
    {
      method: 'PATCH',
      headers: {
        Authorization: `Bearer ${accessToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(body),
    },
  );
  const text = await res.text();
  if (!res.ok) {
    console.error(`✗ PATCH a échoué (HTTP ${res.status}):`);
    console.error(text);
    process.exit(1);
  }
  console.log(`✓ Config mise à jour (HTTP ${res.status}).`);

  // ── 3. Read back the public settings to confirm apple === true ──────────
  const verify = await fetch(
    `https://${PROJECT_REF}.supabase.co/auth/v1/settings`,
    { headers: { apikey: 'sb_publishable_5NZJowDX1ba6cGwuzFN08Q_j9GxFMXi' } },
  );
  const settings = await verify.json();
  console.log(`\n→ Vérification: apple=${settings.external.apple}, google=${settings.external.google}`);
  if (settings.external.apple === true) {
    console.log('\n🎉 Apple est maintenant activé sur Supabase.');
  } else {
    console.log('\n⚠️ Apple ressort encore false — voir la réponse PATCH ci-dessus.');
  }
}

main().catch((e) => {
  console.error('✗ Erreur réseau:', e.message);
  process.exit(1);
});
