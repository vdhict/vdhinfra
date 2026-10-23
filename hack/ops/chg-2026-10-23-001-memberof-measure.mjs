// chg-2026-10-23-001 (Larry 23-10, tsk-2026-10-17-002): READ-ONLY measurement of whether the desk api's CURRENT
// app-only permissions allow the v5 direct-membership read. v5 (567edd0d) calls GET /v1.0/users/{user}/memberOf
// ?$select=id&$top=999 with the api's own identity (AR1); Microsoft Learn lists Directory.Read.All as least privilege
// for it, against User.Read.All for transitiveMemberOf (the v4 read).
//
// Runs once in lab-passkey-dotnet with only the AR1 private key mounted (/secrets/ar1/tls.key) and the public
// thumbprint from the env. GET only, three reads. The token stays in memory and is never printed. Prints status codes,
// Graph error codes, counts and whether the TP population group id is in the result; no names, no ids of other objects.
//
//   node measure.mjs   (env: AR1_THUMBPRINT_SHA256 hex, TP_GROUP_ID, PERSONA_UPN)
// Exit 0 measured | 2 refused (self-check) | 1 error.
import { createPrivateKey, createSign, randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';

const TENANT_ID = '95cf7dac-b898-4b02-a22a-1379e2fde497';
const AR1_APP_ID = '6e05d927-e0c2-418b-9f01-ab909aec5699';
const GRAPH = 'https://graph.microsoft.com/v1.0';
const out = (o) => console.log('RESULT ' + JSON.stringify(o));
const b64url = (b) => Buffer.from(b).toString('base64url');

function assertion(keyPem, thumbHex) {
  const now = Math.floor(Date.now() / 1000);
  const head = b64url(JSON.stringify({ alg: 'PS256', typ: 'JWT', 'x5t#S256': Buffer.from(thumbHex, 'hex').toString('base64url') }));
  const body = b64url(JSON.stringify({ aud: `https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token`, iss: AR1_APP_ID, sub: AR1_APP_ID, jti: randomUUID(), nbf: now, exp: now + 300 }));
  const s = createSign('RSA-SHA256'); s.update(`${head}.${body}`);
  return `${head}.${body}.${s.sign({ key: createPrivateKey(keyPem), padding: 6, saltLength: 32 }).toString('base64url')}`;
}

async function main() {
  const thumb = process.env.AR1_THUMBPRINT_SHA256 ?? '', group = (process.env.TP_GROUP_ID ?? '').toLowerCase(), upn = process.env.PERSONA_UPN ?? '';
  if (!/^[0-9a-fA-F]{64}$/.test(thumb) || !/^[0-9a-f-]{36}$/.test(group) || !/^pp-e2e-tp-[a-z0-9-]+@7m5b27gbc\.onmicrosoft\.com$/.test(upn)) { out({ refused: 'env' }); return 2; }
  const res = await fetch(`https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token`, {
    method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ client_id: AR1_APP_ID, scope: 'https://graph.microsoft.com/.default', grant_type: 'client_credentials', client_assertion_type: 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer', client_assertion: assertion(readFileSync('/secrets/ar1/tls.key', 'utf8'), thumb) }),
  });
  const j = await res.json().catch(() => ({}));
  if (!res.ok || !j.access_token) { out({ refused: `token ${res.status} ${j.error ?? ''}` }); return 2; }
  const c = JSON.parse(Buffer.from(j.access_token.split('.')[1], 'base64url').toString());
  if (c.tid !== TENANT_ID || c.appid !== AR1_APP_ID) { out({ refused: 'self-check: tenant or app' }); return 2; }
  out({ selfCheck: { tid: c.tid, appid: c.appid }, appRoles: [...(c.roles ?? [])].sort() });

  const reads = [
    ['memberOf (v5 directMemberships)', `/users/${encodeURIComponent(upn)}/memberOf?$select=id&$top=999`],
    ['transitiveMemberOf (v4 memberships)', `/users/${encodeURIComponent(upn)}/transitiveMemberOf?$select=id&$top=999`],
  ];
  for (const [name, path] of reads) {
    const r = await fetch(GRAPH + path, { headers: { authorization: `Bearer ${j.access_token}`, accept: 'application/json' } });
    const b = await r.json().catch(() => ({}));
    const v = Array.isArray(b.value) ? b.value : [];
    out({ read: name, status: r.status, error: b?.error?.code ?? null, count: v.length, nextLink: Boolean(b['@odata.nextLink']),
          types: v.reduce((a, e) => ((a[e['@odata.type'] ?? 'none'] = (a[e['@odata.type'] ?? 'none'] ?? 0) + 1), a), {}),
          tpGroupPresent: v.some((e) => String(e.id).toLowerCase() === group), requestId: r.headers.get('request-id') });
  }
  return 0;
}
main().then((x) => process.exit(x)).catch((e) => { out({ error: String(e?.message ?? e).slice(0, 200) }); process.exit(1); });
