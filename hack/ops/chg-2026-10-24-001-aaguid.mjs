// chg-2026-10-24-001 READ-ONLY: the aaGuid of the registered fido2 method on one pp-e2e-tp-* persona in dev tenant
// 7m5b27gbc, compared with the GUID in the sign-in log's authenticationMethodDetail (Larry tsk-2026-10-14-001).
// Runs INSIDE the devtenant image as a devtenant-build Job, signed in as atlas-devtenant-build through the image's
// appSignIn (tenant pin + self-check). GET only; the token is never printed. Personas are printed by alias only.
//   node /work/aaguid.mjs
// Exit: 0 measured (verdict in RESULT aaguid) | 2 refused (tenant pin) | 1 error.
const TENANT_ID = '95cf7dac-b898-4b02-a22a-1379e2fde497';
const INITIAL_DOMAIN = '7m5b27gbc.onmicrosoft.com';
const EXPECTED = '2fc741d3-d86f-4c84-99f0-546220b74172';
const V1 = 'https://graph.microsoft.com/v1.0';
const out = (k, v) => console.log('RESULT ' + JSON.stringify({ [k]: v }));

async function main() {
  const { appSignIn, signInIo, mountedKeySource, PINNED_APP_IDS, DEV_TENANT } = await import('/app/infra/devtenant/lib/app-auth.ts');
  if (DEV_TENANT.id !== TENANT_ID || DEV_TENANT.domain !== INITIAL_DOMAIN) { out('refused', 'image DEV_TENANT mismatch'); return 2; }
  let key = await mountedKeySource().load('build');
  const s = await appSignIn(signInIo((u, init) => fetch(u, init), (l) => console.log(l)), 'build', PINNED_APP_IDS.build, key, new Date());
  key = null;
  const get = async (url) => {
    if (!url.startsWith(V1 + '/')) throw new Error('outside Graph v1.0');
    const r = await fetch(url, { method: 'GET', headers: { authorization: `Bearer ${s.token}`, ConsistencyLevel: 'eventual' } });
    let json = null; try { json = await r.json(); } catch { json = null; }
    if (r.status !== 200) throw new Error(`GET ${url.split('?')[0].replace(/[0-9a-f-]{36}/g, '{id}')} -> ${r.status} ${json?.error?.code ?? ''}`);
    return json;
  };
  const users = (await get(`${V1}/users?$filter=startsWith(userPrincipalName,'pp-e2e-tp-')&$select=id,userPrincipalName&$count=true&$top=50`)).value ?? [];
  const personas = users.filter((u) => String(u.userPrincipalName).toLowerCase().endsWith('@' + INITIAL_DOMAIN));
  out('personas', personas.length);
  for (const u of personas) {
    const alias = String(u.userPrincipalName).split('@')[0].slice('pp-e2e-'.length);
    const m = (await get(`${V1}/users/${u.id}/authentication/fido2Methods?$select=id,aaGuid,model,createdDateTime`)).value ?? [];
    if (!m.length) { out('noFido2', alias); continue; }
    const rows = m.map((x) => ({ aaGuid: String(x.aaGuid ?? '').toLowerCase(), model: x.model ?? null, created: x.createdDateTime ?? null }));
    out('aaguid', { persona: alias, methods: rows, expected: EXPECTED, match: rows.every((r) => r.aaGuid === EXPECTED) });
    return 0;
  }
  out('aaguid', { persona: null, reason: 'no pp-e2e-tp-* persona has a fido2 method' });
  return 0;
}
main().then((x) => process.exit(x)).catch((e) => { out('error', String(e?.message ?? e).slice(0, 200)); process.exit(1); });
