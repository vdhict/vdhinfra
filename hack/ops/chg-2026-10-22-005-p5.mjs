// chg-2026-10-22-005 point 5 (Larry 22-10 + 23-10; Argus 23-10: C1-C16, C5 = one-time TAP, deviations D-a..D-d,
// required changes R1-R9): what does the Passkey Point desk (.NET LAB) do when its own CA policy d63ae654
// ("PP-DEV CA-TP", auth context c2, built-in phishing-resistant MFA) is weakened? A dedicated persona
// pp-e2e-tp-catest-<yyyymmdd> signs in with a one-time Temporary Access Pass (non-phishing-resistant MFA) with the
// policy as is (baseline), (a) on the plain MFA strength, (b) report-only, (c) disabled; restore and re-check (persona
// refused again) after every case.
//
// Runs as a devtenant-build Job in the passkey-point-e2e runner image (Playwright + Chromium, Node 24), signed in as
// atlas-devtenant-build with its own certificate (mounted tls.key + tls.crt), self-checked: tenant, app id, roles.
// The token, the persona's password (create only, never stored) and every TAP stay in this process's memory: never in
// env, args, files, logs, screenshots or traces (C5a). Playwright runs without trace, video, HAR or screenshots.
//
// Writes are double-guarded (R1): ALLOW names the call shapes, guardWrite() names the only objects a write may touch
// (the catest persona, the catest group, membership of the catest persona in e660b8f8 or the catest group, the policy
// d63ae654 and the TAP method configuration). `node p5.mjs selftest` proves offline that forbidden writes are refused
// before anything is sent.
//
//   node p5.mjs selftest                    offline: R1 refusals (network stubbed; no key needed)
//   node p5.mjs precheck                    C1 C2 C5 C5b, hashes (C7), BEFORE state (incl. the full TAP config, R3)
//   node p5.mjs deadman <yyyymmdd> <fire-iso>   arms with a green self-check, fires at <fire-iso>, restores all (R4/R5)
//   node p5.mjs setup <yyyymmdd>            catest group + TAP target, persona (password only), memberships
//   node p5.mjs case <baseline|a|b|c|recheck> <yyyymmdd>
//   node p5.mjs cleanup <yyyymmdd>          C16 steps 1-4, every hash read back
// Inputs: /work/before.json (written once from the precheck BEFORE line).
// Output: RESULT <json> lines. Exit 0 ok | 2 refused (a check failed; nothing changed after it) | 1 error.
import { createHash, createPrivateKey, createSign, randomBytes, randomUUID, X509Certificate } from 'node:crypto';
import { readFileSync } from 'node:fs';

const TENANT_ID = '95cf7dac-b898-4b02-a22a-1379e2fde497';
const DOMAIN = '7m5b27gbc.onmicrosoft.com';
const BUILD_APP_ID = '9d98adaf-499f-49b2-ba94-cab1a5e42514';
const POLICY_ID = 'd63ae654-3dac-4eb1-996c-1fb31f466379';
const TP_GROUP = 'e660b8f8-c81f-4ebe-975a-96607dcdeec8';   // TP population = d63ae654's only include group
const TAP_GROUP_R1 = 'f06f3a30';                            // "PP-E2E-test": route 1 only if clean (it is not, 23-10)
const CATEST_GROUP = (d) => `PP-E2E catest TAP ${d}`;       // C5b route 2: dedicated static group for the window
const TAP_CFG = '/v1.0/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/TemporaryAccessPass';
const TAP_WRITABLE = ['state', 'isUsableOnce', 'minimumLifetimeInMinutes', 'maximumLifetimeInMinutes', 'defaultLifetimeInMinutes', 'defaultLength', 'includeTargets', 'excludeTargets'];
const ALLOW_OTHER_MEMBERS = ['099ec30d-7ed5-4171-b411-6e1e6ed02247']; // dev-tenant SIM-VM test persona (Argus C1, 23-10)
const STRENGTH = { pr: '00000000-0000-0000-0000-000000000004', mfa: '00000000-0000-0000-0000-000000000002' };
// UserAuthMethod-TAP.ReadWrite.All: TAPs only (Argus D-b). Group.ReadWrite.All covers member add/remove.
const NEED_ROLES = ['Policy.ReadWrite.ConditionalAccess', 'Policy.Read.All', 'Policy.ReadWrite.AuthenticationMethod', 'UserAuthMethod-TAP.ReadWrite.All', 'UserAuthenticationMethod.Read.All', 'Group.ReadWrite.All', 'User.ReadWrite.All'];
const DESK = 'https://passkey-point-dotnet-lab.bluejungle.net';
const PROPAGATION_MS = 7 * 60_000;
const out = (k, v) => console.log('RESULT ' + JSON.stringify({ [k]: v }));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const b64url = (b) => Buffer.from(b).toString('base64url');
const canon = (v) => (Array.isArray(v) ? v.map(canon) : v && typeof v === 'object' ? Object.fromEntries(Object.keys(v).sort().filter((k) => !k.includes('@odata')).map((k) => [k, canon(v[k])])) : v);
const sha = (v) => createHash('sha256').update(JSON.stringify(canon(v))).digest('hex');
const keyFields = (p) => ({ state: p.state, conditions: p.conditions, grantControls: { operator: p.grantControls?.operator, builtInControls: p.grantControls?.builtInControls, authenticationStrength: p.grantControls?.authenticationStrength?.id ?? null }, sessionControls: p.sessionControls });
const DATE_RE = /^20\d{6}$/;
const personaUpn = (d) => { if (!DATE_RE.test(d ?? '')) throw new Refused('date yyyymmdd'); return `pp-e2e-tp-catest-${d}@${DOMAIN}`; };
const tapWritable = (c) => Object.fromEntries(TAP_WRITABLE.filter((k) => k in (c ?? {})).map((k) => [k, c[k]]));
class Refused extends Error {}

let TOKEN = null, BEFORE = null;
const before = () => (BEFORE ??= JSON.parse(readFileSync('/work/before.json', 'utf8')));
// The objects this run may write (R1). Set only by lookups that verified them.
const T = { date: null, catestId: null, catestGroupId: null };

async function signIn() {
  const certPem = readFileSync('/secrets/build/tls.crt', 'utf8'), keyPem = readFileSync('/secrets/build/tls.key', 'utf8');
  const x5t = b64url(createHash('sha256').update(new X509Certificate(certPem).raw).digest());
  const now = Math.floor(Date.now() / 1000);
  const head = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT', 'x5t#S256': x5t }));
  const body = b64url(JSON.stringify({ aud: `https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token`, iss: BUILD_APP_ID, sub: BUILD_APP_ID, jti: randomUUID(), nbf: now, exp: now + 600 }));
  const s = createSign('RSA-SHA256'); s.update(`${head}.${body}`);
  const assertion = `${head}.${body}.${b64url(s.sign(createPrivateKey(keyPem)))}`;
  const r = await fetch(`https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token`, { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ client_id: BUILD_APP_ID, scope: 'https://graph.microsoft.com/.default', grant_type: 'client_credentials', client_assertion_type: 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer', client_assertion: assertion }) });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || !j.access_token) throw new Refused(`token ${r.status} ${j.error ?? ''}`);
  const c = JSON.parse(Buffer.from(j.access_token.split('.')[1], 'base64url').toString());
  const missing = NEED_ROLES.filter((x) => !(c.roles ?? []).includes(x));
  if (c.tid !== TENANT_ID || c.appid !== BUILD_APP_ID || missing.length) { out('roles', [...(c.roles ?? [])].sort()); throw new Refused(`self-check: tid/app or missing roles ${missing.join(',')}`); }
  TOKEN = j.access_token;
  out('selfCheck', { tid: c.tid, appid: c.appid, rolesNeeded: NEED_ROLES, allPresent: true, at: new Date().toISOString() });
}

// Layer 1: call shapes (C8). Anything else is refused before it is sent.
const ALLOW = [
  ['GET', /^\/beta\/identity\/conditionalAccess\/policies(\?|$)/], ['GET', /^\/beta\/identity\/conditionalAccess\/policies\/d63ae654-3dac-4eb1-996c-1fb31f466379$/],
  ['PATCH', /^\/beta\/identity\/conditionalAccess\/policies\/d63ae654-3dac-4eb1-996c-1fb31f466379$/],
  ['GET', /^\/v1\.0\/groups(\/[0-9a-f-]{36})?(\/(members|transitiveMembers\/microsoft\.graph\.user|appRoleAssignments))?(\?|$)/],
  ['GET', /^\/v1\.0\/policies\/authenticationMethodsPolicy(\?|$)/], ['GET', /^\/v1\.0\/policies\/authenticationMethodsPolicy\/authenticationMethodConfigurations\/TemporaryAccessPass$/],
  ['PATCH', /^\/v1\.0\/policies\/authenticationMethodsPolicy\/authenticationMethodConfigurations\/TemporaryAccessPass$/],
  ['POST', /^\/v1\.0\/groups$/], ['DELETE', /^\/v1\.0\/groups\/[0-9a-f-]{36}$/],
  ['POST', /^\/v1\.0\/groups\/[0-9a-f-]{36}\/members\/\$ref$/], ['DELETE', /^\/v1\.0\/groups\/[0-9a-f-]{36}\/members\/[0-9a-f-]{36}\/\$ref$/],
  ['GET', /^\/v1\.0\/users\/pp-e2e-tp-catest-20\d{6}%40/], ['GET', /^\/v1\.0\/users\/[0-9a-f-]{36}(\/(memberOf|authentication\/methods|authentication\/temporaryAccessPassMethods))?(\?|$)/],
  ['POST', /^\/v1\.0\/users$/], ['DELETE', /^\/v1\.0\/users\/[0-9a-f-]{36}$/],
  ['POST', /^\/v1\.0\/users\/[0-9a-f-]{36}\/authentication\/temporaryAccessPassMethods$/],
  ['DELETE', /^\/v1\.0\/users\/[0-9a-f-]{36}\/authentication\/temporaryAccessPassMethods\/[0-9a-zA-Z-]+$/],
];
// Layer 2 (R1): which objects a write may touch.
function guardWrite(method, path, body) {
  if (method === 'GET') return;
  const b = before();
  const protectedUsers = new Set([...(b.tpGroup?.ids ?? []), ...ALLOW_OTHER_MEMBERS]);
  const tapTargetIds = new Set((b.tapConfig?.includeTargets ?? []).map((t) => t.id));
  const isCatest = (id) => Boolean(T.catestId) && id === T.catestId && !protectedUsers.has(id);
  const isCatestGroup = (id) => Boolean(T.catestGroupId) && id === T.catestGroupId && id !== TP_GROUP && !tapTargetIds.has(id);
  let m;
  if (path === '/beta/identity/conditionalAccess/policies/' + POLICY_ID && method === 'PATCH') return;
  if (path === TAP_CFG && method === 'PATCH') {
    const keys = Object.keys(body ?? {}).filter((k) => k !== '@odata.type');
    if (keys.every((k) => TAP_WRITABLE.includes(k))) return;
    throw new Refused('guard: TAP config PATCH with a field outside the writable list');
  }
  if (path === '/v1.0/users' && method === 'POST') {
    if (T.date && body?.userPrincipalName === personaUpn(T.date) && body?.mailNickname === `pp-e2e-tp-catest-${T.date}`) return;
    throw new Refused('guard: user create only for the catest persona');
  }
  if (path === '/v1.0/groups' && method === 'POST') {
    if (T.date && body?.displayName === CATEST_GROUP(T.date) && body?.securityEnabled === true && body?.mailEnabled === false && !body?.groupTypes?.length) return;
    throw new Refused('guard: group create only for the catest group (static, security)');
  }
  if ((m = /^\/v1\.0\/users\/([0-9a-f-]{36})(\/authentication\/temporaryAccessPassMethods(\/[0-9a-zA-Z-]+)?)?$/.exec(path))) {
    if (isCatest(m[1])) return;
    throw new Refused('guard: user or TAP write on a user that is not the catest persona');
  }
  if ((m = /^\/v1\.0\/groups\/([0-9a-f-]{36})$/.exec(path)) && method === 'DELETE') {
    if (isCatestGroup(m[1])) return;
    throw new Refused('guard: group delete only for the catest group');
  }
  if ((m = /^\/v1\.0\/groups\/([0-9a-f-]{36})\/members\/\$ref$/.exec(path)) && method === 'POST') {
    const who = String(body?.['@odata.id'] ?? '').split('/').pop();
    if ((m[1] === TP_GROUP || isCatestGroup(m[1])) && isCatest(who)) return;
    throw new Refused('guard: member add only of the catest persona to e660b8f8 or the catest group');
  }
  if ((m = /^\/v1\.0\/groups\/([0-9a-f-]{36})\/members\/([0-9a-f-]{36})\/\$ref$/.exec(path)) && method === 'DELETE') {
    if ((m[1] === TP_GROUP || isCatestGroup(m[1])) && isCatest(m[2])) return;
    throw new Refused('guard: member remove only of the catest persona from e660b8f8 or the catest group');
  }
  throw new Refused(`guard: write not covered: ${method} ${path}`);
}
async function g(method, path, body) {
  const url = new URL(path.startsWith('http') ? path : `https://graph.microsoft.com${path}`);
  if (url.origin !== 'https://graph.microsoft.com' || !ALLOW.some(([m, re]) => m === method && re.test(url.pathname + url.search))) throw new Refused(`call not allowed: ${method} ${url.pathname}`);
  guardWrite(method, url.pathname, body);
  for (let i = 0; ; i++) {
    const r = await fetch(url, { method, headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json', accept: 'application/json' }, body: body ? JSON.stringify(body) : undefined });
    if ((r.status === 429 || r.status >= 500) && i < 4) { await sleep(5000 * (i + 1)); continue; }
    const t = await r.text(); let j = null; try { j = t ? JSON.parse(t) : null; } catch { j = null; }
    return { status: r.status, json: j };
  }
}
const ok = (r, what) => { if (r.status < 200 || r.status > 299) throw new Error(`${what}: ${r.status} ${r.json?.error?.code ?? ''}`); return r.json; };
async function list(path) { const all = []; let next = path; for (let n = 0; next; n++) { if (n > 20) throw new Error('paging'); const j = ok(await g('GET', next), 'list'); all.push(...(j.value ?? [])); next = j['@odata.nextLink'] ?? null; } return all; }

async function policy() { return ok(await g('GET', `/beta/identity/conditionalAccess/policies/${POLICY_ID}`), 'policy'); }
async function allPolicyHashes() { return Object.fromEntries((await list('/beta/identity/conditionalAccess/policies')).map((p) => [p.id.slice(0, 8), sha(keyFields(p))]).sort()); }
async function memberHash(gid) { const m = (await list(`/v1.0/groups/${gid}/members?$select=id&$top=999`)).map((x) => x.id).sort(); return { count: m.length, sha256: sha(m), ids: m }; }
async function tapConfig() { return ok(await g('GET', TAP_CFG), 'tap config'); }
async function methods(uid) { return (await list(`/v1.0/users/${uid}/authentication/methods`)).map((m) => ({ type: m['@odata.type'].replace('#microsoft.graph.', ''), id: m.id })); }

// Lookups that set the write targets (R1).
async function findCatest(d) {
  T.date = d;
  const r = await g('GET', `/v1.0/users/${encodeURIComponent(personaUpn(d))}?$select=id,userPrincipalName`);
  if (r.status !== 200) { T.catestId = null; return null; }
  if (String(r.json.userPrincipalName).toLowerCase() !== personaUpn(d) || [...(before().tpGroup?.ids ?? []), ...ALLOW_OTHER_MEMBERS].includes(r.json.id)) throw new Refused('catest lookup returned a protected user');
  T.catestId = r.json.id; return r.json;
}
async function findCatestGroup(d) {
  const gs = await list(`/v1.0/groups?$filter=displayName eq '${CATEST_GROUP(d)}'&$select=id,displayName,groupTypes`);
  if (gs.length > 1) throw new Refused('catest group twice');
  const id = gs[0]?.id ?? null;
  if (id && (id === TP_GROUP || (before().tapConfig?.includeTargets ?? []).some((t) => t.id === id))) throw new Refused('catest group lookup returned a protected group');
  T.catestGroupId = id; return id;
}

// TAP method configuration: compare and restore every writable field (R3).
async function restoreTapPolicy() {
  const b = before();
  for (let i = 0; i < 3; i++) {
    if (sha(tapWritable(await tapConfig())) === sha(tapWritable(b.tapConfig))) return true;
    ok(await g('PATCH', TAP_CFG, { '@odata.type': '#microsoft.graph.temporaryAccessPassAuthenticationMethodConfiguration', ...tapWritable(b.tapConfig) }), 'tap policy restore');
    await sleep(3000);
  }
  if (sha(tapWritable(await tapConfig())) !== sha(tapWritable(b.tapConfig))) throw new Error('TAP method policy not back to its before-state');
  return true;
}

async function restorePolicy() {
  const b = before();
  if (sha(keyFields(await policy())) !== b.policySha256) {
    ok(await g('PATCH', `/beta/identity/conditionalAccess/policies/${POLICY_ID}`, { state: b.policy.state, grantControls: { operator: b.policy.grantControls.operator, builtInControls: b.policy.grantControls.builtInControls, authenticationStrength: { id: b.policy.grantControls.authenticationStrength } } }), 'restore patch');
  }
  const h = sha(keyFields(await policy()));
  const all = await allPolicyHashes();
  const allSame = JSON.stringify(all) === JSON.stringify(b.allPolicies);
  out('restored', { at: new Date().toISOString(), policySha256: h, equalsBefore: h === b.policySha256, allPoliciesEqualBefore: allSame });
  if (h !== b.policySha256 || !allSame) throw new Error('restore did not return every CA policy to its before-hash');
}

async function deleteTaps(uid) {
  const taps = await list(`/v1.0/users/${uid}/authentication/temporaryAccessPassMethods`);
  for (const t of taps) ok(await g('DELETE', `/v1.0/users/${uid}/authentication/temporaryAccessPassMethods/${t.id}`), 'delete tap');
  return taps.map((t) => t.id);
}

async function precheck() {
  const policies = await list('/beta/identity/conditionalAccess/policies');
  const c2 = policies.filter((p) => (p.conditions?.applications?.includeAuthenticationContextClassReferences ?? []).includes('c2')).map((p) => p.id);
  const t = policies.find((p) => p.id === POLICY_ID);
  const u = t?.conditions?.users ?? {};
  const problems = [];
  if (c2.length !== 1 || c2[0] !== POLICY_ID) problems.push(`C2: c2 policies ${c2.map((x) => x.slice(0, 8))}`);
  if (!t || t.state !== 'enabled' || t.grantControls?.authenticationStrength?.id !== STRENGTH.pr) problems.push('target not enabled/phishing-resistant');
  if (JSON.stringify(u.includeGroups) !== JSON.stringify([TP_GROUP]) || (u.includeUsers ?? []).length || (u.includeRoles ?? []).length || u.includeGuestsOrExternalUsers) problems.push('C1: target scope differs');
  const g0 = ok(await g('GET', `/v1.0/groups/${TP_GROUP}?$select=id,groupTypes`), 'tp group');
  if ((g0.groupTypes ?? []).includes('DynamicMembership')) problems.push('C1: TP group dynamic');
  const direct = await list(`/v1.0/groups/${TP_GROUP}/members?$select=id&$top=999`);
  if (direct.some((m) => m['@odata.type'] !== '#microsoft.graph.user')) problems.push('C1: nested group');
  const users = await list(`/v1.0/groups/${TP_GROUP}/transitiveMembers/microsoft.graph.user?$select=id,userPrincipalName&$top=999`);
  const others = users.filter((m) => !/^pp-e2e-tp-[a-z0-9-]+@/.test(String(m.userPrincipalName).toLowerCase()) && !ALLOW_OTHER_MEMBERS.includes(m.id)).map((m) => m.id);
  if (others.length) problems.push(`C1: ${others.length} member(s) not a test persona: ${others}`);
  if (users.some((m) => /^pp-e2e-tp-catest-/.test(String(m.userPrincipalName).toLowerCase()))) problems.push('a catest persona is already in the TP group');
  out('c1c2', { c2: c2.map((x) => x.slice(0, 8)), tpGroupUsers: users.length, allowlisted: users.filter((m) => ALLOW_OTHER_MEMBERS.includes(m.id)).length, ok: problems.length === 0, problems });
  // C5b route 1 check (informative: route 2 is implemented).
  const r1 = (await list(`/v1.0/groups?$filter=startswith(displayName,'PP-E2E-test')&$select=id,groupTypes`)).filter((x) => x.id.startsWith(TAP_GROUP_R1));
  const inCa = r1.length === 1 ? policies.filter((p) => JSON.stringify(p.conditions?.users ?? {}).includes(r1[0].id)).map((p) => p.id.slice(0, 8)) : null;
  const tap = await tapConfig();
  if (tap.state !== 'enabled') problems.push('C5b: TAP method disabled');
  out('c5b', { route1Group: TAP_GROUP_R1, route1InCaPolicies: inCa, route: 2, tap: { state: tap.state, isUsableOnce: tap.isUsableOnce, minimumLifetimeInMinutes: tap.minimumLifetimeInMinutes, includeTargets: (tap.includeTargets ?? []).map((x) => x.id.slice(0, 8)) } });
  const b = { at: new Date().toISOString(), policy: keyFields(t), policySha256: sha(keyFields(t)), allPolicies: await allPolicyHashes(), tpGroup: await memberHash(TP_GROUP), tapConfig: tapWritable(tap), tapConfigSha256: sha(tapWritable(tap)), tapMinLifetime: tap.minimumLifetimeInMinutes ?? 10 };
  out('hashes', { policy: b.policySha256, tpGroup: b.tpGroup.sha256, tpGroupCount: b.tpGroup.count, tapConfig: b.tapConfigSha256, allPolicies: b.allPolicies });
  console.log('BEFORE ' + JSON.stringify(b));
  if (problems.length) throw new Refused(problems.join('; '));
}

async function setup(d) {
  const b = before();
  if (await findCatest(d)) throw new Refused('persona exists already');
  if (await findCatestGroup(d)) throw new Refused('catest group exists already');
  if (sha(tapWritable(await tapConfig())) !== b.tapConfigSha256) throw new Refused('TAP method policy not in its before-state');
  const cg = ok(await g('POST', '/v1.0/groups', { displayName: CATEST_GROUP(d), mailEnabled: false, mailNickname: `pp-e2e-catest-tap-${d}`, securityEnabled: true, description: 'chg-2026-10-22-005 point 5, window only (Argus C5b route 2)' }), 'create group');
  T.catestGroupId = cg.id;
  ok(await g('PATCH', TAP_CFG, { '@odata.type': '#microsoft.graph.temporaryAccessPassAuthenticationMethodConfiguration', includeTargets: [...b.tapConfig.includeTargets, { targetType: 'group', id: cg.id, isRegistrationRequired: false }] }), 'tap policy patch');
  const now = tapWritable(await tapConfig());
  const rest = { ...now, includeTargets: (now.includeTargets ?? []).filter((x) => x.id !== cg.id) };
  const sameOtherwise = sha(rest) === b.tapConfigSha256;   // R3: every field except the one added target equals before
  out('tapPolicy', { addedTarget: cg.id.slice(0, 8), targets: (now.includeTargets ?? []).length, everythingElseUnchanged: sameOtherwise });
  if (!sameOtherwise) { await restoreTapPolicy(); throw new Refused('TAP config changed beyond the added target; restored'); }
  const pw = `${b64url(randomBytes(24))}aA1!`;   // create only: the persona signs in with a TAP; the password is never stored
  const u = ok(await g('POST', '/v1.0/users', { accountEnabled: true, displayName: `PP E2E TP catest ${d}`, mailNickname: `pp-e2e-tp-catest-${d}`, userPrincipalName: personaUpn(d), passwordProfile: { password: pw, forceChangePasswordNextSignIn: false } }), 'create user');
  if ([...(b.tpGroup?.ids ?? []), ...ALLOW_OTHER_MEMBERS].includes(u.id)) throw new Refused('created id collides with a protected user');
  T.catestId = u.id;
  out('created', { id: u.id, upn: personaUpn(d).split('@')[0], group: cg.id });
  await addMemberships(u.id, cg.id);
}

// The two memberships of the catest persona. A new user can 404 on the first add while it replicates (run
// 20261023t080006z), so a 404 is retried for up to 60 s; any other error stops. A membership already present is kept.
async function addMemberships(uid, cgid) {
  const expect = [TP_GROUP, cgid].sort();
  const current = async () => (await list(`/v1.0/users/${uid}/memberOf?$select=id`)).map((x) => x.id).sort();
  const have = await current();
  if (have.some((id) => !expect.includes(id))) throw new Refused('catest persona has a membership outside the two');
  for (const gid of expect.filter((id) => !have.includes(id))) {
    for (let i = 0; ; i++) {
      const r = await g('POST', `/v1.0/groups/${gid}/members/$ref`, { '@odata.id': `https://graph.microsoft.com/v1.0/directoryObjects/${uid}` });
      if (r.status === 404 && i < 12) { out('addMemberRetry', { group: gid.slice(0, 8), attempt: i + 1 }); await sleep(5000); continue; }
      ok(r, 'add member'); break;
    }
  }
  let mem = [];
  for (let i = 0; i < 12; i++) { mem = await current(); if (mem.length === 2) break; await sleep(5000); }
  out('memberships', { count: mem.length, exactlyTheTwo: JSON.stringify(mem) === JSON.stringify(expect), methods: (await methods(uid)).map((m) => m.type) });
  if (JSON.stringify(mem) !== JSON.stringify(expect)) throw new Refused('memberships differ');
}

// Finish a setup that stopped after creating the persona and its group (run 20261023t080006z: add member 404). Only
// when the persona and the group exist, the TAP config equals its before-state plus exactly that group, and the
// persona has no authentication method other than the password.
async function resume(d) {
  const b = before();
  const u = await findCatest(d); const cgid = await findCatestGroup(d);
  if (!u || !cgid) throw new Refused('resume: persona or catest group missing');
  const now = tapWritable(await tapConfig());
  const targets = now.includeTargets ?? [];
  const rest = { ...now, includeTargets: targets.filter((x) => x.id !== cgid) };
  if (!targets.some((x) => x.id === cgid) || sha(rest) !== b.tapConfigSha256) throw new Refused('resume: TAP config is not before-state plus the catest group');
  const m = (await methods(u.id)).map((x) => x.type);
  if (m.some((t) => t !== 'passwordAuthenticationMethod')) throw new Refused('resume: persona has a method other than the password');
  out('resume', { id: u.id, group: cgid, tapConfigBeforePlusGroup: true, methods: m });
  await addMemberships(u.id, cgid);
}

async function weaken(kase) {
  const b = before();
  if (sha(keyFields(await policy())) !== b.policySha256) throw new Refused('policy is not in its before-state; not weakening');
  const body = kase === 'a' ? { grantControls: { operator: b.policy.grantControls.operator, builtInControls: b.policy.grantControls.builtInControls, authenticationStrength: { id: STRENGTH.mfa } } }
    : kase === 'b' ? { state: 'enabledForReportingButNotEnforced' } : { state: 'disabled' };
  ok(await g('PATCH', `/beta/identity/conditionalAccess/policies/${POLICY_ID}`, body), 'patch');
  const after = keyFields(await policy());
  const expected = kase === 'a' ? { ...b.policy, grantControls: { ...b.policy.grantControls, authenticationStrength: STRENGTH.mfa } } : { ...b.policy, state: body.state };
  const exact = sha(after) === sha(expected);
  out('weakened', { case: kase, at: new Date().toISOString(), field: Object.keys(body)[0], readBackMatchesPlannedOnly: exact, sha256: sha(after) });
  if (!exact) throw new Refused('weakened state is not exactly the planned change');
}

// One sign-in at the desk with a fresh one-time TAP. The TAP value never leaves this function.
async function signInWithTap(uid, upn, lifetime) {
  const created = ok(await g('POST', `/v1.0/users/${uid}/authentication/temporaryAccessPassMethods`, { isUsableOnce: true, lifetimeInMinutes: lifetime }), 'create tap');
  let tap = created.temporaryAccessPass; created.temporaryAccessPass = undefined;
  const meta = { tapId: created.id, isUsableOnce: created.isUsableOnce, lifetimeInMinutes: created.lifetimeInMinutes, createdAt: created.createdDateTime };
  let result;
  const { chromium } = await import('/e2e/node_modules/playwright-core/index.mjs');
  const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
  try {
    const ctx = await browser.newContext();   // fresh context; no trace, video, HAR or screenshot is ever started (C5a, C11)
    const page = await ctx.newPage();
    const trail = [], prompts = [];
    page.on('framenavigated', (f) => { if (f === page.mainFrame()) { const u = new URL(f.url()); trail.push(`${u.host}${u.pathname}`); } });
    try {
      await page.goto(`${DESK}/signin`, { timeout: 30_000 });
      await Promise.all([page.waitForURL(/login\.microsoftonline\.com/, { timeout: 30_000 }), page.locator('a[href="/auth/login"]').click()]);
      await page.locator('input[name=loginfmt]').fill(upn);
      await page.locator('#idSIButton9').click();
      // As the harness (aee4e84 registerPasskeyWithTap): Entra may open on the password page; switch to the TAP.
      const tapHeading = page.getByText(/temporary access pass/i).first(), pwHeading = page.getByText(/^enter password$/i).first();
      await Promise.race([tapHeading.waitFor({ state: 'visible', timeout: 20_000 }), pwHeading.waitFor({ state: 'visible', timeout: 20_000 })]).catch(() => {});
      if (!(await tapHeading.isVisible().catch(() => false))) {
        const ways = page.getByRole('link', { name: /other ways to sign in|sign in another way/i });
        if (await ways.first().isVisible().catch(() => false)) await ways.first().click();
        await page.getByText(/temporary access pass/i).first().click({ timeout: 10_000 });
      }
      const pass = page.locator('input[name=passwd]');
      await pass.waitFor({ state: 'visible', timeout: 20_000 });
      await pass.fill(tap); tap = null;
      await page.locator('#idSIButton9').click();
      const deskOrigin = new URL(DESK).origin;
      for (const t0 = Date.now(); Date.now() - t0 < 60_000;) {
        if (new URL(page.url()).origin === deskOrigin) break;
        const body = (await page.locator('body').innerText({ timeout: 1500 }).catch(() => '')).replace(/\s+/g, ' ');
        if (/stay signed in\?/i.test(body) && (await page.locator('#idBtn_Back').isVisible().catch(() => false))) { await page.locator('#idBtn_Back').click().catch(() => {}); continue; }
        if (/keep your account secure|more information required/i.test(body)) { prompts.push(body.slice(0, 80)); break; }   // C5c: never registered, never passed
        await page.waitForTimeout(700);
      }
      await page.waitForLoadState('networkidle', { timeout: 15_000 }).catch(() => {});
      const u = new URL(page.url());
      const body = (await page.locator('body').innerText({ timeout: 3000 }).catch(() => '')).replace(/\s+/g, ' ').trim();
      const onDesk = u.origin === deskOrigin;
      // R7: positive markers only. Accepted = body[data-signed-in="1"] and the desk card [data-desk]; refused = the desk's
      // own [data-refused=<reason>] page. Anything else is unknown, and the case is invalid.
      const signedIn = onDesk ? await page.locator('body[data-signed-in="1"]').count() : 0;
      const deskCard = onDesk ? await page.locator('[data-desk]').first().getAttribute('data-desk').catch(() => null) : null;
      const refusedReason = onDesk ? await page.locator('[data-refused]').first().getAttribute('data-refused').catch(() => null) : null;
      const deskOutcome = signedIn === 1 && deskCard !== null ? 'accepted' : refusedReason ? 'refused' : onDesk ? 'unknown' : 'not-on-desk';
      result = { landed: `${u.host}${u.pathname}`, onDesk, deskOutcome, deskCard, refusedReason, aadsts: /AADSTS\d{5,6}/.exec(body)?.[0] ?? null, entraText: onDesk ? null : body.slice(0, 140), prompts, trail: trail.slice(-8) };
    } catch (e) {
      result = { error: String(e?.message ?? e).split('\n')[0].slice(0, 160), landed: (() => { try { const u = new URL(page.url()); return `${u.host}${u.pathname}`; } catch { return null; } })(), deskOutcome: 'unknown', prompts, trail: trail.slice(-8) };
    }
    await ctx.close().catch(() => {});
  } finally { tap = null; await browser.close().catch(() => {}); }
  return { ...meta, ...result };
}

async function kase(k, d) {
  const b = before();
  const p = await findCatest(d); if (!p) throw new Refused('persona missing');
  const cg = await findCatestGroup(d);
  const mem = (await list(`/v1.0/users/${p.id}/memberOf?$select=id`)).map((x) => x.id).sort();
  if (!cg || JSON.stringify(mem) !== JSON.stringify([TP_GROUP, cg].sort())) throw new Refused('persona memberships differ');
  const weakens = ['a', 'b', 'c'].includes(k);
  if (!weakens && sha(keyFields(await policy())) !== b.policySha256) throw new Refused('baseline/recheck needs the before-state');
  let r = null, left = null;
  try {
    if (weakens) { await weaken(k); out('wait', { propagationMinutes: PROPAGATION_MS / 60000 }); await sleep(PROPAGATION_MS); }
    r = await signInWithTap(p.id, p.userPrincipalName, b.tapMinLifetime);
  } finally {
    // R2: TAP clean-up and the restore always run, whatever happened above.
    const deleted = await deleteTaps(p.id).catch((e) => { out('tapDeleteError', String(e?.message ?? e).slice(0, 120)); return null; });
    left = await methods(p.id).catch(() => null);
    out('signIn', { case: k, at: new Date().toISOString(), ...(r ?? { deskOutcome: 'unknown', error: 'sign-in did not complete' }), tapsDeleted: deleted?.length ?? null, deletedAt: new Date().toISOString(), methodsAfter: left?.map((m) => m.type) ?? null });
    if (weakens) await restorePolicy();
  }
  // C5c (after the restore): any method other than the password makes the case invalid and stops the run.
  if (!left || !left.every((m) => m.type === 'passwordAuthenticationMethod')) { out('c5c', { case: k, invalid: true, methodsAfter: left?.map((m) => m.type) ?? null }); throw new Refused('extra authentication method (or unreadable): case invalid, run stops; cleanup deletes the persona'); }
  if (r?.deskOutcome === 'unknown') throw new Refused('desk outcome unknown (R7): case invalid');
}

// R4/R5: one dead-man for the whole window. Self-checks when armed; at fire time every restore step runs on its own.
async function deadman(d, fireIso) {
  const t = Date.parse(fireIso); if (!Number.isFinite(t) || !DATE_RE.test(d ?? '')) throw new Refused('deadman <yyyymmdd> <fire-iso>');
  await signIn();
  before();
  out('armed', { firesAt: new Date(t).toISOString(), date: d });
  while (Date.now() < t) await sleep(Math.min(30_000, t - Date.now()));
  await signIn();
  const b = before(), errors = [], steps = {};
  const step = async (name, fn) => { try { steps[name] = await fn(); } catch (e) { errors.push(`${name}: ${String(e?.message ?? e).slice(0, 120)}`); steps[name] = 'error'; } };
  await step('caPolicy', async () => { await restorePolicy(); return 'ok'; });
  let p = null; await step('lookup', async () => { p = await findCatest(d); await findCatestGroup(d); return p ? 'persona present' : 'persona gone'; });
  if (p) {
    await step('taps', async () => (await deleteTaps(p.id)).length);
    await step('tpGroupMember', async () => { const r = await g('DELETE', `/v1.0/groups/${TP_GROUP}/members/${p.id}/$ref`); if (r.status !== 204 && r.status !== 404) throw new Error(`remove ${r.status}`); return r.status; });
  }
  await step('tapPolicy', async () => restoreTapPolicy());
  await step('tpGroupHash', async () => { for (let i = 0; i < 12; i++) { if ((await memberHash(TP_GROUP)).sha256 === b.tpGroup.sha256) return true; await sleep(5000); } throw new Error('TP group not back to its before-hash'); });
  out('deadman', { firedAt: new Date().toISOString(), steps, errors });
  if (errors.length) throw new Error(`dead-man: ${errors.length} step(s) failed`);
}

async function cleanup(d) {
  const b = before();
  const p = await findCatest(d); const cg = await findCatestGroup(d);
  if (p) {
    out('cleanupTaps', { deleted: (await deleteTaps(p.id)).length });
    const r = await g('DELETE', `/v1.0/groups/${TP_GROUP}/members/${p.id}/$ref`); if (r.status !== 204 && r.status !== 404) throw new Error(`remove member ${r.status}`);
  }
  let tp; for (let i = 0; i < 12; i++) { tp = await memberHash(TP_GROUP); if (tp.sha256 === b.tpGroup.sha256) break; await sleep(5000); }
  const tapOk = await restoreTapPolicy();
  if (cg) ok(await g('DELETE', `/v1.0/groups/${cg}`), 'delete catest group');
  out('cleanupGroups', { tpGroupEqualsBefore: tp.sha256 === b.tpGroup.sha256, tpGroupSha256: tp.sha256, tapConfigEqualsBefore: tapOk, catestGroupDeleted: Boolean(cg) });
  if (p) {
    out('cleanupMethods', { before: (await methods(p.id)).map((m) => m.type) });
    ok(await g('DELETE', `/v1.0/users/${p.id}`), 'delete user');
    let gone = false; for (let i = 0; i < 12 && !gone; i++) { gone = (await g('GET', `/v1.0/users/${p.id}`)).status === 404; if (!gone) await sleep(5000); }
    out('cleanupPersona', { deleted: true, readBack404: gone, note: 'soft-deleted; purge is not in the allow-list, it expires in 30 days' });
  }
  const h = sha(keyFields(await policy()));
  out('cleanupFinal', { policyEqualsBefore: h === b.policySha256, allPoliciesEqualBefore: JSON.stringify(await allPolicyHashes()) === JSON.stringify(b.allPolicies) });
  if (tp.sha256 !== b.tpGroup.sha256 || h !== b.policySha256) throw new Error('cleanup read-back differs from before');
}

// R1 offline test: forbidden writes are refused before fetch is ever called.
async function selftest() {
  let sent = 0;
  globalThis.fetch = async () => { sent++; throw new Error('network must not be used'); };
  const persona = 'aaaaaaaa-0000-4000-8000-000000000001', catest = 'cccccccc-0000-4000-8000-000000000003', catestG = 'dddddddd-0000-4000-8000-000000000004', tapTarget = 'eeeeeeee-0000-4000-8000-000000000005';
  BEFORE = { tpGroup: { ids: [persona, ALLOW_OTHER_MEMBERS[0]] }, tapConfig: { includeTargets: [{ id: tapTarget }] } };
  Object.assign(T, { date: '20261023', catestId: catest, catestGroupId: catestG });
  const cases = [
    ['delete a TP persona', 'DELETE', `/v1.0/users/${persona}`],
    ['delete the SIM persona', 'DELETE', `/v1.0/users/${ALLOW_OTHER_MEMBERS[0]}`],
    ['delete group e660b8f8', 'DELETE', `/v1.0/groups/${TP_GROUP}`],
    ['delete a TAP target group', 'DELETE', `/v1.0/groups/${tapTarget}`],
    ['remove another member from e660b8f8', 'DELETE', `/v1.0/groups/${TP_GROUP}/members/${persona}/$ref`],
    ['add another user to e660b8f8', 'POST', `/v1.0/groups/${TP_GROUP}/members/$ref`, { '@odata.id': `https://graph.microsoft.com/v1.0/directoryObjects/${persona}` }],
    ['create a TAP for a TP persona', 'POST', `/v1.0/users/${persona}/authentication/temporaryAccessPassMethods`, { isUsableOnce: true }],
    ['delete a TP persona TAP', 'DELETE', `/v1.0/users/${persona}/authentication/temporaryAccessPassMethods/abc`],
    ['create another user', 'POST', '/v1.0/users', { userPrincipalName: `someone@${DOMAIN}`, mailNickname: 'someone' }],
    ['PATCH another CA policy', 'PATCH', '/beta/identity/conditionalAccess/policies/9f9c792d-27ab-4e86-917a-c0395d0b95b5', { state: 'disabled' }],
    ['TAP config PATCH outside writable fields', 'PATCH', TAP_CFG, { excludeTargets: [], foo: 1 }],
  ];
  const results = [];
  for (const [name, m, path, body] of cases) {
    let refused = false, msg = '';
    try { await g(m, path, body); } catch (e) { refused = e instanceof Refused; msg = String(e.message).slice(0, 90); }
    results.push({ name, refused, msg });
  }
  // A permitted write passes the guard (it then reaches the stubbed fetch, which throws: counted separately).
  let allowedReached = false; const before0 = sent;
  try { await g('DELETE', `/v1.0/groups/${TP_GROUP}/members/${catest}/$ref`); } catch { allowedReached = sent === before0 + 1; }
  const pass = results.every((r) => r.refused) && sent === 1 && allowedReached;
  out('selftest', { pass, refusedAll: results.every((r) => r.refused), fetchCalls: sent, allowedCatestRemoveReachedNetwork: allowedReached, results });
  if (!pass) throw new Error('selftest failed');
}

async function main() {
  const [mode, a1, a2] = process.argv.slice(2);
  if (mode === 'selftest') return selftest();
  if (mode === 'deadman') return deadman(a1, a2);
  await signIn();
  if (mode === 'precheck') return precheck();
  if (mode === 'setup') { T.date = a1; return setup(a1); }
  if (mode === 'case' && ['baseline', 'a', 'b', 'c', 'recheck'].includes(a1)) return kase(a1, a2);
  if (mode === 'cleanup') return cleanup(a1);
  if (mode === 'resume') return resume(a1);
  throw new Refused('mode');
}
main().then(() => process.exit(0)).catch((e) => { out(e instanceof Refused ? 'refused' : 'error', String(e?.message ?? e).slice(0, 300)); process.exit(e instanceof Refused ? 2 : 1); });
